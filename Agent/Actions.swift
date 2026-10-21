import AppKit
import Foundation

/// Lancement de commandes système, sans shell : chemin absolu et arguments.
enum Shell {
    struct Result {
        var status: Int32
        var output: String
        /// `false` si la commande tournait encore à l'échéance.
        var finished: Bool
    }

    /// `capture` : lire la sortie standard. Réservé aux commandes brèves et peu
    /// bavardes ; à l'échéance, une commande capturée est arrêtée. Sans capture,
    /// elle continue de tourner (une action comme `caffeinate -t 3600` le doit).
    static func run(_ path: String, _ arguments: [String], capture: Bool = false,
                    timeout: TimeInterval = 10) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = capture ? pipe : FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription, finished: true)
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            if capture {
                process.terminate()
            }
            return Result(status: 0, output: "", finished: false)
        }
        let output = capture
            ? String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return Result(status: process.terminationStatus, output: output, finished: true)
    }

    static func appleScript(_ source: String) -> String? {
        let result = run("/usr/bin/osascript", ["-e", source], capture: true, timeout: 5)
        return result.finished && result.status == 0 ? result.output : nil
    }
}

/// Actions rapides. Appelées hors du fil principal : ce qui touche AppKit ou
/// l'injection d'événements y est renvoyé explicitement.
enum Actions {
    static func perform(_ action: ActionName) throws {
        switch action {
        case .lock:
            // Raccourci système ⌃⌘Q, résolu selon la disposition du clavier.
            try onMain {
                try Input.requireAccess()
                try Input.press("q", modifiers: [Modifier.control.rawValue, Modifier.cmd.rawValue])
            }
        case .sleep:
            // Délai : laisser partir la réponse avant que le Mac ne s'endorme.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                _ = Shell.run("/usr/bin/pmset", ["sleepnow"])
            }
        case .displaySleep:
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                _ = Shell.run("/usr/bin/pmset", ["displaysleepnow"])
            }
        case .playPause:
            try media(.playPause)
        case .next:
            try media(.next)
        case .previous:
            try media(.previous)
        case .mute, .unmute:
            let muted = action == .mute
            guard Shell.appleScript("set volume output muted \(muted)") != nil else {
                throw AgentError("Impossible de changer la sourdine")
            }
        }
    }

    static func setVolume(_ level: Int) throws {
        let value = min(max(level, 0), 100)
        guard Shell.appleScript("set volume output volume \(value)") != nil else {
            throw AgentError("Impossible de régler le volume")
        }
    }

    /// Volume de sortie et sourdine. `nil` quand la sortie n'a pas de volume
    /// réglable (certains écrans HDMI, par exemple).
    static func volume() -> (level: Int?, muted: Bool?) {
        let script = """
        set s to get volume settings
        return ((output volume of s) as text) & "," & ((output muted of s) as text)
        """
        guard let output = Shell.appleScript(script) else { return (nil, nil) }
        let parts = output.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return (nil, nil) }
        return (Int(parts[0]), parts[1] == "true" ? true : parts[1] == "false" ? false : nil)
    }

    /// N'ouvre que du web : un `file://` ou un schéma d'app arbitraire depuis le
    /// téléphone n'a pas d'usage ici et élargirait la surface d'attaque.
    static func open(url text: String) throws {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { throw AgentError("Seules les adresses http et https sont acceptées") }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    /// Ouvre une app par son nom, ou la passe au premier plan si elle tourne.
    static func open(app name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentError("Nom d'application vide") }
        let result = Shell.run("/usr/bin/open", ["-a", trimmed])
        guard result.finished, result.status == 0 else {
            throw AgentError("Application introuvable : \(trimmed)")
        }
    }

    /// Applications ouvertes (celles qui ont une icône dans le Dock), triées.
    static func runningApps() -> [String] {
        DispatchQueue.main.sync {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.localizedName)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    /// Lance une action de `config.json`. Attend sa fin jusqu'à 15 s.
    static func run(_ action: ConfiguredAction) throws -> String {
        guard let executable = action.command.first else { throw AgentError("Commande vide") }
        let result = Shell.run(executable, Array(action.command.dropFirst()), timeout: 15)
        if !result.finished {
            return "« \(action.label) » lancée, toujours en cours"
        }
        guard result.status == 0 else {
            throw AgentError("« \(action.label) » a échoué (code \(result.status))")
        }
        return "« \(action.label) » terminée"
    }

    private static func media(_ key: Input.MediaKey) throws {
        try onMain {
            try Input.requireAccess()
            Input.media(key)
        }
    }

    private static func onMain(_ work: () throws -> Void) throws {
        if Thread.isMainThread {
            try work()
        } else {
            try DispatchQueue.main.sync(execute: work)
        }
    }
}
