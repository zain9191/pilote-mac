import SwiftUI
import UIKit

/// Adresse du Mac et jeton de jumelage.
struct SettingsView: View {
    @Environment(MacLink.self) private var link
    @State private var address = Settings.address
    @State private var token = Settings.token ?? ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("mac.tailXXXX.ts.net", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !address.isEmpty {
                        if let url = Address.url(from: address) {
                            Text(url.absoluteString).font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Adresse illisible").font(.footnote).foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Adresse du Mac")
                } footer: {
                    Text("Le nom Tailscale du Mac (affiché par l'app Tailscale), ou son adresse 100.x.y.z si l'agent écoute en direct.")
                }

                Section {
                    HStack {
                        SecureField("Jeton", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Coller") {
                            token = UIPasteboard.general.string?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? token
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Jeton")
                } footer: {
                    Text("Sur le Mac : menu Pilote › Copier le jeton. Avec le même identifiant Apple, il arrive dans le presse-papiers de l'iPhone. Il est rangé dans le trousseau de l'iPhone.")
                }

                Section {
                    Button("Enregistrer et se connecter") {
                        Settings.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        Settings.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved = true
                        link.connect()
                    }
                    .disabled(Address.url(from: address) == nil || token.isEmpty)

                    if saved {
                        stateLabel
                    }
                }

                if link.isOnline {
                    Section {
                        Button("Se déconnecter", role: .destructive) { link.disconnect() }
                    }
                }
            }
            .navigationTitle("Réglages")
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch link.phase {
        case .online:
            Label("Connecté à \(link.hello?.name ?? "ton Mac")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .connecting:
            Label("Connexion…", systemImage: "hourglass")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .offline:
            EmptyView()
        }
    }
}
