import SwiftUI
import UIKit

/// The optional Docker-host import: the script runs on the user's own host, and its file comes back through the Files picker.
struct CompanionImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var includeChecks = true
    @State private var importing = false
    @State private var reviewing: PendingImport?
    @State private var failure: String?
    @State private var copied = false

    private static let scriptURL = Bundle.main.url(forResource: "enve-companion-export", withExtension: "py")

    private var command: String {
        let address = host.trimmingCharacters(in: .whitespaces).isEmpty ? "<this host's address>" : host.trimmingCharacters(in: .whitespaces)
        return "python3 enve-companion-export.py --host \(address) -o enve-homelab.json" + (includeChecks ? " --include-checks" : "")
    }

    var body: some View {
        Form {
            Section {
                Text("A small Python script lists the containers running on your Docker host — names, images and published ports only — and writes a file you import here. It never reads environment variables, volumes or secrets and never connects to the network.")
                    .font(.subheadline)
            }

            Section {
                if let scriptURL = Self.scriptURL {
                    ShareLink(item: scriptURL) {
                        Label("Save the Script…", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("1. Copy the script to the host")
            } footer: {
                Text("AirDrop it to a Mac, save it to Files or a shared folder, or copy it from Scripts/ in the Enve Homelab source. It needs Python 3.8 or later and access to `docker ps`.")
            }

            Section {
                TextField("Address your phone uses, e.g. 192.168.1.20", text: $host)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Also add health checks for other web containers", isOn: $includeChecks)
                Text(command)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy Command") {
                    UIPasteboard.general.string = command
                    copied = true
                }
            } header: {
                Text("2. Run it on the host")
            }

            Section {
                Button {
                    importing = true
                } label: {
                    Label("Choose enve-homelab.json…", systemImage: "doc.badge.plus")
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            } header: {
                Text("3. Import the file")
            } footer: {
                Text("You'll see every service it found and choose which to add, then enter each API key. Nothing already set up is changed.")
            }
        }
        .navigationTitle("Import from Docker Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        }
        .onChange(of: command) { copied = false }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                reviewing = PendingImport(backup: try ConfigurationFile.read(result))
                failure = nil
            } catch {
                failure = "That file isn't a readable Enve Homelab file. \(error.localizedDescription)"
            }
        }
        .sheet(item: $reviewing, onDismiss: { dismiss() }) { ImportReviewView(backup: $0.backup) }
        .enveScreen()
    }
}
