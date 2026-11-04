// Runs production playback control logic against a deterministic audio-device clock.
// This validates scheduling/state, not hardware output or codec gaplessness.
// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift Tests/check_audio_playback.swift
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let app = try String(contentsOf: root.appendingPathComponent("OfflineMusic/OfflineMusicApp.swift"), encoding: .utf8)
let options = try String(contentsOf: root.appendingPathComponent("OfflineMusic/PlaybackOptions.swift"), encoding: .utf8)
let models = String(app[app.range(of: "@Model final class Song")!.lowerBound..<app.range(of: "enum LibraryStore")!.lowerBound])
let timing = String(options[options.range(of: "enum PlaybackTiming")!.lowerBound..<options.range(of: "struct PlaybackSettingsView")!.lowerBound])
var engine = String(app[app.range(of: "struct PlaybackHistoryProgress")!.lowerBound...])
func replace(_ start: String, through end: String, with replacement: String) {
    let range = engine.range(of: start)!.lowerBound..<engine.range(of: end)!.lowerBound
    engine.replaceSubrange(range, with: replacement + "\n")
}
// Replace only platform integration boundaries; all queue, transition, sleep,
// interruption and persistence control code below runs unchanged.
replace("    private func configureSession()", through: "    @discardableResult\n    private func prepare", with: "    private func configureSession() {}")
replace("    private func updateNowPlaying()", through: "    private func restoreSessionIfPossible()", with: "    private func updateNowPlaying() {}")
replace("    private func configureRemoteCommands()", through: "    private func resumeFromRemote()", with: "    private func configureRemoteCommands() {}")
let doubles = #"""
enum LibraryStore {
    static let musicURL: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playback-test-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
enum UIApplication {
    static let willResignActiveNotification = Notification.Name("test.resign")
    static let didEnterBackgroundNotification = Notification.Name("test.background")
    static let didBecomeActiveNotification = Notification.Name("test.active")
}
let AVAudioSessionInterruptionTypeKey = "type"
let AVAudioSessionInterruptionOptionKey = "options"
let AVAudioSessionRouteChangeReasonKey = "reason"
enum AVAudioSession {
    static let routeChangeNotification = Notification.Name("test.route")
    static let interruptionNotification = Notification.Name("test.interruption")
    static let mediaServicesWereResetNotification = Notification.Name("test.reset")
    enum InterruptionType: UInt { case ended = 0, began = 1 }
    struct InterruptionOptions: OptionSet { let rawValue: UInt; static let shouldResume = Self(rawValue: 1) }
    enum RouteChangeReason: UInt { case oldDeviceUnavailable = 2 }
}
@MainActor final class MPNowPlayingInfoCenter {
    static let shared = MPNowPlayingInfoCenter()
    static func `default`() -> MPNowPlayingInfoCenter { shared }
    var nowPlayingInfo: [String: Any]?
}
@MainActor protocol AVAudioPlayerDelegate: AnyObject {}
struct TestFormat { var sampleRate = 44100.0; var channelCount = 2 }
@MainActor final class AVAudioPlayer {
    static var clock = 0.0
    static var durations: [String: Double] = [:]
    static var formats: [String: TestFormat] = [:]
    weak var delegate: AVAudioPlayerDelegate?
    let duration: Double
    let format: TestFormat
    var numberOfLoops = 0
    var volume: Float = 1
    var lastFade: (Float, Double)?
    var active = false
    private var position = 0.0
    private var startedAt = 0.0
    var deviceCurrentTime: Double { Self.clock }
    var currentTime: Double {
        get {
            let value = position + (active ? max(0, Self.clock - startedAt) : 0)
            return numberOfLoops == -1 ? value.truncatingRemainder(dividingBy: duration) : min(duration, value)
        }
        set { position = newValue; startedAt = Self.clock }
    }
    var isPlaying: Bool { active && Self.clock >= startedAt && (numberOfLoops == -1 || currentTime < duration) }
    init(contentsOf url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        duration = Self.durations[url.lastPathComponent] ?? 100
        format = Self.formats[url.lastPathComponent] ?? TestFormat()
    }
    func prepareToPlay() -> Bool { true }
    @discardableResult func play() -> Bool {
        if currentTime >= duration { position = 0 }
        active = true; startedAt = Self.clock; return true
    }
    func play(atTime time: Double) -> Bool { active = true; startedAt = time; return true }
    func pause() { position = currentTime; active = false }
    func stop() { pause() }
    func setVolume(_ volume: Float, fadeDuration duration: Double) {
        lastFade = (volume, duration)
        if duration == 0 { self.volume = volume }
    }
}
"""#
let checks = #"""
extension AudioPlayer {
    static func testPlayer() -> AudioPlayer {
        for key in [PlaybackSession.storageKey, "playback.sleepDeadline", "playback.crossfadeEnabled", "playback.crossfadeDuration", "playback.gaplessEnabled", "playback.sleepFadeEnabled"] { UserDefaults.standard.removeObject(forKey: key) }
        AVAudioPlayer.clock = 0
        return AudioPlayer()
    }
    static func restoredTestPlayer() -> AudioPlayer { AudioPlayer() }
    var plannedID: UUID? { scheduledTransition?.song.id }
    var plannedTime: Double? { scheduledTransition?.startsAt }
    var plannedOverlap: Double? { scheduledTransition?.overlap }
    var testAudio: AVAudioPlayer? { audio }
    var testTail: AVAudioPlayer? { outgoingAudio }
    func drive(to time: Double) { AVAudioPlayer.clock = time; updateProgress() }
    func finish() { if let audio { audioPlayerDidFinishPlaying(audio, successfully: true) } }
    func deadline(in seconds: Double) { sleepDeadline = Date().addingTimeInterval(seconds); armSleepTimer(); refreshScheduledTransition() }
    func activate() { becameActive() }
    func interrupt(began: Bool, resume: Bool = true) {
        interrupted(Notification(name: AVAudioSession.interruptionNotification, userInfo: [AVAudioSessionInterruptionTypeKey: UInt(began ? 1 : 0), AVAudioSessionInterruptionOptionKey: UInt(resume ? 1 : 0)]))
    }
    func unplug() { routeChanged(Notification(name: AVAudioSession.routeChangeNotification, userInfo: [AVAudioSessionRouteChangeReasonKey: UInt(2)])) }
    func dispose() {
        stop(); cancelSleepTimer(); timer?.invalidate(); sessionSaveWorkItem?.cancel()
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        NotificationCenter.default.removeObserver(self)
    }
}
MainActor.assumeIsolated {
    defer { try? FileManager.default.removeItem(at: LibraryStore.musicURL) }
    let songs = ["a", "b", "c"].map { name -> Song in
        let file = name + ".wav"
        try! Data([1]).write(to: LibraryStore.musicURL.appendingPathComponent(file))
        return Song(title: name, duration: 100, fileName: file)
    }
    do {
        let p = AudioPlayer.testPlayer(); defer { p.dispose() }
        p.setLibrary(songs); p.play(songs[0])
        precondition(p.plannedID == songs[1].id && p.plannedTime == 100 && p.plannedOverlap == 0)
        let outgoing = p.testAudio!
        p.drive(to: 100)
        precondition(p.current?.id == songs[1].id && !outgoing.active && p.plannedID == songs[2].id)
        p.next(); precondition(p.current?.id == songs[2].id)
        p.previous(); precondition(p.current?.id == songs[1].id)
        p.toggle(); precondition(!p.isPlaying && p.plannedID == nil)
        p.toggle(); precondition(p.isPlaying && p.plannedID == songs[2].id)
    }
    do {
        let p = AudioPlayer.testPlayer(); defer { p.dispose() }
        p.setLibrary(songs); p.play(songs[0]); p.addToQueue([songs[2], songs[1]])
        precondition(p.plannedID == songs[2].id && p.queue.count == 2)
        p.moveQueue(from: IndexSet(integer: 1), to: 0)
        precondition(p.plannedID == songs[1].id)
        p.removeQueue(ids: [songs[1].id]); precondition(p.plannedID == songs[2].id)
        p.drive(to: 100); precondition(p.current?.id == songs[2].id && p.queue.isEmpty)
        p.play(songs[0]); p.toggleShuffle()
        precondition(p.plannedID != nil && p.plannedID != songs[0].id)
        p.cycleRepeatMode(); precondition(p.testAudio?.numberOfLoops == -1 && p.plannedID == nil)
        p.sleepAtEndOfCurrentSong(); precondition(p.testAudio?.numberOfLoops == 0 && p.plannedID == nil)
        p.finish(); precondition(!p.isPlaying && p.current?.id == songs[0].id && !p.sleepAfterCurrentSong)
    }
    do {
        let p = AudioPlayer.testPlayer(); defer { p.dispose() }
        p.setLibrary(songs); p.setCrossfadeEnabled(true); p.setCrossfadeDuration(12); p.play(songs[0])
        precondition(p.plannedTime == 88 && p.plannedOverlap == 12)
        let outgoing = p.testAudio!
        p.drive(to: 88)
        precondition(p.current?.id == songs[1].id && p.testTail === outgoing)
        precondition(outgoing.lastFade?.0 == 0 && outgoing.lastFade?.1 == 12)
        precondition(p.testAudio?.lastFade?.0 == 1 && p.testAudio?.lastFade?.1 == 12)
        p.next(); precondition(p.current?.id == songs[2].id && p.testTail == nil && !outgoing.active)
        AVAudioPlayer.durations["b.wav"] = 4
        p.play(songs[0]); precondition(p.plannedOverlap == 2)
        AVAudioPlayer.durations.removeValue(forKey: "b.wav")
        p.setCrossfadeEnabled(false); precondition(p.plannedOverlap == 0)
        p.setGaplessEnabled(false); precondition(p.plannedID == nil)
        p.finish(); precondition(p.current?.id == songs[1].id)
    }
    do {
        let p = AudioPlayer.testPlayer(); defer { p.dispose() }
        p.setLibrary(songs); p.play(songs[0]); p.startSleepTimer(minutes: 5)
        precondition(p.sleepDeadline != nil)
        p.cancelSleepTimer(); precondition(p.sleepDeadline == nil && p.isPlaying)
        p.setSleepFadeEnabled(true); p.sleepAtEndOfCurrentSong(); p.seek(0.98)
        precondition(p.testAudio?.lastFade?.0 == 0)
        p.seek(0.2)
        precondition(p.testAudio?.lastFade?.0 == 1 && p.testAudio?.lastFade?.1 == 0, "Seeking back must cancel an end-of-track fade")
        p.cancelSleepTimer(); p.deadline(in: 3)
        precondition(p.testAudio?.lastFade?.0 == 0 && (p.testAudio?.lastFade?.1 ?? 99) <= 3)
        p.cancelSleepTimer(); precondition(p.testAudio?.volume == 1)
        p.toggle(); p.deadline(in: -1); p.activate()
        precondition(!p.isPlaying && p.sleepDeadline == nil)
        p.toggle(); p.interrupt(began: true)
        precondition(!p.isPlaying && p.plannedID == nil)
        p.interrupt(began: false, resume: false); precondition(!p.isPlaying)
        p.toggle(); p.interrupt(began: true); p.interrupt(began: false)
        precondition(p.isPlaying && p.plannedID != nil)
        p.interrupt(began: true); p.deadline(in: -1); p.interrupt(began: false)
        precondition(!p.isPlaying, "An expired timer must block interruption auto-resume")
        p.toggle(); p.unplug(); precondition(!p.isPlaying && p.plannedID == nil)
    }
    do {
        let p = AudioPlayer.testPlayer(); defer { p.dispose() }
        AVAudioPlayer.formats["b.wav"] = TestFormat(sampleRate: 48000, channelCount: 2)
        p.setLibrary(songs); p.play(songs[0])
        precondition(p.plannedID == nil, "Incompatible formats use the normal decoder transition")
        p.finish(); precondition(p.current?.id == songs[1].id)
        AVAudioPlayer.formats.removeValue(forKey: "b.wav")
    }
    do {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Song.self, Playlist.self, MusicGenre.self, ArtistProfile.self, configurations: config)
        defer { withExtendedLifetime(container) {} }
        let p = AudioPlayer.testPlayer(); defer { p.dispose() }
        songs.forEach { $0.playCount = 0; $0.lastPlayedAt = nil }
        songs.forEach { container.mainContext.insert($0) }
        p.attachHistoryContext(container.mainContext)
        p.setLibrary([]); p.next(); p.previous(); precondition(p.current == nil)
        p.setLibrary(songs); p.play(songs[0]); p.drive(to: 5)
        p.seek(0.9); precondition(songs[0].playCount == 0, "Seeking forward is not listening")
        p.drive(to: 6); p.seek(0.1); p.drive(to: 30)
        precondition(songs[0].playCount == 1 && songs[0].lastPlayedAt != nil)
        let verificationContext = ModelContext(container)
        defer { withExtendedLifetime(verificationContext) {} }
        let savedHistory = try! verificationContext.fetch(FetchDescriptor<Song>()).first { $0.id == songs[0].id }!
        precondition(savedHistory.playCount == 1, "Playback must persist history at the threshold")
        p.drive(to: 31); p.toggle(); p.drive(to: 200)
        precondition(songs[0].playCount == 1, "Paused time must not count")
        p.toggle(); p.seek(0); p.drive(to: 231)
        precondition(songs[0].playCount == 1, "Seeking backward must not count a second play")
        p.play(songs[0], in: [songs[0], songs[2], songs[1]])
        p.drive(to: 261); precondition(songs[0].playCount == 2)
        p.toggle()
        let restored = AudioPlayer.restoredTestPlayer(); defer { restored.dispose() }
        restored.setLibrary(songs)
        restored.attachHistoryContext(container.mainContext)
        precondition(!restored.isPlaying && restored.current?.id == songs[0].id)
        restored.toggle(); restored.drive(to: 292)
        precondition(songs[0].playCount == 2, "Session restoration must retain the already-counted marker")
        precondition(restored.plannedID == songs[2].id, "The saved playlist order must survive restoration")
        restored.addToQueue([songs[1], songs[1], songs[2]])
        precondition(restored.queue.map(\.id) == [songs[1].id, songs[2].id])
        let missing = Song(title: "Missing", fileName: "missing.wav")
        restored.playNext(missing); restored.next()
        precondition(restored.current?.id == songs[1].id, "An inaccessible queue item must not block valid tracks")
    }
    do {
        let p = AudioPlayer.testPlayer(); defer { p.dispose() }
        let loop = Song(title: "Loop", duration: 100, fileName: "a.wav")
        p.setLibrary([loop]); p.play(loop); p.cycleRepeatMode(); p.drive(to: 241)
        precondition(loop.playCount == 3, "Each meaningful native repeat cycle must count, including delayed progress events")
        p.drive(to: 250); precondition(loop.playCount == 3)
        p.cycleRepeatMode(); p.play(loop); p.drive(to: 270); p.toggle()
        let restored = AudioPlayer.restoredTestPlayer(); defer { restored.dispose() }
        restored.setLibrary([loop]); restored.toggle(); restored.drive(to: 280)
        precondition(loop.playCount == 4, "Partial listening time must survive a paused-session restart")
        restored.prepareForLibraryMutation()
        let kept = Song(title: "Kept", duration: 100, fileName: "b.wav")
        kept.mergeHistory(from: loop)
        restored.reconcileDuplicates(songs: [kept], replacements: [loop.id: kept.id], previousCurrentID: loop.id, previousQueueIDs: [])
        restored.finishLibraryMutation(); restored.drive(to: 311)
        precondition(kept.playCount == 4, "Replacing a duplicate must not count the same session twice")
    }
    precondition(PlaybackTiming.overlap(requested: 12, outgoing: 1, incoming: 100, remaining: 1) == 0.5)
    precondition(PlaybackTiming.overlap(requested: .nan, outgoing: 100, incoming: 100, remaining: 100) == 0)
    print("PASS: production transition scheduling, gapless/crossfade modes, short tracks, skips, queue edits, shuffle/repeat, sleep cancellation/expiry/fade, interruption resume and unplug pause")
}
"""#
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", "-"]
let pipe = Pipe()
process.standardInput = pipe
try process.run()
let code = "import Foundation\nimport Combine\nimport SwiftUI\nimport SwiftData\n" + [models, doubles, timing, engine, checks].joined(separator: "\n")
try pipe.fileHandleForWriting.write(contentsOf: Data(code.utf8))
try pipe.fileHandleForWriting.close()
process.waitUntilExit()
exit(process.terminationStatus)
