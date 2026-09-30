import Foundation

struct JSONFile<Value: Codable & Sendable>: Sendable {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    /// An unreadable file is moved aside before throwing so the next save can't overwrite the user's only copy.
    func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
            let preserved = url.deletingPathExtension().appendingPathExtension("damaged-\(stamp).json")
            try FileManager.default.moveItem(at: url, to: preserved)
            throw JSONFileError.unreadable(preservedAs: preserved.lastPathComponent)
        }
    }

    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum JSONFileError: Error, LocalizedError, Equatable {
    case unreadable(preservedAs: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "The file was damaged, so a copy was kept as “\(name)” and this list starts empty."
        }
    }
}
