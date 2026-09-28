import SwiftUI

private enum PendingPowerAction {
    case shutdown
    case restart

    var title: String {
        switch self {
        case .shutdown: return "Éteindre le PC"
        case .restart: return "Redémarrer le PC"
        }
    }

    var message: String {
        switch self {
        case .shutdown: return "Le PC va s’éteindre immédiatement."
        case .restart: return "Le PC va redémarrer immédiatement."
        }
    }
}

struct ContentView: View {
    @AppStorage("pc.host") private var host = "192.168.1.10"
    @AppStorage("pc.port") private var portText = "8765"
    @AppStorage("pc.mac") private var mac = ""
    @AppStorage("pc.broadcast") private var broadcast = "255.255.255.255"
    @AppStorage("pc.secret") private var secret = ""

    @State private var isOnline = false
    @State private var isBusy = false
    @State private var statusMessage = "Vérification…"
    @State private var pendingAction: PendingPowerAction?
    @State private var showConfirm = false

    private var port: Int {
        Int(portText) ?? 8765
    }

    private var client: PCClient {
        PCClient(host: host, port: port, secret: secret)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 16)

                Image(systemName: "desktopcomputer")
                    .font(.system(size: 72, weight: .light))
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isOnline ? Color.green : Color.gray)
                            .frame(width: 12, height: 12)

                        Text(isOnline ? "PC EN LIGNE" : "PC HORS LIGNE")
                            .font(.headline)
                    }

                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    Button {
                        Task { await wakePC() }
                    } label: {
                        Label("Allumer", systemImage: "power")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || mac.isEmpty)

                    Button {
                        pendingAction = .restart
                        showConfirm = true
                    } label: {
                        Label("Redémarrer", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || !isOnline)

                    Button(role: .destructive) {
                        pendingAction = .shutdown
                        showConfirm = true
                    } label: {
                        Label("Éteindre", systemImage: "power.circle.fill")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || !isOnline)
                }

                if isBusy {
                    ProgressView()
                }

                Spacer()

                Button {
                    Task { await refreshStatus() }
                } label: {
                    Label("Actualiser", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isBusy)
            }
            .padding()
            .navigationTitle("PC Remote")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .task {
                await refreshStatus()
            }
            .alert(
                pendingAction?.title ?? "Confirmer",
                isPresented: $showConfirm,
                presenting: pendingAction
            ) { action in
                Button(action.title, role: .destructive) {
                    Task { await run(action) }
                }
                Button("Annuler", role: .cancel) {}
            } message: { action in
                Text(action.message)
            }
        }
    }

    @MainActor
    private func refreshStatus() async {
        guard !host.isEmpty, !secret.isEmpty else {
            isOnline = false
            statusMessage = "Configure l’IP et la clé dans Réglages."
            return
        }

        do {
            try await client.status()
            isOnline = true
            statusMessage = "\(host):\(port)"
        } catch {
            isOnline = false
            statusMessage = "Le PC ne répond pas."
        }
    }

    @MainActor
    private func run(_ action: PendingPowerAction) async {
        isBusy = true
        defer { isBusy = false }

        do {
            switch action {
            case .shutdown:
                try await client.shutdown()
                statusMessage = "Commande d’extinction envoyée."

            case .restart:
                try await client.restart()
                statusMessage = "Commande de redémarrage envoyée."
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshStatus()

        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func wakePC() async {
        isBusy = true
        statusMessage = "Envoi du Wake-on-LAN…"
        defer { isBusy = false }

        do {
            try await WakeOnLAN.send(mac: mac, broadcast: broadcast)
            statusMessage = "Signal d’allumage envoyé. Démarrage en cours…"

            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                do {
                    try await client.status()
                    isOnline = true
                    statusMessage = "PC démarré."
                    return
                } catch {
                    isOnline = false
                }
            }

            statusMessage = "Signal envoyé, mais le PC n’a pas encore répondu."

        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
