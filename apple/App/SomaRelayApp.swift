import SwiftUI

@main
struct SomaRelayApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { model.start() }
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.saveNow() }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch model.phase {
            case .loading:
                RelayMark().frame(width: 72)
            case .onboarding:
                OnboardingView()
                    .transition(.opacity)
            case .ready:
                MainTabs()
                    .transition(.opacity)
            }
        }
        .tint(Theme.mesh)
        .overlay(alignment: .top) { BannerView() }
        .fullScreenCover(isPresented: Binding(get: { model.calls.presented }, set: { model.calls.presented = $0 })) {
            CallView()
        }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.conversations

    enum Tab: Hashable { case conversations, contacts, settings }

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("Conversations", systemImage: "bubble.left.and.bubble.right", value: Tab.conversations) {
                ConversationsView()
            }
            .badge(model.conversations.reduce(0) { $0 + $1.unread })
            SwiftUI.Tab("Répertoire", systemImage: "person.2", value: Tab.contacts) {
                ContactsView()
            }
            SwiftUI.Tab("Réglages", systemImage: "gearshape", value: Tab.settings) {
                SettingsView()
            }
        }
        .onAppear {
            switch DemoData.screen {
            case "contacts", "qr": tab = .contacts
            case "settings": tab = .settings
            case "call": model.calls.showDemo(peer: DemoData.ines)
            default: break
            }
        }
    }
}

/// Short messages from the model (errors, confirmations), glass capsule at the top.
struct BannerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.banner {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { model.banner = nil }
                .task(id: text) {
                    UIAccessibility.post(notification: .announcement, argument: text)
                    try? await Task.sleep(for: .seconds(3.5))
                    withAnimation(.smooth) { model.banner = nil }
                }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}
