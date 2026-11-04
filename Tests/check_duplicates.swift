// Run with: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift Tests/check_duplicates.swift
// Exercises exact hashing, metadata matching and last-accessible-copy protection.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = try String(contentsOf: root.appendingPathComponent("OfflineMusic/LibraryManagement.swift"), encoding: .utf8)
let start = source.range(of: "enum DuplicateKind")!.lowerBound
let end = source.range(of: "struct DuplicateManagerView")!.lowerBound
let logic = String(source[start..<end])
let checks = #"""
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }

func write(_ name: String, _ bytes: String) -> String {
    let url = folder.appendingPathComponent(name)
    try! Data(bytes.utf8).write(to: url)
    return url.path
}

let exactA = UUID(), exactB = UUID(), possibleA = UUID(), possibleB = UUID(), titleOnlyA = UUID(), titleOnlyB = UUID()
let inputs = [
    DuplicateSongInput(id: exactA, title: "Same", artist: "Artist", album: "Album", duration: 180, fileName: "one.mp3", path: write("one.mp3", "identical audio")),
    DuplicateSongInput(id: exactB, title: "Same", artist: "Artist", album: "Album", duration: 180, fileName: "two.mp3", path: write("two.mp3", "identical audio")),
    DuplicateSongInput(id: possibleA, title: "Maybe", artist: "Artist", album: "Album", duration: 200, fileName: "three.m4a", path: write("three.m4a", "version a")),
    DuplicateSongInput(id: possibleB, title: "Maybe", artist: "Artist", album: "Album", duration: 201, fileName: "four.m4a", path: write("four.m4a", "version b")),
    DuplicateSongInput(id: titleOnlyA, title: "Shared title", artist: "Artist A", album: "", duration: 100, fileName: "five.mp3", path: write("five.mp3", "five")),
    DuplicateSongInput(id: titleOnlyB, title: "Shared title", artist: "Artist B", album: "", duration: 100, fileName: "six.mp3", path: write("six.mp3", "six"))
]
let groups = await DuplicateScanner.scan(inputs)
let exact = groups.first { $0.kind == .exact }!
precondition(Set(exact.records.map(\.id)) == [exactA, exactB])
precondition(groups.contains { $0.kind == .possible && Set($0.records.map(\.id)) == [possibleA, possibleB] })
precondition(!groups.contains { $0.records.contains(where: { $0.id == titleOnlyA || $0.id == titleOnlyB }) })
let oneDelete = DuplicateScanner.safeDeletionIDs(groups: [exact], removalIDs: [exactA])
precondition(oneDelete.ids == [exactA] && oneDelete.blockedGroupCount == 0)
let allDelete = DuplicateScanner.safeDeletionIDs(groups: [exact], removalIDs: [exactA, exactB])
precondition(allDelete.ids.isEmpty && allDelete.blockedGroupCount == 1)
print("PASS: streaming exact hashes, metadata matching and deletion safety")
"""#

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", "-"]
let pipe = Pipe()
process.standardInput = pipe
try process.run()
let combined = "import Foundation\nimport CryptoKit\n" + logic + checks
try pipe.fileHandleForWriting.write(contentsOf: Data(combined.utf8))
try pipe.fileHandleForWriting.close()
process.waitUntilExit()
exit(process.terminationStatus)
