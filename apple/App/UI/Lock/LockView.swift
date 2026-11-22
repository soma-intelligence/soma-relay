import SwiftUI

/// Full-screen lock, shown in its own window above every sheet (`LockWindowHost`). Also the
/// privacy cover of the app switcher snapshot: when Relay is not active and not locked, it shows
/// the same screen without the buttons.
struct LockView: View {
    let lock: LockController
    /// The cover drawn while the scene is inactive or in the background, not a real lock.
    var coverOnly = false
    /// The scene is active. Passed in: this view lives in a window SwiftUI's scene phase does not reach.
    var sceneActive = true

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                RelayMark().frame(width: 76)
                    .padding(.bottom, 28)
                Text("Relay est verrouillé")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)
                    .contentTransition(.opacity)
                Spacer()
                if !coverOnly {
                    buttons
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: 480)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(coverOnly ? "lock.cover" : "lock.screen")
        .task(id: sceneActive) {
            // A passkey sheet or Face ID needs a foreground scene.
            guard !coverOnly, sceneActive else { return }
            await lock.autoStartIfNeeded()
        }
        .animation(.smooth, value: lock.showsDeviceFallback)
        .animation(.smooth, value: lock.failed)
    }

    private var subtitle: String {
        if lock.failed { return "Ça n'a pas marché. Réessaie." }
        if lock.showsDeviceFallback { return "Ta clé d'accès n'a pas répondu. Tu peux utiliser Face ID ou le code de ton téléphone." }
        return "Tes messages continuent d'arriver. Déverrouille pour les lire."
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            Button {
                Haptics.tap()
                Task { await lock.unlock() }
            } label: {
                Text("Déverrouiller")
                    .font(.headline)
                    .foregroundStyle(Theme.onMesh)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(lock.busy)
            if lock.showsDeviceFallback {
                Button {
                    Haptics.tap()
                    Task { await lock.unlockWithDevice() }
                } label: {
                    Text("Utiliser Face ID ou le code")
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(lock.busy)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}
