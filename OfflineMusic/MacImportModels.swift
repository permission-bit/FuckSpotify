import Foundation
import SwiftData

enum MacImportTarget: Codable, Hashable {
    case automatic, library, playlist(UUID)
}

@Model final class MacImportBatch {
    @Attribute(.unique) var key: String
    var scope: String
    var jobID: UUID
    var title: String
    var targetData: Data
    var automaticPlaylistID: UUID = UUID()
    var playlistWasCreated: Bool = false
    var jobData: Data
    var updatedAt: Date = Date()
    init(key: String, scope: String, job: MacJobInfo, title: String, target: MacImportTarget) throws {
        self.key = key; self.scope = scope; jobID = job.id; self.title = title
        targetData = try JSONEncoder().encode(target); jobData = try JSONEncoder().encode(job)
    }
    var target: MacImportTarget { (try? JSONDecoder().decode(MacImportTarget.self, from: targetData)) ?? .library }
    var job: MacJobInfo? { try? JSONDecoder().decode(MacJobInfo.self, from: jobData) }
}

@Model final class MacImportedFile {
    @Attribute(.unique) var key: String
    var batchKey: String
    var itemID: UUID
    var position: Int
    var checksum: String
    var itemData: Data
    var songID: UUID?
    var state: String = "pending"
    var message: String?
    var stagingName: String = UUID().uuidString + ".mp3"
    init(key: String, batchKey: String, item: MacReadyItem, checksum: String) throws {
        self.key = key; self.batchKey = batchKey; itemID = item.id; position = item.position
        self.checksum = checksum; itemData = try JSONEncoder().encode(item)
    }
    var item: MacReadyItem? { try? JSONDecoder().decode(MacReadyItem.self, from: itemData) }
    var finished: Bool { state == "imported" || state == "reused" }
}

struct MacImportSettings: Codable {
    var version = 1
    var automatic = true
    var target: MacImportTarget = .automatic
    var cursors: [String: Int64] = [:]
    var requestedTargets: [String: MacImportTarget]?
}

struct MacImportJournal {
    let directory: URL
    var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func load() throws -> MacImportSettings {
        try prepare()
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return MacImportSettings() }
        guard let data = try? Data(contentsOf: settingsURL), let settings = try? JSONDecoder().decode(MacImportSettings.self, from: data), settings.version == 1 else { throw MacImportError.stateUnavailable }
        return settings
    }
    func save(_ settings: MacImportSettings) throws {
        try prepare()
        try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
    }
    func stagingURL(_ name: String) throws -> URL {
        guard name == URL(fileURLWithPath: name).lastPathComponent, UUID(uuidString: String(name.dropLast(4))) != nil,
              name.hasSuffix(".mp3") else { throw MacImportError.stateUnavailable }
        return directory.appendingPathComponent(name)
    }
}

enum MacPlaylistOrder {
    // Insert only new memberships; never reorder or restore manually removed ones.
    static func inserting(_ newIDs: Set<UUID>, desired: [UUID], into current: [UUID]) -> [UUID] {
        var result = current
        var seen = Set(result)
        for (index, id) in desired.enumerated() where newIDs.contains(id) && !seen.contains(id) {
            if let previous = desired[..<index].reversed().first(where: { seen.contains($0) }), let position = result.firstIndex(of: previous) {
                result.insert(id, at: position + 1)
            } else if let next = desired.dropFirst(index + 1).first(where: { seen.contains($0) }), let position = result.firstIndex(of: next) {
                result.insert(id, at: position)
            } else { result.append(id) }
            seen.insert(id)
        }
        return result
    }
}
