// Run with: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift Tests/check_playback_session.swift
// Extracts the production PlaybackSession declaration and tests its persistence format.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appSource = try String(contentsOf: root.appendingPathComponent("OfflineMusic/OfflineMusicApp.swift"), encoding: .utf8)
let start = appSource.range(of: "struct PlaybackHistoryProgress")!.lowerBound
let end = appSource.range(of: "@MainActor final class AudioPlayer")!.lowerBound
let declaration = String(appSource[start..<end])

let checks = #"""
let currentID = UUID()
let queueIDs = [UUID(), UUID(), UUID()]
let original = PlaybackSession(currentSongID: currentID, position: 137.25, queueSongIDs: queueIDs, shuffle: true, repeatMode: 1)
let data = try JSONEncoder().encode(original)
let restored = try JSONDecoder().decode(PlaybackSession.self, from: data)
precondition(restored == original)
precondition(restored.queueSongIDs == queueIDs, "Queue order must survive a restart")
precondition(restored.currentSongID == currentID)
precondition(restored.position == 137.25)
var withHistory = original
withHistory.history = PlaybackHistoryProgress(songID: currentID, listened: 20, counted: false)
withHistory.contextSongIDs = queueIDs
let restoredHistory = try JSONDecoder().decode(PlaybackSession.self, from: JSONEncoder().encode(withHistory))
precondition(restoredHistory == withHistory)
let legacy = try JSONSerialization.data(withJSONObject: ["currentSongID": currentID.uuidString, "position": 3.0, "queueSongIDs": queueIDs.map(\.uuidString), "shuffle": false, "repeatMode": 0])
let restoredLegacy = try JSONDecoder().decode(PlaybackSession.self, from: legacy)
precondition(restoredLegacy.history == nil && restoredLegacy.contextSongIDs == nil)
print("PASS: playback session retains stable IDs, position, queue order, shuffle and repeat state")
"""#

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", "-"]
let pipe = Pipe()
process.standardInput = pipe
try process.run()
try pipe.fileHandleForWriting.write(contentsOf: Data(("import Foundation\n" + declaration + checks).utf8))
try pipe.fileHandleForWriting.close()
process.waitUntilExit()
exit(process.terminationStatus)
