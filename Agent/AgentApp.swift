import AppKit
import SwiftUI

@main
struct PiloteAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            AgentMenu(model: delegate.model)
        } label: {
            MenuIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AgentModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }
}

/// Icône de la barre des menus : une vue à part, pour que l'observation du
/// nombre de clients la redessine à coup sûr.
struct MenuIcon: View {
    let model: AgentModel

    var body: some View {
        Image(systemName: model.clients > 0 ? "iphone.radiowaves.left.and.right" : "iphone")
    }
}

struct AgentMenu: View {
    let model: AgentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pilote").font(.headline)
                Label(model.listening,
                      systemImage: model.listenFailed ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(model.listenFailed ? Color.red : Color.secondary)
                Text(clientsText).foregroundStyle(.secondary)
            }
            .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Autorisations").font(.subheadline.weight(.semibold))
                PermissionRow(title: "Clavier, souris, verrouillage", granted: model.canControl) {
                    model.requestControl()
                }
                PermissionRow(title: "Bureau à distance (écran)", granted: model.canCapture) {
                    model.requestCapture()
                }
                if !model.canCapture {
                    Text("Après l'autorisation de l'écran, quitter et relancer l'agent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Jumelage").font(.subheadline.weight(.semibold))
                HStack {
                    Button("Copier le jeton") { model.copyToken() }
                    Button("Nouveau jeton") { model.regenerateToken() }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Actions personnalisées : \(model.actionCount)").font(.subheadline.weight(.semibold))
                HStack {
                    Button("Modifier…") { model.openConfig() }
                    Button("Relire") { model.reloadConfig() }
                }
                if let error = model.configError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Divider()

            Toggle("Lancer à l'ouverture de session", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }

    private var clientsText: String {
        switch model.clients {
        case 0: return "Aucun iPhone connecté"
        case 1: return "1 iPhone connecté"
        default: return "\(model.clients) iPhone connectés"
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: @MainActor () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if !granted {
                Button("Autoriser") { action() }
            }
        }
    }
}
