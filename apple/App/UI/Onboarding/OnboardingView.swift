import SwiftUI

/// Name, identity creation (post-quantum keys), then the QR card.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = Step.welcome
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    enum Step: Int { case welcome, name, creating, card }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome: welcome
            case .name: nameStep
            case .creating: creating
            case .card: card
            }
        }
        .padding(.horizontal, 24)
        .animation(.smooth(duration: 0.35), value: step)
        .onAppear {
            if DemoData.screen == "onboarding-card" { name = "Quentin"; create() }
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            RelayMark().frame(width: 112)
            Text("Soma Relay")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("Tes messages passent de téléphone en téléphone, même sans réseau ni Internet.")
                .font(.title3)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                feature("dot.radiowaves.left.and.right", "Bluetooth et Wi-Fi direct entre téléphones proches")
                feature("lock.shield", "Chiffré de bout en bout, post-quantique")
                feature("person.crop.circle.badge.questionmark", "Ni numéro, ni e-mail : juste une clé")
            }
            .padding(.top, 12)
            Spacer()
            primary("Commencer") { step = .name }
            Text("Code ouvert sous licence AGPL.")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 12)
        }
        .transition(.opacity)
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.mesh)
                .frame(width: 28)
            Text(text).font(.body).foregroundStyle(Theme.text)
        }
        .accessibilityElement(children: .combine)
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer().frame(height: 40)
            Text("Comment on t'appelle ?")
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.text)
            Text("Ton prénom ou un surnom. Il voyage avec ta carte, tu peux le changer quand tu veux.")
                .foregroundStyle(Theme.secondary)
            TextField("Prénom", text: $name)
                .font(.title2)
                .textContentType(.givenName)
                .submitLabel(.done)
                .focused($nameFocused)
                .padding(.horizontal, 18)
                .frame(height: 56)
                .glassBar(radius: 22)
                .onSubmit(create)
                .accessibilityLabel("Ton prénom")
            Spacer()
            primary("Créer mon identité", disabled: name.trimmingCharacters(in: .whitespaces).isEmpty, action: create)
                .padding(.bottom, 12)
        }
        .onAppear { nameFocused = true }
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }

    private var creating: some View {
        VStack(spacing: 22) {
            Spacer()
            CipherQRCode(stage: .connecting)
                .frame(width: 220)
            Text("Génération de tes clés")
                .font(.title2.bold())
                .foregroundStyle(Theme.text)
            Text("ML-KEM-1024 + X25519 · ML-DSA-87 + Ed25519")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.secondary)
            Spacer()
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private var card: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 24)
            Text("Ta carte est prête")
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.text)
            Text("Fais scanner ce QR pour qu'on t'ajoute. Ta clé ne quitte jamais ce téléphone.")
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            if let link = model.myCompactLink {
                CipherQRCode(stage: .code(link))
                    .frame(maxWidth: 280)
                    .accessibilityLabel("QR de ta carte de contact")
            }
            if let core = model.core {
                VStack(spacing: 6) {
                    Text(core.fingerprintHex().groupedFingerprint(groups: 4))
                        .font(Theme.mono(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(core.safetyWords().joined(separator: " · "))
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Ton empreinte")
            }
            Spacer()
            primary("C'est parti") { model.finishOnboarding() }
                .padding(.bottom, 12)
        }
        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
    }

    private func primary(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(disabled)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        nameFocused = false
        step = .creating
        Task {
            let started = Date()
            await model.createIdentity(name: trimmed)
            // Let the cipher play a moment: the user should see that keys were made.
            let wait = max(0, 1.4 - Date().timeIntervalSince(started))
            try? await Task.sleep(for: .seconds(wait))
            Haptics.success()
            step = .card
        }
    }
}
