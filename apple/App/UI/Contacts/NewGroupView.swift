import SwiftUI

/// Create a private group (relay-screens current/17, on the design system): optional photo and
/// name in one card, the people picked so far, then the contacts with lime checkmarks.
struct NewGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let created: (String) -> Void
    @State private var name = ""
    @State private var selected: [String] = []
    @State private var photo: UIImage?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DSSection {
                        HStack(spacing: 14) {
                            EditablePhoto(name: trimmed.isEmpty ? "?" : trimmed, photo: photo, size: 60, icon: photo == nil ? "camera" : nil, cropTitle: "Photo du groupe") { image in
                                withAnimation(.smooth) { photo = image }
                            }
                            TextField("Nom du groupe", text: $name)
                                .font(DS.TextStyle.title3)
                                .foregroundStyle(DS.label)
                                .focused($nameFocused)
                                .submitLabel(.done)
                        }
                        .padding(.horizontal, DS.Space.cell)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } footer: {
                        Text("Photo facultative. Toi seul pourras changer le nom et la photo.")
                    }
                    if !selected.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(selected, id: \.self) { fp in
                                    VStack(spacing: 6) {
                                        DSAvatar(name: model.name(of: fp), size: 48, photo: model.photo(for: fp))
                                        Text(model.name(of: fp))
                                            .font(DS.TextStyle.caption)
                                            .foregroundStyle(DS.label)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 60)
                                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                                }
                            }
                            .padding(.horizontal, DS.Space.margin + 4)
                        }
                        .padding(.top, DS.Space.group)
                    }
                    DSSection(header: selected.isEmpty ? "Membres" : "Membres · \(selected.count)") {
                        if model.contacts.isEmpty {
                            DSRow(first: true) {
                                Text("Ajoute d'abord des contacts.").font(DS.TextStyle.body).foregroundStyle(DS.label2)
                            }
                        }
                        ContactChecklist(contacts: model.contacts, selected: $selected)
                    }
                    .padding(.top, DS.Space.group)
                    if let error {
                        Text(error)
                            .font(DS.TextStyle.footnote)
                            .foregroundStyle(DS.danger)
                            .padding(.horizontal, DS.Space.margin + DS.Space.cell)
                            .padding(.top, 10)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(DS.background)
            .animation(.smooth, value: selected)
            .navigationTitle("Nouveau groupe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() }.tint(DS.label) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") {
                        do {
                            let id = try model.createGroup(name: trimmed, members: selected)
                            if let photo { model.setGroupProfile(String(id.dropFirst(2)), photo: .some(photo)) }
                            Haptics.success()
                            dismiss()
                            created(id)
                        } catch {
                            withAnimation { self.error = error.message }
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(DS.accentFill)
                    .foregroundStyle(DS.onAccent)
                    .disabled(trimmed.isEmpty || selected.isEmpty)
                }
            }
            .onAppear {
                if DemoData.screen == "new-group" {
                    name = "Covoit retour"
                    selected = [DemoData.ines, DemoData.jade]
                    photo = DemoData.avatarArt(0x0B6E63, 0x6DD5FA, "🚐")
                }
            }
        }
        .presentationCornerRadius(DS.Radius.sheet)
    }
}
