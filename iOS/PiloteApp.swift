import SwiftUI

@main
struct PiloteApp: App {
    @State private var link = MacLink()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(link)
        }
        .onChange(of: scenePhase) {
            // iOS suspend l'app en arrière-plan : on coupe proprement, on se
            // reconnecte au retour.
            switch scenePhase {
            case .active:
                link.connectIfNeeded()
            case .background:
                link.disconnect()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @Environment(MacLink.self) private var link
    @State private var tab = Settings.isComplete ? 0 : 2

    var body: some View {
        TabView(selection: $tab) {
            DashboardView()
                .tabItem { Label("Mac", systemImage: "laptopcomputer") }
                .tag(0)
            ScreenView()
                .tabItem { Label("Écran", systemImage: "rectangle.on.rectangle") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
                .tag(2)
        }
        .task { link.connectIfNeeded() }
    }
}
