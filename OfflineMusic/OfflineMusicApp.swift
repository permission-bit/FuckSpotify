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
    var artistIDs: [UUID] = []
    var genreIDs: [UUID] = []
    var importedGenre: String = ""
    var originalGenreIDs: [UUID] = []
    var inferredGenreIDs: [UUID] = []
    var genreOverrideID: UUID?
    init(title: String, artist: String = "Unknown Artist", album: String = "Unknown Album", duration: Double = 0, fileName: String, artworkData: Data? = nil, importedGenre: String = "") {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration; self.fileName = fileName; self.artworkData = artworkData; self.importedGenre = importedGenre
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

struct PlaybackSession: Codable, Equatable {
    var currentSongID: UUID?
    var position: TimeInterval
    var queueSongIDs: [UUID]
    var shuffle: Bool
    var repeatMode: Int

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
    private var library: [Song] = []
    private var currentIndex = 0
    private var audio: AVAudioPlayer?
    private var timer: Timer?
    private var pendingSession: PlaybackSession?
    private var didAttemptSessionRestore = false
    private var sessionSaveWorkItem: DispatchWorkItem?
    private var lastSavedPosition: TimeInterval = 0

    private override init() {
        pendingSession = Self.loadSession()
        super.init()
        configureSession()
        configureRemoteCommands()
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(saveForAppTransition), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(saveForAppTransition), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func setLibrary(_ songs: [Song]) {
        library = songs
        let availableIDs = Set(songs.map(\.id))
        if !queue.isEmpty { queue.removeAll { !availableIDs.contains($0.id) } }
        if let current, !availableIDs.contains(current.id) {
            audio?.stop()
            audio = nil
            self.current = nil
            isPlaying = false
            progress = 0
        } else if let current, let index = songs.firstIndex(where: { $0.id == current.id }) {
            currentIndex = index
        }
        restoreSessionIfPossible()
    }

    func play(_ song: Song) {
        queue.removeAll { $0.id == song.id }
        _ = prepare(song, at: 0, shouldPlay: true)
        saveSessionNow()
    }

    func playNext(_ song: Song) {
        guard song.id != current?.id else { return }
        queue.removeAll { $0.id == song.id || $0.id == current?.id }
        queue.insert(song, at: 0)
        saveSessionNow()
    }

    func addToQueue(_ song: Song) {
        guard song.id != current?.id, !queue.contains(where: { $0.id == song.id }) else { return }
        queue.append(song)
        saveSessionNow()
    }

    func addToQueue(_ songs: [Song]) {
        let existing = Set(queue.map(\.id) + [current?.id].compactMap { $0 })
        queue.append(contentsOf: songs.filter { !existing.contains($0.id) })
        saveSessionNow()
    }

    func removeFromQueue(_ song: Song) {
        queue.removeAll { $0.id == song.id }
        saveSessionNow()
    }

    func removeQueue(at offsets: IndexSet) {
        queue.remove(atOffsets: offsets)
        saveSessionNow()
    }

    func removeQueue(ids: Set<UUID>) {
        queue.removeAll { ids.contains($0.id) }
        saveSessionNow()
    }

    func removeSongs(ids: Set<UUID>) {
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

    func moveQueue(from offsets: IndexSet, to destination: Int) {
        queue.move(fromOffsets: offsets, toOffset: destination)
        saveSessionNow()
    }

    func clearQueue() {
        guard !queue.isEmpty else { return }
        queue.removeAll()
        saveSessionNow()
    }

    func toggleShuffle() {
        shuffle.toggle()
        saveSessionNow()
    }

    func cycleRepeatMode() {
        repeatMode = (repeatMode + 1) % 2
        saveSessionNow()
    }

    func next() {
        while !queue.isEmpty {
            let nextSong = queue.removeFirst()
            if prepare(nextSong, at: 0, shouldPlay: true) {
                saveSessionNow()
                return
            }
        }
        guard !library.isEmpty else { return }
        currentIndex = shuffle ? Int.random(in: 0..<library.count) : min(currentIndex + 1, library.count - 1)
        _ = prepare(library[currentIndex], at: 0, shouldPlay: true)
        saveSessionNow()
    }

    func previous() {
        guard !library.isEmpty else { return }
        if (audio?.currentTime ?? 0) > 3 { seek(0); return }
        currentIndex = max(currentIndex - 1, 0)
        _ = prepare(library[currentIndex], at: 0, shouldPlay: true)
        saveSessionNow()
    }

    func toggle() {
        guard let audio else { return }
        if audio.isPlaying {
            audio.pause()
            timer?.invalidate()
        } else {
            audio.play()
            startTimer()
        }
        isPlaying = audio.isPlaying
        updateNowPlaying()
        saveSessionNow()
    }

    func seek(_ value: Double) {
        guard let audio else { return }
        audio.currentTime = min(max(0, value * audio.duration), audio.duration)
        progress = audio.duration == 0 ? 0 : audio.currentTime / audio.duration
        updateNowPlaying()
        saveSessionNow()
    }

    func seekBy(_ seconds: Double) {
        guard let audio else { return }
        audio.currentTime = min(max(0, audio.currentTime + seconds), audio.duration)
        progress = audio.duration == 0 ? 0 : audio.currentTime / audio.duration
        updateNowPlaying()
        saveSessionNow()
    }

    func stop() {
        audio?.stop()
        timer?.invalidate()
        isPlaying = false
        updateNowPlaying()
        saveSessionNow()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if repeatMode == 1, let current { _ = prepare(current, at: 0, shouldPlay: true) }
        else if !queue.isEmpty || currentIndex < library.count - 1 || shuffle { next() }
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
        player.delegate = self
        player.prepareToPlay()
        player.currentTime = min(max(0, position), player.duration)
        audio = player
        current = song
        currentIndex = library.firstIndex(where: { $0.id == song.id }) ?? currentIndex
        if shouldPlay { player.play(); startTimer() } else { timer?.invalidate() }
        isPlaying = shouldPlay
        progress = player.duration == 0 ? 0 : player.currentTime / player.duration
        updateNowPlaying()
        return true
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateProgress() }
        }
    }
    private func updateProgress() {
        guard let audio else { return }
        progress = audio.duration == 0 ? 0 : audio.currentTime / audio.duration
        updateNowPlaying()
        if isPlaying, abs(audio.currentTime - lastSavedPosition) >= 10 { scheduleSessionSave() }
    }

    private func updateNowPlaying() { guard let s = current else { return }; var info: [String: Any] = [MPMediaItemPropertyTitle: s.title, MPMediaItemPropertyArtist: s.artist, MPMediaItemPropertyAlbumTitle: s.album, MPMediaItemPropertyPlaybackDuration: audio?.duration ?? s.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: audio?.currentTime ?? 0, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0]; if let d = s.artworkData, let image = UIImage(data: d) { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }; MPNowPlayingInfoCenter.default().nowPlayingInfo = info }

    private func restoreSessionIfPossible() {
        guard !didAttemptSessionRestore, !library.isEmpty, let session = pendingSession else { return }
        didAttemptSessionRestore = true
        shuffle = session.shuffle
        repeatMode = session.repeatMode
        queue = session.queueSongIDs.compactMap { id in library.first { $0.id == id } }
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
                self?.saveSessionNow()
            }
        }
        sessionSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func saveSessionNow() {
        sessionSaveWorkItem?.cancel()
        sessionSaveWorkItem = nil
        guard let data = try? JSONEncoder().encode(PlaybackSession(
            currentSongID: current?.id,
            position: audio?.currentTime ?? 0,
            queueSongIDs: queue.map(\.id),
            shuffle: shuffle,
            repeatMode: repeatMode
        )) else { return }
        UserDefaults.standard.set(data, forKey: PlaybackSession.storageKey)
        lastSavedPosition = audio?.currentTime ?? 0
    }
    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resumeFromRemote(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pauseFromRemote(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }; self?.seek(e.positionTime / (self?.audio?.duration ?? 1)); return .success }
        // iOS shares these commands between Lock Screen and Control Center.
        // Interval commands take the transport slots away from track navigation.
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        c.changePlaybackPositionCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
    }
    private func resumeFromRemote() { if audio?.isPlaying == false { toggle() } }
    private func pauseFromRemote() { if audio?.isPlaying == true { toggle() } }
    @objc private func saveForAppTransition() { saveSessionNow() }
    @objc private func routeChanged(_ note: Notification) {
        if let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
           reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
            audio?.pause()
            timer?.invalidate()
            isPlaying = false
            updateNowPlaying()
            saveSessionNow()
        }
    }
}
