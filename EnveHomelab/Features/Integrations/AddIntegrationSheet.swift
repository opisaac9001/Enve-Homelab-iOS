import SwiftUI

struct AddIntegrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: IntegrationKind?
    var serverID: UUID?

    var body: some View {
        NavigationStack {
            List {
                ForEach(IntegrationCategory.allCases) { category in
                    Section(category.title) {
                        ForEach(IntegrationKind.allCases.filter { $0.category == category }) { kind in
                            Button {
                                chosen = kind
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: kind.systemImage)
                                        .foregroundStyle(Color.enveAccent)
                                        .frame(width: 28)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(kind.displayName).font(.body.weight(.semibold))
                                        Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Add Integration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(item: $chosen) { kind in
                IntegrationEditorForm(original: nil, kind: kind, serverID: serverID) { dismiss() }
            }
        }
    }
}
