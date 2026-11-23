import SwiftUI

/// Compare the four safety words with a contact (relay-screens current/21, on the design system):
/// title, one sentence, the numbered words, the short code, then "Les mots sont identiques" or
/// "Ils sont différents". Used after adding someone, from the "À vérifier" row and from the
/// contact sheet.
struct VerifyWordsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let contact: ContactJSON
    /// "Contact ajouté" title right after adding.
    var justAdded = false
    var done: () -> Void = {}

    private var words: [String] { model.safetyWords(with: contact.fingerprint) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                DSRoundGlassButton(systemName: "xmark", label: justAdded ? "Plus tard" : "Fermer") { close() }
            }
            .padding(.horizontal, DS.Space.margin)
            .padding(.top, 16)
            ScrollView {
                VStack(spacing: 0) {
                    DSAvatar(name: contact.name, size: 72, photo: model.photo(for: contact.fingerprint), verified: contact.verified)
                        .padding(.bottom, 14)
                    Text(justAdded ? "\(contact.name) est dans tes contacts" : "Vérifie avec \(contact.name)")
                        .font(DS.TextStyle.title2)
                        .foregroundStyle(DS.label)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Lis-lui ces quatre mots, en face ou au téléphone. S'ils sont les mêmes sur son écran, personne ne s'est glissé entre toi et \(contact.name).")
                        .font(DS.TextStyle.subheadline)
                        .foregroundStyle(DS.label2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .padding(.horizontal, 12)
                    VStack(spacing: 12) {
                        DSWordGrid(words: words)
                        let code = model.safetyCode(with: contact.fingerprint)
                        if !code.isEmpty {
                            Text(code)
                                .font(DS.TextStyle.fingerprint(13))
                                .foregroundStyle(DS.label3)
                                .accessibilityLabel("Code \(code)")
                        }
                    }
                    .padding(16)
                    .dsCard()
                    .padding(.top, 22)
                }
                .padding(.horizontal, DS.Space.margin)
                .padding(.top, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 12) {
                Button("Les mots sont identiques") {
                    model.setVerified(contact.fingerprint, true)
                    close()
                }
                .buttonStyle(.dsPrimary)
                Button("Ils sont différents") {
                    model.setVerified(contact.fingerprint, false)
                    Haptics.warning()
                    model.banner = "\(contact.name) reste non vérifié. Ne partage rien de sensible."
                    close()
                }
                .buttonStyle(.dsSecondary)
            }
            .padding(.horizontal, DS.Space.margin)
            .padding(.bottom, 12)
        }
        .background(DS.background.ignoresSafeArea())
        .presentationCornerRadius(DS.Radius.sheet)
    }

    private func close() {
        dismiss()
        done()
    }
}
