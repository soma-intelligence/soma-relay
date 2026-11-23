import SwiftUI

/// "Suggérer une fonctionnalité" from Réglages: the idea, an optional e-mail, then one POST to
/// Soma Labs. The amber note says it plainly: this leaves the encrypted messaging. On an error the
/// text stays so nothing is lost.
struct FeatureRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message: String
    @State private var email = ""
    @State private var sending = false
    @State private var sent = false
    @State private var failure: FeatureRequestClient.Failure?
    @FocusState private var focus: Field?

    private enum Field { case message, email }

    private let client: FeatureRequestClient

    init(client: FeatureRequestClient = FeatureRequestClient(), demo: Bool = false) {
        self.client = client
        _message = State(initialValue: demo ? "Pouvoir épingler une conversation en haut de la liste." : "")
    }

    private var count: Int { FeatureRequestClient.trimmed(message).count }
    private var canSend: Bool { FeatureRequestClient.canSend(message) && !sending && !sent }

    var body: some View {
        NavigationStack {
            Group {
                if sent { confirmation } else { form }
            }
            .background(DS.background)
            .navigationTitle("Suggérer une fonctionnalité")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                        .tint(DS.label)
                        .disabled(sending)
                }
            }
            .onAppear { if message.isEmpty { focus = .message } }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(sending)
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: DS.Space.group) {
                DSSection(header: "Ton idée") {
                    DSRow(first: true, minHeight: 140) {
                        TextField("Qu'est-ce qui rendrait l'app meilleure pour toi ?", text: $message, axis: .vertical)
                            .font(DS.TextStyle.body)
                            .foregroundStyle(DS.label)
                            .lineLimit(5...14)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                            .focused($focus, equals: .message)
                            .onChange(of: message) { _, text in
                                if text.count > FeatureRequestClient.maxLength {
                                    message = String(text.prefix(FeatureRequestClient.maxLength))
                                }
                                failure = nil
                            }
                            .accessibilityLabel("Ton idée")
                            .accessibilityHint("Au moins \(FeatureRequestClient.minLength) caractères")
                            .accessibilityIdentifier("feature.message")
                    }
                } footer: {
                    if let failure {
                        Text(failure.message)
                            .foregroundStyle(DS.danger)
                            .accessibilityIdentifier("feature.error")
                    } else {
                        Text(verbatim: "\(count) / \(FeatureRequestClient.maxLength)")
                            .monospacedDigit()
                            .accessibilityLabel("\(count) caractères sur \(FeatureRequestClient.maxLength)")
                    }
                }
                DSSection(header: "E-mail (facultatif)") {
                    DSRow(first: true) {
                        TextField("toi@exemple.com", text: $email)
                            .font(DS.TextStyle.body)
                            .foregroundStyle(DS.label)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .email)
                            .submitLabel(.send)
                            .onSubmit(send)
                            .onChange(of: email) { _, _ in if failure == .invalidEmail { failure = nil } }
                            .accessibilityLabel("E-mail, facultatif")
                            .accessibilityIdentifier("feature.email")
                    }
                } footer: {
                    Text("Seulement si tu veux qu'on te réponde.")
                }
                DSWarningNote(text: "Ton idée et ton e-mail partent à Soma Labs par une connexion HTTPS classique, en dehors de la messagerie chiffrée. Ils ne passent ni par le mesh ni par ton nœud.")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.margin + DS.Space.cell)
                    .accessibilityIdentifier("feature.privacy")
                Button(action: send) {
                    HStack(spacing: 8) {
                        if sending { ProgressView().tint(DS.onAccent) }
                        Text(sending ? "Envoi…" : "Envoyer")
                    }
                }
                .buttonStyle(.dsPrimary)
                .disabled(!canSend)
                .padding(.horizontal, DS.Space.margin)
                .accessibilityIdentifier("feature.send")
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var confirmation: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(DS.accent)
                .accessibilityHidden(true)
            Text("Merci, on lit chaque idée.")
                .font(DS.TextStyle.title3)
                .foregroundStyle(DS.label)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, DS.Space.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feature.thanks")
        .transition(.opacity)
    }

    private func send() {
        guard canSend else { return }
        focus = nil
        sending = true
        failure = nil
        let text = message
        let mail = email
        Task {
            defer { sending = false }
            do throws(FeatureRequestClient.Failure) {
                _ = try await client.send(message: text, email: mail)
                Haptics.success()
                withAnimation(.smooth) { sent = true }
                UIAccessibility.post(notification: .announcement, argument: "Merci, on lit chaque idée.")
                try? await Task.sleep(for: .seconds(1.6))
                dismiss()
            } catch {
                Haptics.warning()
                failure = error
            }
        }
    }
}
