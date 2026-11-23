import SwiftUI

extension EnvironmentValues {
    /// Opens Réglages (a sheet over the tabs), from the avatar at the top left of every tab.
    @Entry var openSettings: () -> Void = {}
}

/// The avatar at the top left of a tab, in a round glass button: opens Réglages.
struct ProfileToolbarButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            Haptics.tap()
            openSettings()
        } label: {
            DSAvatar(name: model.displayName, size: 36, photo: model.photos[AppModel.me])
        }
        .accessibilityLabel("Réglages")
        .accessibilityHint("Ton profil et les réglages de Relay")
        .accessibilityIdentifier("settings.open")
    }
}

extension View {
    /// Shared chrome of the three tabs: large title, the avatar at the top left.
    func dsTabChrome(title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ProfileToolbarButton() }
            }
    }
}
