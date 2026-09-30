import SwiftUI

struct ConnectionFailureView: View {
    @Environment(AppModel.self) private var app
    let session: ServerSession
    let failure: ConnectionFailure

    @State private var reviewing: ReviewRequest?
    @State private var editing = false
    @State private var trustError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: failure.error.reviewableCertificate == nil ? "wifi.exclamationmark" : "lock.trianglebadge.exclamationmark")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(Color.enveAccent)
                        .padding(.top, 40)
                        .accessibilityHidden(true)
                    Text("Couldn't connect to \(session.displayName)")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)

                    EnveCard {
                        ConnectionFailureSummary(failure: failure) { certificate, endpointID, pinned in
                            reviewing = ReviewRequest(certificate: certificate, endpointID: endpointID, pinnedFingerprint: pinned)
                        }
                    }

                    if let trustError {
                        Text(trustError).font(.footnote).foregroundStyle(.red)
                    }

                    VStack(spacing: 10) {
                        Button {
                            Task { await session.connect(using: app.store) }
                        } label: {
                            Text("Try Again").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            editing = true
                        } label: {
                            Text("Edit Server").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        if let endpoint = failure.endpoint {
                            let apiKey = session.profile.flatMap { try? app.store.apiKey(for: $0) }
                            NavigationLink {
                                DiagnosticsView(title: session.displayName, url: endpoint.url, pinnedFingerprint: endpoint.pinnedCertificateSHA256,
                                                authenticate: apiKey.map { key in
                                                    { @Sendable in let identity = try await UnraidClient(endpoint: endpoint, apiKey: key).identity(); return "Unraid \(identity.unraidVersion ?? "") · \(identity.name)" }
                                                })
                            } label: {
                                Text("Diagnose Connection").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.large)
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ServerSwitcherButton() }
            }
            .enveScreen()
        }
        .sheet(item: $reviewing) { request in
            CertificateReviewView(certificate: request.certificate, pinnedFingerprint: request.pinnedFingerprint) {
                Task {
                    do {
                        try await session.trust(request.certificate, endpointID: request.endpointID, store: app.store)
                    } catch {
                        trustError = error.localizedDescription
                    }
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let profile = session.profile {
                ServerEditorView(profile: profile, hasSavedKey: (try? app.store.apiKey(for: profile)) != nil) { _ in
                    Task { await session.reload(from: app.store) }
                }
            }
        }
    }
}
