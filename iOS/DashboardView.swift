import SwiftUI

/// État du Mac et actions rapides.
struct DashboardView: View {
    @Environment(MacLink.self) private var link
    @State private var volume: Double = 50
    @State private var editingVolume = false
    @State private var urlText = ""
    @State private var appText = ""
    @State private var confirmSleep = false
    @State private var pendingCustom: CustomAction?

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                if link.isOnline {
                    statusSection
                    actionsSection
                    soundSection
                    openSection
                    customSection
                }
            }
            .navigationTitle(link.hello?.name ?? "Mac")
            .refreshable { @MainActor in
                if link.isOnline {
                    await link.refresh()
                } else {
                    link.connect()
                }
            }
            .task(id: link.isOnline) {
                // Rafraîchi toutes les 5 s tant que l'onglet est affiché.
                while link.isOnline && !Task.isCancelled {
                    await link.refresh()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .onChange(of: link.status?.volume) {
                if !editingVolume, let level = link.status?.volume {
                    volume = Double(level)
                }
            }
            .confirmationDialog("Mettre le Mac en veille ?", isPresented: $confirmSleep, titleVisibility: .visible) {
                Button("Mettre en veille", role: .destructive) {
                    Task { await link.perform(.sleep) }
                }
            } message: {
                Text("Il ne sera plus joignable depuis l'iPhone tant qu'il ne sera pas réveillé sur place.")
            }
            .confirmationDialog(pendingCustom?.label ?? "", isPresented: Binding(
                get: { pendingCustom != nil },
                set: { if !$0 { pendingCustom = nil } }
            ), titleVisibility: .visible) {
                Button("Lancer") {
                    if let action = pendingCustom {
                        Task { await link.runCustom(action) }
                    }
                }
            }
            .alert("Mac", isPresented: Binding(
                get: { link.notice != nil },
                set: { if !$0 { link.notice = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(link.notice ?? "")
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var connectionSection: some View {
        switch link.phase {
        case .online:
            EmptyView()
        case .connecting:
            Section {
                HStack {
                    ProgressView()
                    Text("Connexion au Mac…").padding(.leading, 8)
                }
            }
        case .offline:
            Section {
                Button("Se connecter") { link.connect() }
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Réessayer") { link.connect() }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let status = link.status {
            Section("État") {
                if let cpu = status.cpu {
                    Meter(label: "Processeur", value: cpu, text: percent(cpu))
                }
                if let used = status.memoryUsed, let total = status.memoryTotal, total > 0 {
                    Meter(label: "Mémoire", value: Double(used) / Double(total),
                          text: "\(bytes(used)) sur \(bytes(total))")
                }
                if let available = status.diskAvailable, let total = status.diskTotal, total > 0 {
                    Meter(label: "Disque", value: 1 - Double(available) / Double(total),
                          text: "\(bytes(available)) libres")
                }
                if let battery = status.battery {
                    LabeledContent("Batterie", value: batteryText(battery))
                }
                if let app = status.frontApp {
                    LabeledContent("Au premier plan", value: app)
                }
                if let thermal = status.thermal, thermal != "nominal" {
                    LabeledContent("Température", value: thermalText(thermal))
                        .foregroundStyle(.orange)
                }
                if let uptime = status.uptime {
                    LabeledContent("Allumé depuis", value: duration(uptime))
                }
                if !status.permissions.input || !status.permissions.screen {
                    Label(permissionText(status.permissions), systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                ActionTile(title: "Verrouiller", systemImage: "lock.fill") {
                    Task { await link.perform(.lock) }
                }
                ActionTile(title: "Écran noir", systemImage: "display") {
                    Task { await link.perform(.displaySleep) }
                }
                ActionTile(title: "Veille", systemImage: "moon.fill") {
                    confirmSleep = true
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var soundSection: some View {
        Section("Son") {
            HStack(spacing: 28) {
                Spacer()
                Button { Task { await link.perform(.previous) } } label: {
                    Image(systemName: "backward.fill")
                }
                Button { Task { await link.perform(.playPause) } } label: {
                    Image(systemName: "playpause.fill").font(.title2)
                }
                Button { Task { await link.perform(.next) } } label: {
                    Image(systemName: "forward.fill")
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.title3)

            if link.status?.volume != nil {
                HStack {
                    Button {
                        let muted = link.status?.muted ?? false
                        Task { await link.perform(muted ? .unmute : .mute) }
                    } label: {
                        Image(systemName: link.status?.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 28)
                    }
                    .buttonStyle(.borderless)
                    Slider(value: $volume, in: 0...100, step: 1, onEditingChanged: { editing in
                        editingVolume = editing
                        if !editing {
                            Task { await link.setVolume(Int(volume)) }
                        }
                    })
                    Text("\(Int(volume))").monospacedDigit().frame(width: 32, alignment: .trailing)
                }
            } else {
                Text("Volume non réglable sur cette sortie audio").foregroundStyle(.secondary)
            }
        }
    }

    private var openSection: some View {
        Section("Ouvrir sur le Mac") {
            HStack {
                TextField("Adresse web", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { openURL() }
                Button("Ouvrir") { openURL() }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                TextField("Application (ex. Safari)", text: $appText)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { openApp() }
                Menu {
                    ForEach(link.runningApps, id: \.self) { app in
                        Button(app) { Task { await link.open(app: app) } }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                Button("Ouvrir") { openApp() }
                    .disabled(appText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .buttonStyle(.borderless)
            .task { await link.loadApps() }
        }
    }

    @ViewBuilder
    private var customSection: some View {
        if let actions = link.hello?.actions, !actions.isEmpty {
            Section("Mes actions") {
                ForEach(actions) { action in
                    Button(action.label) {
                        if action.confirm {
                            pendingCustom = action
                        } else {
                            Task { await link.runCustom(action) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Gestes

    private func openURL() {
        let text = urlText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            await link.open(url: text)
            urlText = ""
        }
    }

    private func openApp() {
        let text = appText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            await link.open(app: text)
            appText = ""
        }
    }

    // MARK: Mise en forme

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private func batteryText(_ battery: Battery) -> String {
        var text = "\(battery.level) %"
        if battery.charging {
            text += " · en charge"
        } else if battery.onAC {
            text += " · sur secteur"
        } else if let minutes = battery.minutesLeft {
            text += " · \(minutes / 60) h \(String(format: "%02d", minutes % 60)) restantes"
        }
        return text
    }

    private func thermalText(_ state: String) -> String {
        switch state {
        case "fair": return "Élevée"
        case "serious": return "Très élevée"
        case "critical": return "Critique"
        default: return "Normale"
        }
    }

    private func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "—"
    }

    private func permissionText(_ permissions: Permissions) -> String {
        var missing: [String] = []
        if !permissions.input { missing.append("Accessibilité") }
        if !permissions.screen { missing.append("Enregistrement de l'écran") }
        return "Autorisation à donner sur le Mac : " + missing.joined(separator: ", ")
    }
}

private struct Meter: View {
    let label: String
    let value: Double
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(text).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: min(max(value, 0), 1))
                .tint(value > 0.9 ? .orange : .accentColor)
        }
        .padding(.vertical, 2)
    }
}

private struct ActionTile: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(.footnote)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
