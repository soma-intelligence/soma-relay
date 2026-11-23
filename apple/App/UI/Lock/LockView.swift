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

    /// Unread messages: a count only, never a name or a preview.
    var unread = 0

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                BrandMark().frame(width: 116)
                    .background { BrandHalo().frame(width: 640, height: 640) }
                    .padding(.bottom, 36)
                Text("Relay est verrouillé")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(DS.label)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(DS.TextStyle.body)
                    .foregroundStyle(lock.failed ? DS.danger : DS.label2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 32)
                    .contentTransition(.opacity)
                if unread > 0, !coverOnly {
                    unreadCapsule.padding(.top, 28)
                }
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
        return "Tes messages continuent d'arriver.\nDéverrouille pour les lire."
    }

    private var unreadCapsule: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(DS.label3)
            Text("Nouveaux messages")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DS.label)
            DSCountBadge(count: unread)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 40)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unread == 1 ? "1 nouveau message" : "\(unread) nouveaux messages")
    }

    private var buttons: some View {
        VStack(spacing: 14) {
            Button {
                Haptics.tap()
                Task { await lock.unlock() }
            } label: {
                Label("Déverrouiller", systemImage: "key.fill")
            }
            .buttonStyle(.dsPrimary)
            .disabled(lock.busy)
            .accessibilityLabel("Déverrouiller")
            if lock.showsDeviceFallback {
                Button {
                    Haptics.tap()
                    Task { await lock.unlockWithDevice() }
                } label: {
                    Text("Utiliser Face ID ou le code")
                        .font(DS.TextStyle.headline)
                        .foregroundStyle(DS.label)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(lock.busy)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}
