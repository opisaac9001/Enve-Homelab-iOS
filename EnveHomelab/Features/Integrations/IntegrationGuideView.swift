import SwiftUI

struct IntegrationGuideView: View {
    let kind: IntegrationKind

    var body: some View {
        let guide = kind.guide
        List {
            Section("Create credentials") {
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                    Label {
                        Text(step)
                    } icon: {
                        Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(Color.enveAccent)
                    }
                }
            }
            Section("Permissions") { Text(guide.permissions) }
            Section("Address") { Text(guide.address) }
            Section("What Enve Homelab reads") { Text(guide.reads) }
            Section {
                if guide.actions.isEmpty {
                    Text("Nothing — this integration is read-only.")
                } else {
                    ForEach(guide.actions, id: \.self) { Label($0, systemImage: "hand.tap") }
                }
            } header: {
                Text("What it can change")
            } footer: {
                Text("Consequential actions always show their target and consequence first. View-only profiles can't run any of them.")
            }
            Section {
                NavigationLink("About trust and credentials") { TrustHelpView() }
            }
        }
        .navigationTitle("Connect \(kind.displayName)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TrustHelpView: View {
    var body: some View {
        List {
            Section("Credentials") {
                Text("API keys, tokens, passwords and SSH private keys are stored only in this device's Keychain, never in backups, and they're deleted when you remove the connection. They're sent only to the server they belong to.")
            }
            Section("HTTPS and self-signed certificates") {
                Text("The system checks every certificate first. Home servers often use self-signed certificates, which the system can't verify; you'll see the certificate's SHA-256 fingerprint and trust it only after comparing it with the server. If that certificate later changes, the connection is refused until you review the new one — a change can mean someone is intercepting the connection.")
                Text("Compare fingerprints from a trusted machine, for example:\nopenssl s_client -connect HOST:PORT </dev/null | openssl x509 -noout -fingerprint -sha256")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            Section("Plain HTTP") {
                Text("HTTP sends credentials unencrypted. Use it only on networks you fully trust, or put a reverse proxy with HTTPS in front of the service. TrueNAS refuses API keys over HTTP.")
            }
            Section("SSH host keys") {
                Text("The first connection shows the host key fingerprint for you to confirm (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on the server). A changed key is refused.")
            }
            Section("Profiles") {
                Text("View-only profiles can look but not change anything, open terminals or see editors. Switching back to an Owner profile can require Face ID, Touch ID or the passcode.")
            }
            Section("What leaves this device") {
                Text("Only requests to the servers you add, the Tailscale and Cloudflare APIs if you add them, and your own ntfy server if you set one up. No analytics, accounts or relays.")
            }
        }
        .navigationTitle("Trust & Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}
