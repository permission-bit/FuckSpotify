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
    init(title: String, artist: String = "Unknown Artist", album: String = "Unknown Album", duration: Double = 0, fileName: String, artworkData: Data? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration; self.fileName = fileName; self.artworkData = artworkData
    }
}

@Model final class Playlist: Identifiable {
    var id: UUID = UUID()
    var name: String
    var songIDs: [UUID] = []
    var artistName: String = ""
    var createdAt: Date = Date()
    init(name: String, artistName: String = "") { self.name = name; self.artistName = artistName }
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

@MainActor final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()
    @Published private(set) var current: Song?
    @Published private(set) var isPlaying = false
    @Published var progress = 0.0
    @Published var shuffle = false
    @Published var repeatMode = 0
    @Published private(set) var queue: [Song] = []
    private var library: [Song] = []
    private var currentIndex = 0
    private var audio: AVAudioPlayer?
    private var timer: Timer?
    private override init() { super.init(); configureSession(); configureRemoteCommands(); NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil) }
    func setLibrary(_ songs: [Song]) { library = songs; if let current, let index = songs.firstIndex(where: { $0.id == current.id }) { currentIndex = index } }
    func play(_ song: Song) { queue.removeAll { $0.id == song.id }; if let index = library.firstIndex(where: { $0.id == song.id }) { currentIndex = index }; start(song) }
    func playNext(_ song: Song) {
        guard song.id != current?.id else { return }
        queue.removeAll { $0.id == song.id || $0.id == current?.id }
        queue.insert(song, at: 0)
    }
    func addToQueue(_ song: Song) {
        guard song.id != current?.id, !queue.contains(where: { $0.id == song.id }) else { return }
        queue.append(song)
    }
    func removeFromQueue(_ song: Song) { queue.removeAll { $0.id == song.id } }
    private func start(_ song: Song) { current = song; guard let a = try? AVAudioPlayer(contentsOf: LibraryStore.musicURL.appendingPathComponent(song.fileName)) else { return }; audio = a; a.delegate = self; a.prepareToPlay(); a.play(); isPlaying = true; progress = 0; updateNowPlaying(); startTimer() }
    func next() {
        if !queue.isEmpty { start(queue.removeFirst()); return }
        guard !library.isEmpty else { return }
        currentIndex = shuffle ? Int.random(in: 0..<library.count) : min(currentIndex + 1, library.count - 1)
        start(library[currentIndex])
    }
    func previous() { guard !library.isEmpty else { return }; if (audio?.currentTime ?? 0) > 3 { seek(0); return }; currentIndex = max(currentIndex - 1, 0); start(library[currentIndex]) }
    func toggle() { guard let a = audio else { return }; if a.isPlaying { a.pause() } else { a.play() }; isPlaying = a.isPlaying; updateNowPlaying() }
    func seek(_ value: Double) { audio?.currentTime = value * (audio?.duration ?? 0); progress = value; updateNowPlaying() }
    func seekBy(_ seconds: Double) { guard let audio else { return }; audio.currentTime = min(max(0, audio.currentTime + seconds), audio.duration); progress = audio.duration == 0 ? 0 : audio.currentTime / audio.duration; updateNowPlaying() }
    func stop() { audio?.stop(); timer?.invalidate(); isPlaying = false }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { if repeatMode == 1, let s = current { start(s) } else if currentIndex < library.count - 1 || shuffle { next() } else { stop() } }
    private func configureSession() { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default); try? AVAudioSession.sharedInstance().setActive(true) }
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
    }
    private func updateNowPlaying() { guard let s = current else { return }; var info: [String: Any] = [MPMediaItemPropertyTitle: s.title, MPMediaItemPropertyArtist: s.artist, MPMediaItemPropertyAlbumTitle: s.album, MPMediaItemPropertyPlaybackDuration: audio?.duration ?? s.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: audio?.currentTime ?? 0, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0]; if let d = s.artworkData, let image = UIImage(data: d) { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }; MPNowPlayingInfoCenter.default().nowPlayingInfo = info }
    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.audio?.play(); self?.isPlaying = true; return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.audio?.pause(); self?.isPlaying = false; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }; self?.seek(e.positionTime / (self?.audio?.duration ?? 1)); return .success }
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.seekBy(15); return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.seekBy(-15); return .success }
        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
    }
    @objc private func routeChanged(_ note: Notification) { if let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { audio?.pause(); isPlaying = false } }
}
