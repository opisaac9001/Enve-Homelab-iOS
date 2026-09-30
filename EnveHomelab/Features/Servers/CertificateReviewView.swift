import SwiftUI

struct CertificateReviewView: View {
    let certificate: CertificateSummary
    let pinnedFingerprint: String?
    let onTrust: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var verified = false

    private var isChange: Bool { pinnedFingerprint != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(isChange
                             ? "This server presented a different certificate from the one you trusted. This happens after you regenerate the server's certificate — or when someone is intercepting the connection."
                             : "This certificate isn't signed by an authority this device trusts. Self-hosted servers, including Unraid, often use self-signed certificates.")
                    } icon: {
                        Image(systemName: isChange ? "exclamationmark.shield.fill" : "lock.shield")
                            .foregroundStyle(isChange ? .red : .orange)
                    }
                    .font(.subheadline)
                }

                Section("Certificate") {
                    LabeledValue(label: "Host", value: certificate.host)
                    LabeledValue(label: "Subject", value: certificate.subject)
                    if let notBefore = certificate.notValidBefore {
                        LabeledValue(label: "Valid from", value: notBefore.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let notAfter = certificate.notValidAfter {
                        LabeledValue(label: "Expires", value: notAfter.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let failure = certificate.evaluationFailure {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("System check").foregroundStyle(.secondary)
                            Text(failure).font(.footnote)
                        }
                    }
                }

                Section {
                    FingerprintText(fingerprint: certificate.sha256Fingerprint)
                } header: {
                    Text("SHA-256 fingerprint")
                } footer: {
                    Text("Compare this with the certificate the server actually uses, for example from a trusted machine:\nopenssl s_client -connect \(certificate.host):PORT </dev/null | openssl x509 -noout -fingerprint -sha256")
                        .textSelection(.enabled)
                }

                if let pinnedFingerprint {
                    Section("Previously trusted fingerprint") {
                        FingerprintText(fingerprint: pinnedFingerprint)
                    }
                }

                Section {
                    Toggle("I've confirmed this fingerprint matches my server", isOn: $verified)
                    Button(isChange ? "Trust New Certificate" : "Trust This Certificate") {
                        onTrust()
                        dismiss()
                    }
                    .disabled(!verified)
                } footer: {
                    Text("Only this exact certificate is trusted, and only for this server address. If it changes you'll be asked again.")
                }
            }
            .navigationTitle(isChange ? "Certificate Changed" : "Review Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Don't Trust") { dismiss() }
                }
            }
        }
    }
}

private struct FingerprintText: View {
    let fingerprint: String

    var body: some View {
        let pairs = fingerprint.split(separator: ":")
        let rows = stride(from: 0, to: pairs.count, by: 8).map { pairs[$0..<min($0 + 8, pairs.count)].joined(separator: " ") }
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.self) { Text($0) }
        }
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .accessibilityLabel("Fingerprint")
        .accessibilityValue(fingerprint.replacingOccurrences(of: ":", with: " "))
    }
}
