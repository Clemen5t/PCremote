import SwiftUI

struct SettingsView: View {
    @AppStorage("pc.host") private var host = "192.168.1.10"
    @AppStorage("pc.port") private var port = "8765"
    @AppStorage("pc.mac") private var mac = ""
    @AppStorage("pc.broadcast") private var broadcast = "255.255.255.255"
    @AppStorage("pc.secret") private var secret = ""

    var body: some View {
        Form {
            Section("PC") {
                TextField("IP du PC", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Port", text: $port)
                    .keyboardType(.numberPad)

                TextField("Adresse MAC", text: $mac)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            Section("Wake-on-LAN") {
                TextField("Broadcast", text: $broadcast)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("Exemple : 192.168.1.255 pour un réseau 192.168.1.x/24.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Sécurité") {
                SecureField("Clé secrète", text: $secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("La clé signe chaque commande avec HMAC-SHA256 et n’est pas envoyée telle quelle au PC.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Réglages")
        .navigationBarTitleDisplayMode(.inline)
    }
}
