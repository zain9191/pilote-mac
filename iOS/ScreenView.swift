import SwiftUI

/// Bureau à distance : l'écran du Mac et une barre de touches.
struct ScreenView: View {
    @Environment(MacLink.self) private var link
    @AppStorage("screenQuality") private var qualityRaw = MacLink.Quality.standard.rawValue
    @State private var typing = false
    @State private var modifiers: Set<Modifier> = []

    private var quality: MacLink.Quality {
        MacLink.Quality(rawValue: qualityRaw) ?? .standard
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RemoteScreen(link: link)
                overlay
            }
            keyBar
            KeyCatcher(active: $typing, onText: { typed($0) }, onDelete: { press(SpecialKey.delete.rawValue) })
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .background(Color.black)
        .task(id: link.isOnline) {
            if link.isOnline {
                await link.startScreen(quality: quality)
            }
        }
        .onChange(of: qualityRaw) {
            Task { await link.startScreen(quality: quality) }
        }
        .onDisappear {
            typing = false
            link.stopScreen()
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if !link.isOnline {
            message("Mac non connecté", systemImage: "wifi.slash")
        } else if let error = link.screenError {
            message(error, systemImage: "exclamationmark.triangle")
        } else if link.screen == nil {
            ProgressView().tint(.white)
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(.white)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    typing.toggle()
                } label: {
                    Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .buttonStyle(KeyStyle(active: typing))

                ForEach(Modifier.allCases, id: \.self) { modifier in
                    Button(modifier.symbol) {
                        if modifiers.contains(modifier) {
                            modifiers.remove(modifier)
                        } else {
                            modifiers.insert(modifier)
                        }
                    }
                    .buttonStyle(KeyStyle(active: modifiers.contains(modifier)))
                }

                key("esc", .escape)
                key("⇥", .tab)
                key("⏎", .return)
                key("⌫", .delete)
                key("←", .left)
                key("↑", .up)
                key("↓", .down)
                key("→", .right)

                Menu {
                    Picker("Qualité", selection: $qualityRaw) {
                        ForEach(MacLink.Quality.allCases) { quality in
                            Text(quality.label).tag(quality.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(KeyStyle(active: false))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func key(_ label: String, _ key: SpecialKey) -> some View {
        Button(label) { press(key.rawValue) }
            .buttonStyle(KeyStyle(active: false))
    }

    /// Avec un modificateur actif, la frappe devient un raccourci (⌘C…), puis
    /// les modificateurs se relâchent.
    private func typed(_ text: String) {
        if text == "\n" {
            press(SpecialKey.return.rawValue)
        } else if text == "\t" {
            press(SpecialKey.tab.rawValue)
        } else if !modifiers.isEmpty, text.count == 1 {
            press(text)
        } else {
            link.type(text)
        }
    }

    private func press(_ key: String) {
        link.press(key, modifiers: Modifier.allCases.filter(modifiers.contains))
        modifiers.removeAll()
    }
}

private struct KeyStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(minWidth: 44, minHeight: 40)
            .padding(.horizontal, 4)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(active ? Color.accentColor : Color(.secondarySystemFill),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
