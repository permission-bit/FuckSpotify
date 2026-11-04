import SwiftUI
import SwiftData
import AVFoundation
import MediaPlayer
import UIKit

@main
struct OfflineMusicApp: App {
    @StateObject private var player = AudioPlayer.shared
    var body: some Scene {
        WindowGroup { RootView().environmentObject(player) }
            .modelContainer(for: [Song.self, Playlist.self, MusicGenre.self, ArtistProfile.self])
    }
}

@Model final class Song: Identifiable {
    var id: UUID = UUID()
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var fileName: String
    var artworkData: Data?
    var addedAt: Date = Date()
    var isFavorite: Bool = false
    var playCount: Int = 0
    var lastPlayedAt: Date?
    var artistIDs: [UUID] = []
    var genreIDs: [UUID] = []
    var importedGenre: String = ""
    var genreMetadataLoaded: Bool = false
    var originalGenreIDs: [UUID] = []
    var inferredGenreIDs: [UUID] = []
    var genreOverrideID: UUID?
    init(title: String, artist: String = "Unknown Artist", album: String = "Unknown Album", duration: Double = 0, fileName: String, artworkData: Data? = nil, importedGenre: String = "") {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration; self.fileName = fileName; self.artworkData = artworkData; self.importedGenre = importedGenre
    }

    func registerPlayback(count: Int = 1, at date: Date = Date()) {
        guard count > 0 else { return }
        let sum = max(0, playCount).addingReportingOverflow(count)
        playCount = sum.overflow ? Int.max : sum.partialValue
        lastPlayedAt = max(lastPlayedAt ?? date, date)
    }

    func mergeHistory(from other: Song) {
        let sum = max(0, playCount).addingReportingOverflow(max(0, other.playCount))
        playCount = sum.overflow ? Int.max : sum.partialValue
        if let date = other.lastPlayedAt { lastPlayedAt = max(lastPlayedAt ?? date, date) }
        addedAt = min(addedAt, other.addedAt)
    }
}

@Model final class Playlist: Identifiable {
    var id: UUID = UUID()
    var name: String
    var songIDs: [UUID] = []
    var artistName: String = ""
    var coverData: Data?
    var createdAt: Date = Date()
    init(name: String, artistName: String = "", coverData: Data? = nil) {
        self.name = name
        self.artistName = artistName
        self.coverData = coverData
    }

    func appendSongs(_ ids: [UUID]) {
        var seen = Set(songIDs)
        songIDs.append(contentsOf: ids.filter { seen.insert($0).inserted })
    }

    func removeSongs(_ ids: Set<UUID>) { songIDs.removeAll { ids.contains($0) } }

    func reorderSongs(_ visibleIDs: [UUID]) {
        var seen = Set<UUID>()
        songIDs = (visibleIDs + songIDs).filter { seen.insert($0).inserted }
    }
}

@Model final class MusicGenre: Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    init(name: String) { self.name = name }
}

@Model final class ArtistProfile: Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var aliases: [String] = []
    var matchFields: [String] = ["artist", "title", "album", "fileName"]
    var genreID: UUID?
    init(name: String, aliases: [String] = [], genreID: UUID? = nil) {
        self.name = name
        self.aliases = aliases
        self.genreID = genreID
    }
}

enum LibraryStore {
    static var musicURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct PlaybackHistoryProgress: Codable, Equatable {
    let songID: UUID
    var listened: TimeInterval = 0
    var counted = false

    static func threshold(duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 30 }
        return min(30, max(0.1, duration / 2))
    }

    mutating func consume(_ seconds: TimeInterval, duration: TimeInterval) -> Bool {
        guard seconds.isFinite, seconds > 0 else { return false }
        listened += seconds
        guard !counted, listened + 0.001 >= Self.threshold(duration: duration) else { return false }
        counted = true
        return true
    }
}

struct PlaybackSession: Codable, Equatable {
    var currentSongID: UUID?
    var position: TimeInterval
    var queueSongIDs: [UUID]
    var shuffle: Bool
    var repeatMode: Int
    var history: PlaybackHistoryProgress? = nil
    var contextSongIDs: [UUID]? = nil

    static let storageKey = "offlineMusic.playbackSession.v1"
}

@MainActor final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()
    @Published private(set) var current: Song?
    @Published private(set) var isPlaying = false
    @Published var progress = 0.0
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode = 0
    @Published private(set) var queue: [Song] = []
    @Published private(set) var crossfadeEnabled = UserDefaults.standard.bool(forKey: "playback.crossfadeEnabled")
    @Published private(set) var crossfadeDuration = min(12, max(0, UserDefaults.standard.object(forKey: "playback.crossfadeDuration") as? Double ?? 4))
    @Published private(set) var gaplessEnabled = UserDefaults.standard.object(forKey: "playback.gaplessEnabled") as? Bool ?? true
    @Published private(set) var sleepFadeEnabled = UserDefaults.standard.bool(forKey: "playback.sleepFadeEnabled")
    @Published private(set) var sleepDeadline: Date? = UserDefaults.standard.object(forKey: "playback.sleepDeadline") as? Date
    @Published private(set) var sleepAfterCurrentSong = false
    private struct ScheduledTransition {
        let song: Song
        let player: AVAudioPlayer
        let startsAt: TimeInterval
        let overlap: TimeInterval
        let fromQueue: Bool
    }
    private var scheduledTransition: ScheduledTransition?
    private var outgoingAudio: AVAudioPlayer?
    private var transitionWork: DispatchWorkItem?
    private var outgoingWork: DispatchWorkItem?
    private var sleepStopWork: DispatchWorkItem?
    private var sleepFadeWork: DispatchWorkItem?
    private var sleepFading = false
    private var resumeAfterInterruption = false
    private var interruptionInProgress = false
    private var notificationObservers: [NSObjectProtocol] = []
    private var library: [Song] = []
    private var currentIndex = 0
    private var audio: AVAudioPlayer?
    private var timer: Timer?
    private var pendingSession: PlaybackSession?
    private var didAttemptSessionRestore = false
    private var sessionSaveWorkItem: DispatchWorkItem?
    private var lastSavedPosition: TimeInterval = 0
    private weak var historyContext: ModelContext?
    private var historyDirty = false
    private var historySuspended = false
    private var listening: PlaybackHistoryProgress?
    private var listeningClock = 0.0
    private var listeningPosition = 0.0
    private var outgoingListening: PlaybackHistoryProgress?
    private var outgoingSong: Song?
    private var outgoingListeningClock = 0.0
    private var outgoingListeningPosition = 0.0
    private var contextSongIDs: [UUID]?

    func attachHistoryContext(_ context: ModelContext) { historyContext = context }

    private var playbackSongs: [Song] {
        guard let contextSongIDs else { return library }
        let lookup = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        return contextSongIDs.compactMap { lookup[$0] }
    }

    private override init() {
        pendingSession = Self.loadSession()
        super.init()
        configureSession()
        configureRemoteCommands()
        observe(AVAudioSession.routeChangeNotification) { $0.routeChanged($1) }
        observe(UIApplication.willResignActiveNotification) { owner, _ in owner.saveForAppTransition() }
        observe(UIApplication.didEnterBackgroundNotification) { owner, _ in owner.saveForAppTransition() }
        observe(UIApplication.didBecomeActiveNotification) { owner, _ in owner.becameActive() }
        observe(AVAudioSession.interruptionNotification) { $0.interrupted($1) }
        observe(AVAudioSession.mediaServicesWereResetNotification) { owner, _ in owner.mediaServicesReset() }
        observe(.NSSystemClockDidChange) { owner, _ in owner.becameActive() }
        armSleepTimer()
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (AudioPlayer, Notification) -> Void) {
        notificationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { if let self { action(self, note) } }
        })
    }

    func setLibrary(_ songs: [Song]) {
        recordListening()
        synchronizeTransition()
        cancelScheduledTransition()
        library = songs
        let availableIDs = Set(songs.map(\.id))
        if !queue.isEmpty { queue.removeAll { !availableIDs.contains($0.id) } }
        if let current, !availableIDs.contains(current.id) {
            stopOutgoingAudio()
            audio?.stop()
            audio = nil
            self.current = nil
            isPlaying = false
            progress = 0
            timer?.invalidate()
            listening = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        } else if let current, let index = songs.firstIndex(where: { $0.id == current.id }) {
            currentIndex = index
        }
        restoreSessionIfPossible()
        refreshScheduledTransition()
    }

    func play(_ song: Song) {
        contextSongIDs = nil
        beginPlayback(song)
    }

    func play(_ song: Song, in collection: [Song]) {
        var seen = Set<UUID>()
        contextSongIDs = collection.map(\.id).filter { seen.insert($0).inserted }
        beginPlayback(song)
    }

    private func beginPlayback(_ song: Song) {
        synchronizeTransition()
        guard !expireSleepTimerIfNeeded() else { return }
        queue.removeAll { $0.id == song.id }
        _ = prepare(song, at: 0, shouldPlay: true)
        saveSessionNow()
    }

    func playNext(_ song: Song) {
        synchronizeTransition()
        guard song.id != current?.id else { return }
        queue.removeAll { $0.id == song.id || $0.id == current?.id }
        queue.insert(song, at: 0)
        saveSessionNow()
    }

    func addToQueue(_ song: Song) {
        synchronizeTransition()
        guard song.id != current?.id, !queue.contains(where: { $0.id == song.id }) else { return }
        queue.append(song)
        saveSessionNow()
    }

    func addToQueue(_ songs: [Song]) {
        synchronizeTransition()
        var seen = Set(queue.map(\.id) + [current?.id].compactMap { $0 })
        queue.append(contentsOf: songs.filter { seen.insert($0.id).inserted })
        saveSessionNow()
    }

    func removeFromQueue(_ song: Song) {
        synchronizeTransition()
        queue.removeAll { $0.id == song.id }
        saveSessionNow()
    }

    func removeQueue(at offsets: IndexSet) {
        let ids = Set(offsets.compactMap { queue.indices.contains($0) ? queue[$0].id : nil })
        synchronizeTransition()
        queue.removeAll { ids.contains($0.id) }
        saveSessionNow()
    }

    func removeQueue(ids: Set<UUID>) {
        synchronizeTransition()
        queue.removeAll { ids.contains($0.id) }
        saveSessionNow()
    }

    func removeSongs(ids: Set<UUID>) {
        cancelScheduledTransition()
        stopOutgoingAudio()
        guard !ids.isEmpty else { return }
        queue.removeAll { ids.contains($0.id) }
        library.removeAll { ids.contains($0.id) }
        if let current, ids.contains(current.id) {
            audio?.stop()
            audio = nil
            timer?.invalidate()
            self.current = nil
            isPlaying = false
            progress = 0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        } else if let current, let index = library.firstIndex(where: { $0.id == current.id }) {
            currentIndex = index
        }
        saveSessionNow()
    }

    func reconcileDuplicates(songs: [Song], replacements: [UUID: UUID], previousCurrentID: UUID?, previousQueueIDs: [UUID]) {
        cancelScheduledTransition()
        stopOutgoingAudio()
        library = songs
        if let ids = contextSongIDs {
            var seen = Set<UUID>()
            contextSongIDs = ids.map { replacements[$0] ?? $0 }.filter { seen.insert($0).inserted }
        }
        let lookup = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        var seen = Set<UUID>()
        let currentID = previousCurrentID.map { replacements[$0] ?? $0 }
        queue = previousQueueIDs.compactMap { originalID in
            let id = replacements[originalID] ?? originalID
            guard id != currentID, seen.insert(id).inserted else { return nil }
            return lookup[id]
        }
        if let previousCurrentID, let replacementID = replacements[previousCurrentID], let replacement = lookup[replacementID] {
            let position = audio?.currentTime ?? 0
            let playing = isPlaying
            let previousListening = listening
            if !prepare(replacement, at: position, shouldPlay: playing) { stop(); current = nil; audio = nil }
            else if let previousListening {
                listening = PlaybackHistoryProgress(songID: replacementID, listened: previousListening.listened, counted: previousListening.counted)
            }
        } else if let currentID {
            current = lookup[currentID]
            currentIndex = songs.firstIndex { $0.id == currentID } ?? 0
        }
        saveSessionNow()
    }

    func moveQueue(from offsets: IndexSet, to destination: Int) {
        var ids = queue.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        synchronizeTransition()
        let lookup = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0) })
        queue = ids.compactMap { lookup[$0] }
        saveSessionNow()
    }

    func clearQueue() {
        synchronizeTransition()
        guard !queue.isEmpty else { return }
        queue.removeAll()
        saveSessionNow()
    }

    func toggleShuffle() {
        synchronizeTransition()
        shuffle.toggle()
        saveSessionNow()
    }

    func cycleRepeatMode() {
        synchronizeTransition()
        repeatMode = (repeatMode + 1) % 2
        updateLoopMode()
        saveSessionNow()
    }

    func next() {
        synchronizeTransition()
        guard !expireSleepTimerIfNeeded() else { return }
        cancelScheduledTransition()
        while !queue.isEmpty {
            let nextSong = queue.removeFirst()
            if prepare(nextSong, at: 0, shouldPlay: true) {
                saveSessionNow()
                return
            }
        }
        let tracks = playbackSongs
        guard !tracks.isEmpty else { return }
        let index = tracks.firstIndex { $0.id == current?.id } ?? -1
        let candidates = shuffle ? tracks.shuffled() : Array(tracks.dropFirst(index + 1))
        for song in candidates where prepare(song, at: 0, shouldPlay: true) { saveSessionNow(); return }
        if !isPlaying || audio?.isPlaying == false { stop() }
        saveSessionNow()
    }

    func previous() {
        synchronizeTransition()
        guard !expireSleepTimerIfNeeded() else { return }
        let tracks = playbackSongs
        guard !tracks.isEmpty else { return }
        if (audio?.currentTime ?? 0) > 3 { seek(0); return }
        let index = tracks.firstIndex { $0.id == current?.id } ?? 0
        for song in tracks.prefix(max(1, index)).reversed() where prepare(song, at: 0, shouldPlay: true) { break }
        saveSessionNow()
    }

    func toggle() {
        synchronizeTransition()
        guard !expireSleepTimerIfNeeded() else { return }
        guard !interruptionInProgress else { resumeAfterInterruption = false; return }
        resumeAfterInterruption = false
        guard let audio else { return }
        if isPlaying {
            recordListening()
            cancelScheduledTransition()
            audio.pause()
            stopOutgoingAudio()
            timer?.invalidate()
            sleepFading = false
            audio.setVolume(1, fadeDuration: 0)
        } else {
            configureSession()
            if sleepFadeEnabled, let deadline = sleepDeadline { audio.volume = PlaybackTiming.sleepGain(deadline: deadline, now: Date(), fadeDuration: 5) }
            if audio.play() { startTimer() }
            resetListeningBaseline()
        }
        isPlaying = audio.isPlaying
        updateNowPlaying()
        saveSessionNow()
    }

    func seek(_ value: Double) {
        guard value.isFinite else { return }
        synchronizeTransition()
        recordListening()
        cancelScheduledTransition()
        stopOutgoingAudio()
        guard let audio else { return }
        resetSleepFade()
        if sleepFadeEnabled, let deadline = sleepDeadline { audio.volume = PlaybackTiming.sleepGain(deadline: deadline, now: Date(), fadeDuration: 5) }
        audio.currentTime = min(max(0, value * audio.duration), audio.duration)
        resetListeningBaseline()
        progress = audio.duration == 0 ? 0 : audio.currentTime / audio.duration
        updateNowPlaying()
        saveSessionNow()
    }

    func seekBy(_ seconds: Double) {
        guard seconds.isFinite else { return }
        synchronizeTransition()
        recordListening()
        cancelScheduledTransition()
        stopOutgoingAudio()
        guard let audio else { return }
        resetSleepFade()
        if sleepFadeEnabled, let deadline = sleepDeadline { audio.volume = PlaybackTiming.sleepGain(deadline: deadline, now: Date(), fadeDuration: 5) }
        audio.currentTime = min(max(0, audio.currentTime + seconds), audio.duration)
        resetListeningBaseline()
        progress = audio.duration == 0 ? 0 : audio.currentTime / audio.duration
        updateNowPlaying()
        saveSessionNow()
    }

    func stop() {
        recordListening()
        cancelScheduledTransition()
        audio?.pause()
        stopOutgoingAudio()
        audio?.setVolume(1, fadeDuration: 0)
        sleepFading = false
        resumeAfterInterruption = false
        timer?.invalidate()
        isPlaying = false
        updateNowPlaying()
        saveSessionNow()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player === outgoingAudio {
            stopOutgoingAudio()
            refreshScheduledTransition()
            return
        }
        if let transition = scheduledTransition, player === audio {
            if expireSleepTimerIfNeeded() { return }
            synchronizeTransition(force: true)
            if audio === transition.player { return }
        }
        guard player === audio else { return }
        recordListening()
        if expireSleepTimerIfNeeded() { return }
        if sleepAfterCurrentSong {
            stop()
            cancelSleepTimer()
            return
        }
        if repeatMode == 1, let current { _ = prepare(current, at: 0, shouldPlay: true); saveSessionNow() }
        else if !queue.isEmpty || playbackSongs.last?.id != current?.id || shuffle { next() }
        else {
            player.currentTime = 0
            progress = 0
            isPlaying = false
            timer?.invalidate()
            updateNowPlaying()
            saveSessionNow()
        }
    }

    private func configureSession() { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default); try? AVAudioSession.sharedInstance().setActive(true) }

    @discardableResult
    private func prepare(_ song: Song, at position: TimeInterval, shouldPlay: Bool) -> Bool {
        let url = LibraryStore.musicURL.appendingPathComponent(song.fileName)
        guard FileManager.default.fileExists(atPath: url.path), let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        guard player.prepareToPlay() else { return false }
        recordListening()
        cancelScheduledTransition()
        stopOutgoingAudio()
        audio?.stop()
        player.delegate = self
        player.currentTime = min(max(0, position), player.duration)
        audio = player
        current = song
        listening = PlaybackHistoryProgress(songID: song.id)
        resetListeningBaseline()
        currentIndex = library.firstIndex(where: { $0.id == song.id }) ?? currentIndex
        updateLoopMode()
        sleepFading = false
        if sleepFadeEnabled, let deadline = sleepDeadline { player.volume = PlaybackTiming.sleepGain(deadline: deadline, now: Date(), fadeDuration: 5) }
        if shouldPlay && !interruptionInProgress { configureSession(); isPlaying = player.play(); if isPlaying { startTimer() } }
        else { timer?.invalidate(); isPlaying = false }
        progress = player.duration == 0 ? 0 : player.currentTime / player.duration
        updateNowPlaying()
        armSleepTimer()
        return true
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateProgress() }
        }
    }
    private func updateProgress() {
        if expireSleepTimerIfNeeded() { return }
        synchronizeTransition()
        recordListening()
        guard let audio else { return }
        progress = audio.duration == 0 ? 0 : audio.currentTime / audio.duration
        updateNowPlaying()
        if isPlaying, abs(audio.currentTime - lastSavedPosition) >= 10 { scheduleSessionSave() }
    }

    private func resetListeningBaseline() {
        listeningClock = audio?.deviceCurrentTime ?? 0
        listeningPosition = audio?.currentTime ?? 0
    }

    private func sampleListening(_ player: AVAudioPlayer, state: inout PlaybackHistoryProgress, clock: inout Double, position: inout Double) -> Int {
        let now = player.deviceCurrentTime
        let currentPosition = player.currentTime
        let elapsed = max(0, now - clock)
        defer { clock = now; position = currentPosition }
        guard elapsed.isFinite, player.duration.isFinite, player.duration > 0 else { return 0 }
        if player.numberOfLoops == -1, player.isPlaying {
            let untilLoop = max(0, player.duration - position)
            guard elapsed >= untilLoop else { return state.consume(elapsed, duration: player.duration) ? 1 : 0 }
            var count = state.consume(untilLoop, duration: player.duration) ? 1 : 0
            let remainder = elapsed - untilLoop
            let cycles = min(Double(Int.max / 2), floor(remainder / player.duration))
            count += Int(cycles)
            state = PlaybackHistoryProgress(songID: state.songID)
            if state.consume(remainder.truncatingRemainder(dividingBy: player.duration), duration: player.duration) { count += 1 }
            return count
        }
        return state.consume(min(elapsed, max(0, currentPosition - position)), duration: player.duration) ? 1 : 0
    }

    private func recordOutgoingListening() {
        guard let outgoingAudio, let outgoingSong, var state = outgoingListening else { return }
        let count = sampleListening(outgoingAudio, state: &state, clock: &outgoingListeningClock, position: &outgoingListeningPosition)
        outgoingListening = state
        if count > 0 { outgoingSong.registerPlayback(count: count); historyDirty = true }
    }

    private func recordListening() {
        guard !historySuspended else { return }
        if isPlaying, let audio, let current, var state = listening, state.songID == current.id {
            let count = sampleListening(audio, state: &state, clock: &listeningClock, position: &listeningPosition)
            listening = state
            if count > 0 { current.registerPlayback(count: count); historyDirty = true }
        }
        recordOutgoingListening()
        if historyDirty, let historyContext {
            do { try historyContext.save(); historyDirty = false }
            catch { /* Keep changes pending; retry at the next playback event. */ }
        }
    }

    func prepareForLibraryMutation() {
        synchronizeTransition()
        recordListening()
        cancelScheduledTransition()
        stopOutgoingAudio()
        historySuspended = true
    }

    func finishLibraryMutation() { historySuspended = false; refreshScheduledTransition() }

    private func updateNowPlaying() { guard let s = current else { return }; var info: [String: Any] = [MPMediaItemPropertyTitle: s.title, MPMediaItemPropertyArtist: s.artist, MPMediaItemPropertyAlbumTitle: s.album, MPMediaItemPropertyPlaybackDuration: audio?.duration ?? s.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: audio?.currentTime ?? 0, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0]; if let d = s.artworkData, let image = UIImage(data: d) { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }; MPNowPlayingInfoCenter.default().nowPlayingInfo = info }

    private func restoreSessionIfPossible() {
        guard !didAttemptSessionRestore, !library.isEmpty, let session = pendingSession else { return }
        didAttemptSessionRestore = true
        shuffle = session.shuffle
        repeatMode = session.repeatMode
        let lookup = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        var seen = Set<UUID>()
        queue = session.queueSongIDs.compactMap { id in
            guard id != session.currentSongID, seen.insert(id).inserted else { return nil }
            return lookup[id]
        }
        contextSongIDs = session.contextSongIDs?.filter { lookup[$0] != nil }
        pendingSession = nil
        guard let currentID = session.currentSongID, let song = library.first(where: { $0.id == currentID }) else {
            saveSessionNow()
            return
        }
        if !prepare(song, at: session.position, shouldPlay: false) {
            current = nil
            audio = nil
            progress = 0
        }
        if current != nil, session.history?.songID == currentID { listening = session.history }
        saveSessionNow()
    }

    private static func loadSession() -> PlaybackSession? {
        guard let data = UserDefaults.standard.data(forKey: PlaybackSession.storageKey) else { return nil }
        return try? JSONDecoder().decode(PlaybackSession.self, from: data)
    }

    private func scheduleSessionSave() {
        guard sessionSaveWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.sessionSaveWorkItem = nil
                self?.saveSessionNow(refreshTransition: false)
            }
        }
        sessionSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func saveSessionNow(refreshTransition: Bool = true) {
        recordListening()
        sessionSaveWorkItem?.cancel()
        sessionSaveWorkItem = nil
        guard let data = try? JSONEncoder().encode(PlaybackSession(
            currentSongID: current?.id,
            position: audio?.currentTime ?? 0,
            queueSongIDs: queue.map(\.id),
            shuffle: shuffle,
            repeatMode: repeatMode,
            history: listening,
            contextSongIDs: contextSongIDs
        )) else { return }
        UserDefaults.standard.set(data, forKey: PlaybackSession.storageKey)
        lastSavedPosition = audio?.currentTime ?? 0
        if refreshTransition { refreshScheduledTransition(); armSleepTimer() }
    }

    func setCrossfadeEnabled(_ enabled: Bool) {
        synchronizeTransition()
        crossfadeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "playback.crossfadeEnabled")
        refreshScheduledTransition()
    }

    func setCrossfadeDuration(_ seconds: Double) {
        guard seconds.isFinite else { return }
        synchronizeTransition()
        crossfadeDuration = min(12, max(0, seconds))
        UserDefaults.standard.set(crossfadeDuration, forKey: "playback.crossfadeDuration")
        refreshScheduledTransition()
    }

    func setGaplessEnabled(_ enabled: Bool) {
        synchronizeTransition()
        gaplessEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "playback.gaplessEnabled")
        refreshScheduledTransition()
    }

    private func updateLoopMode() {
        // Decoder-native looping preserves supported encoder trim information.
        audio?.numberOfLoops = repeatMode == 1 && !sleepAfterCurrentSong ? -1 : 0
    }

    private func cancelScheduledTransition() {
        transitionWork?.cancel()
        transitionWork = nil
        scheduledTransition?.player.stop()
        scheduledTransition = nil
    }

    private func stopOutgoingAudio() {
        recordOutgoingListening()
        outgoingWork?.cancel()
        outgoingWork = nil
        outgoingAudio?.stop()
        outgoingAudio = nil
        outgoingListening = nil
        outgoingSong = nil
        if !sleepFading { audio?.setVolume(1, fadeDuration: 0) }
    }

    private func refreshScheduledTransition() {
        cancelScheduledTransition()
        guard isPlaying, let source = audio, outgoingAudio == nil,
              !sleepAfterCurrentSong, !sleepFading, repeatMode == 0 else { return }
        let remaining = max(0, source.duration - source.currentTime)
        guard remaining > 0.05 else { return }
        let candidates: [Song]
        let fromQueue = !queue.isEmpty
        if fromQueue { candidates = queue }
        else if shuffle { candidates = playbackSongs.filter { $0.id != current?.id }.shuffled() }
        else {
            let tracks = playbackSongs
            let index = tracks.firstIndex { $0.id == current?.id } ?? -1
            candidates = Array(tracks.dropFirst(index + 1))
        }
        for song in candidates {
            let url = LibraryStore.musicURL.appendingPathComponent(song.fileName)
            guard let successor = try? AVAudioPlayer(contentsOf: url), successor.prepareToPlay(), successor.duration > 0 else { continue }
            let overlap = PlaybackTiming.overlap(requested: crossfadeEnabled ? crossfadeDuration : 0, outgoing: source.duration, incoming: successor.duration, remaining: remaining)
            let compatible = abs(source.format.sampleRate - successor.format.sampleRate) < 0.01 && source.format.channelCount == successor.format.channelCount
            guard overlap > 0 || (gaplessEnabled && compatible) else { return }
            let delay = remaining - overlap
            // Do not schedule audio past the sleep deadline; a sleeping process must
            // never start a prequeued player after that deadline.
            if let deadline = sleepDeadline, deadline.timeIntervalSinceNow <= remaining + 5 { return }
            successor.delegate = self
            successor.volume = overlap > 0 ? 0 : 1
            let startsAt = source.deviceCurrentTime + delay
            guard successor.play(atTime: startsAt) else { return }
            scheduledTransition = ScheduledTransition(song: song, player: successor, startsAt: startsAt, overlap: overlap, fromQueue: fromQueue)
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.synchronizeTransition() }
            }
            transitionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }
    }

    private func synchronizeTransition(force: Bool = false) {
        guard let next = scheduledTransition, let source = audio,
              force || source.deviceCurrentTime >= next.startsAt else { return }
        if expireSleepTimerIfNeeded() { return }
        recordListening()
        transitionWork?.cancel()
        transitionWork = nil
        scheduledTransition = nil
        if next.fromQueue, let index = queue.firstIndex(where: { $0.id == next.song.id }) { queue.removeFirst(index + 1) }
        outgoingListening = listening
        outgoingSong = current
        outgoingListeningClock = listeningClock
        outgoingListeningPosition = listeningPosition
        audio = next.player
        current = next.song
        currentIndex = library.firstIndex { $0.id == next.song.id } ?? currentIndex
        listening = PlaybackHistoryProgress(songID: next.song.id)
        // A scheduled crossfade player stays muted until promotion; don't count
        // time it spent silently waiting for the main-thread transition event.
        listeningClock = next.overlap > 0 ? next.player.deviceCurrentTime : next.startsAt
        listeningPosition = next.overlap > 0 ? next.player.currentTime : 0
        let fadeRemaining = max(0, next.overlap - next.player.currentTime)
        if fadeRemaining > 0, source.isPlaying {
            outgoingAudio = source
            source.setVolume(0, fadeDuration: fadeRemaining)
            next.player.setVolume(1, fadeDuration: fadeRemaining)
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.stopOutgoingAudio()
                    self?.refreshScheduledTransition()
                }
            }
            outgoingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeRemaining, execute: work)
        } else {
            source.stop()
            outgoingListening = nil
            outgoingSong = nil
            next.player.volume = 1
        }
        updateLoopMode()
        progress = next.player.currentTime / next.player.duration
        updateNowPlaying()
        saveSessionNow()
    }

    func startSleepTimer(minutes: Int) {
        guard [5, 10, 15, 30, 45, 60].contains(minutes) else { return }
        synchronizeTransition()
        sleepAfterCurrentSong = false
        sleepDeadline = Date().addingTimeInterval(Double(minutes) * 60)
        UserDefaults.standard.set(sleepDeadline, forKey: "playback.sleepDeadline")
        updateLoopMode()
        resetSleepFade()
        armSleepTimer()
        refreshScheduledTransition()
    }

    func sleepAtEndOfCurrentSong() {
        synchronizeTransition()
        guard current != nil else { return }
        sleepDeadline = nil
        UserDefaults.standard.removeObject(forKey: "playback.sleepDeadline")
        sleepAfterCurrentSong = true
        updateLoopMode()
        cancelScheduledTransition()
        stopOutgoingAudio()
        resetSleepFade()
        armSleepTimer()
    }

    func cancelSleepTimer() {
        sleepDeadline = nil
        sleepAfterCurrentSong = false
        UserDefaults.standard.removeObject(forKey: "playback.sleepDeadline")
        sleepStopWork?.cancel()
        sleepFadeWork?.cancel()
        resetSleepFade()
        updateLoopMode()
        refreshScheduledTransition()
    }

    func setSleepFadeEnabled(_ enabled: Bool) {
        sleepFadeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "playback.sleepFadeEnabled")
        resetSleepFade()
        armSleepTimer()
        refreshScheduledTransition()
    }

    private func resetSleepFade() {
        if sleepFading { stopOutgoingAudio(); audio?.setVolume(1, fadeDuration: 0) }
        sleepFading = false
    }

    @discardableResult
    private func expireSleepTimerIfNeeded() -> Bool {
        guard let deadline = sleepDeadline, deadline <= Date() else { return false }
        sleepDeadline = nil
        sleepAfterCurrentSong = false
        UserDefaults.standard.removeObject(forKey: "playback.sleepDeadline")
        sleepStopWork?.cancel()
        sleepFadeWork?.cancel()
        stop()
        return true
    }

    private func armSleepTimer() {
        sleepStopWork?.cancel()
        sleepFadeWork?.cancel()
        guard !expireSleepTimerIfNeeded() else { return }
        if let deadline = sleepDeadline {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            let stopWork = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    if self?.expireSleepTimerIfNeeded() == false { self?.armSleepTimer() }
                }
            }
            sleepStopWork = stopWork
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + remaining, execute: stopWork)
            scheduleSleepFade(after: remaining - 5, duration: min(5, remaining))
        } else if sleepAfterCurrentSong, isPlaying, let audio {
            let remaining = max(0, audio.duration - audio.currentTime)
            scheduleSleepFade(after: remaining - 5, duration: min(5, remaining))
        }
    }

    private func scheduleSleepFade(after delay: Double, duration: Double) {
        guard sleepFadeEnabled, isPlaying, duration > 0 else { return }
        if delay <= 0 { beginSleepFade(duration: duration); return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let duration = self.sleepDeadline.map { min(5, max(0, $0.timeIntervalSinceNow)) } ?? min(5, max(0, (self.audio?.duration ?? 0) - (self.audio?.currentTime ?? 0)))
                self.beginSleepFade(duration: duration)
            }
        }
        sleepFadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginSleepFade(duration: Double) {
        guard sleepDeadline != nil || sleepAfterCurrentSong else { return }
        guard isPlaying, sleepFadeEnabled, duration > 0 else { return }
        cancelScheduledTransition()
        sleepFading = true
        if let outgoingAudio { outgoingAudio.setVolume(0, fadeDuration: min(duration, max(0, outgoingAudio.duration - outgoingAudio.currentTime))) }
        audio?.setVolume(0, fadeDuration: duration)
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resumeFromRemote() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pauseFromRemote() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in
                guard let self, let duration = self.audio?.duration, duration > 0 else { return }
                self.seek(seconds / duration)
            }
            return .success
        }
        // iOS shares these commands between Lock Screen and Control Center.
        // Interval commands take the transport slots away from track navigation.
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        c.changePlaybackPositionCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
    }
    private func resumeFromRemote() { if !isPlaying { toggle() } }
    private func pauseFromRemote() { resumeAfterInterruption = false; if isPlaying { toggle() } }
    @objc private func saveForAppTransition() { _ = expireSleepTimerIfNeeded(); synchronizeTransition(); saveSessionNow(refreshTransition: false) }
    @objc private func becameActive() {
        guard !expireSleepTimerIfNeeded() else { return }
        synchronizeTransition()
        armSleepTimer()
        refreshScheduledTransition()
    }
    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            synchronizeTransition()
            resumeAfterInterruption = isPlaying
            interruptionInProgress = true
            pauseForAudioSession()
        } else {
            interruptionInProgress = false
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            let shouldResume = resumeAfterInterruption && options.contains(.shouldResume)
            resumeAfterInterruption = false
            if expireSleepTimerIfNeeded() { return }
            if shouldResume, !isPlaying { toggle() }
        }
    }

    private func pauseForAudioSession() {
        recordListening()
        cancelScheduledTransition()
        audio?.pause()
        stopOutgoingAudio()
        resetSleepFade()
        timer?.invalidate()
        isPlaying = false
        updateNowPlaying()
        saveSessionNow()
    }

    @objc private func mediaServicesReset() {
        let position = audio?.currentTime ?? 0
        let song = current
        cancelScheduledTransition()
        stopOutgoingAudio()
        audio = nil
        isPlaying = false
        interruptionInProgress = false
        resumeAfterInterruption = false
        configureSession()
        if let song { _ = prepare(song, at: position, shouldPlay: false) }
        saveSessionNow()
    }

    @objc private func routeChanged(_ note: Notification) {
        synchronizeTransition()
        if let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
           reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
            resumeAfterInterruption = false
            pauseForAudioSession()
        } else { cancelScheduledTransition(); stopOutgoingAudio(); refreshScheduledTransition(); armSleepTimer() }
    }
}
