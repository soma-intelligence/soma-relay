import SwiftUI

@main
struct SomaRelayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    private var model: AppModel { delegate.model }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { model.start() }
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        model.lock.didEnterBackground(at: Date())
                        model.didEnterBackground()
                    case .inactive:
                        // Coming back from the background: relock before the first active frame.
                        model.lock.willEnterForeground(at: Date())
                    case .active:
                        model.lock.willEnterForeground(at: Date())
                        model.didBecomeActive()
                    @unknown default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch model.phase {
            case .loading:
                BrandMark().frame(width: 72)
            case .onboarding:
                OnboardingView()
                    .transition(.opacity)
            case .ready:
                MainTabs()
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(lockShown)
        .tint(Theme.mesh)
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                MessageBannerView()
                BannerView()
            }
        }
        .fullScreenCover(isPresented: Binding(get: { model.calls.presented }, set: { model.calls.presented = $0 })) {
            CallView()
        }
        .background {
            // The lock lives in its own window above every sheet, cover and dialog (CallView too).
            LockWindowHost(
                lock: model.lock,
                visible: lockGate && (model.lock.isLocked || scenePhase != .active),
                coverOnly: !model.lock.isLocked,
                sceneActive: scenePhase == .active)
        }
    }

    private var lockGate: Bool { model.phase != .onboarding && model.lock.enabled }
    private var lockShown: Bool { lockGate && model.lock.isLocked }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.conversations
    @State private var showSettings = false

    enum Tab: Hashable { case conversations, nearby, contacts, search }

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("Discussions", systemImage: "bubble.left.and.bubble.right.fill", value: Tab.conversations) {
                ConversationsView()
            }
            .badge(model.conversations.filter { $0.kind != .channel }.reduce(0) { $0 + $1.unread })
            SwiftUI.Tab("À proximité", systemImage: "dot.radiowaves.left.and.right", value: Tab.nearby) {
                NearbyView()
            }
            SwiftUI.Tab("Contacts", systemImage: "person.2.fill", value: Tab.contacts) {
                ContactsView()
            }
            SwiftUI.Tab(value: Tab.search, role: .search) {
                SearchTabView()
            }
        }
        .tint(DS.accent)
        .environment(\.openSettings, { showSettings = true })
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onChange(of: model.openRequest) { _, request in
            guard request != nil else { return }
            showSettings = false
            if tab != .conversations { tab = .conversations }
        }
        .onAppear {
            switch DemoData.screen {
            case "contacts", "qr", "qr-verify": tab = .contacts
            case "nearby", "channels": tab = .nearby
            case "list-search": tab = .search
            case "settings": showSettings = true
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

/// A message in another conversation: glass card at the top with the face, the name and the
/// preview. Tap opens it, swipe up dismisses, it goes by itself after 4 s.
struct MessageBannerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0

    var body: some View {
        if let banner = model.messageBanner {
            HStack(spacing: 12) {
                Avatar(
                    name: banner.title, size: 42, icon: banner.isGroup ? "person.3.fill" : nil,
                    photo: banner.photoKey.flatMap { model.photos[$0] })
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(banner.preview)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 560)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: Theme.shadow, radius: 18, y: 8)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .offset(y: min(0, drag) + max(0, drag) * 0.15)
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.tap()
                model.openRequest = ChatRoute(conversationId: banner.conversationId, focus: nil)
                dismiss()
            }
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height < -30 || value.predictedEndTranslation.height < -80 {
                            dismiss()
                        } else {
                            withAnimation(.spring(duration: 0.3, bounce: 0.3)) { drag = 0 }
                        }
                    })
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            .id(banner.id)
            .task(id: banner.id) {
                drag = 0
                Haptics.soft()
                UIAccessibility.post(notification: .announcement, argument: "\(banner.title) : \(banner.preview)")
                try? await Task.sleep(for: .seconds(4))
                if model.messageBanner?.id == banner.id { dismiss() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Ouvre la conversation")
            .accessibilityAction(named: "Fermer") { dismiss() }
        }
    }

    private func dismiss() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.1)) {
            model.messageBanner = nil
        }
    }
}
