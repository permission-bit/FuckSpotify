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
    DuplicateSongInput(id: possibleB, title: "MÁYBE", artist: "ARTIST", album: "ALBUM", duration: 201, fileName: "four.m4a", path: write("four.m4a", "version b")),
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

func input(_ name: String, artist: String = "Artist", album: String = "Album", duration: Double = 100, path: String? = nil) -> DuplicateSongInput {
    DuplicateSongInput(id: UUID(), title: "Same Title", artist: artist, album: album, duration: duration, fileName: name, path: path ?? write(name, name))
}
let unknowns = [input("unknown-one.mp3", artist: "Unknown Artist", album: "Unknown Album"), input("unknown-two.mp3", artist: "Unbekannter Künstler", album: "Unbekanntes Album")]
let unknownGroups = await DuplicateScanner.scan(unknowns)
precondition(unknownGroups.isEmpty, "Unknown metadata is not evidence")
let noDuration = [input("no-duration-one.mp3", duration: 0), input("no-duration-two.mp3", duration: 0)]
let noDurationGroups = await DuplicateScanner.scan(noDuration)
precondition(noDurationGroups.isEmpty, "Missing duration must not create possible matches")
let chain = [input("chain-one.mp3", duration: 100), input("chain-two.mp3", duration: 102), input("chain-three.mp3", duration: 104)]
let chainGroups = await DuplicateScanner.scan(chain)
precondition(chainGroups.allSatisfy { ($0.records.map(\.duration).max()! - $0.records.map(\.duration).min()!) <= 2 })
let sharedPath = write("shared.mp3", "only physical copy")
let shared = await DuplicateScanner.scan([input("sharedA.mp3", path: sharedPath), input("sharedB.mp3", path: sharedPath)])
precondition(DuplicateScanner.safeDeletionIDs(groups: shared, removalIDs: [shared[0].records[0].id]).ids.isEmpty, "Two records referencing one file are not two accessible copies")
let thirdShared = input("third-shared.mp3", path: write("third-shared.mp3", "only physical copy"))
let sharedThree = await DuplicateScanner.scan([input("sharedA.mp3", path: sharedPath), input("sharedB.mp3", path: sharedPath), thirdShared])
let sharedID = sharedThree[0].records.first { $0.path == sharedPath }!.id
precondition(DuplicateScanner.safeDeletionIDs(groups: sharedThree, removalIDs: [sharedID]).ids.isEmpty, "Deleting a shared file must not break an unselected record")

// Exact copies must still be comparable with a separately encoded version.
let third = input("alternative.mp3", duration: 180)
let alternative = DuplicateSongInput(id: third.id, title: "Same", artist: "Artist", album: "Album", duration: 180, fileName: third.fileName, path: third.path)
let mixed = await DuplicateScanner.scan([inputs[0], inputs[1], alternative])
precondition(mixed.contains { $0.kind == .exact } && mixed.contains { $0.kind == .possible && $0.records.contains(where: { $0.id == alternative.id }) })

// Differences after the first megabyte must affect the hash.
func largeFile(_ name: String, lastByte: UInt8) throws -> String {
    let url = folder.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    for _ in 0..<6 { try handle.write(contentsOf: Data(repeating: 42, count: 524_288)) }
    try handle.write(contentsOf: Data([lastByte]))
    return url.path
}
let largeA = input("largeA.mp3", path: try largeFile("largeA.mp3", lastByte: 1))
let largeB = input("largeB.mp3", path: try largeFile("largeB.mp3", lastByte: 1))
let largeC = input("largeC.mp3", path: try largeFile("largeC.mp3", lastByte: 2))
let largeGroups = await DuplicateScanner.scan([largeA, largeB, largeC])
precondition(largeGroups.first { $0.kind == .exact }!.records.count == 2)

try Data("changed content and size".utf8).write(to: URL(fileURLWithPath: inputs[1].path))
precondition(DuplicateScanner.safeDeletionIDs(groups: [exact], removalIDs: [exactA]).ids.isEmpty, "A changed keeper invalidates the review")
try FileManager.default.removeItem(atPath: inputs[1].path)
precondition(DuplicateScanner.safeDeletionIDs(groups: [exact], removalIDs: [exactA]).ids.isEmpty, "An unavailable keeper must block deletion")
print("PASS: multi-chunk hashing, normalized metadata, unknown metadata, duration boundaries, mixed versions, shared paths, changed/missing keeper and deletion safety")
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
