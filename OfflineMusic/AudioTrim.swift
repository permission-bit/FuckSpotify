import AVFoundation
import Foundation

struct AudioTrimRange: Equatable, Hashable {
    enum Edge { case start, end }

    let start: TimeInterval
    let end: TimeInterval
    var duration: TimeInterval { end - start }
    var timeRange: CMTimeRange {
        CMTimeRange(start: Self.time(start), end: Self.time(end))
    }

    static func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000)
    }

    func value(for edge: Edge) -> TimeInterval { edge == .start ? start : end }

    func moving(_ edge: Edge, to position: TimeInterval, in length: TimeInterval, minimumLength: TimeInterval = 0.25) -> Self {
        guard position.isFinite else { return self }
        let minimum = min(minimumLength, length)
        switch edge {
        case .start: return Self(start: min(max(0, position), max(0, end - minimum)), end: end)
        case .end: return Self(start: start, end: min(length, max(start + minimum, position)))
        }
    }
}

enum AudioTrimOperation: Hashable {
    case keep, remove
}

struct AudioTrimEdit: Hashable {
    let sourceDuration: TimeInterval
    var selection: AudioTrimRange
    var operation: AudioTrimOperation = .keep

    var duration: TimeInterval {
        operation == .keep ? selection.duration : sourceDuration - selection.duration
    }

    var canPreview: Bool {
        selection.start >= 0 && selection.end <= sourceDuration && selection.duration > 0 &&
            duration >= min(0.05, sourceDuration / 2)
    }

    var hasJoin: Bool {
        operation == .remove && selection.start > 0 && selection.end < sourceDuration
    }

    var remainingRanges: [AudioTrimRange] {
        switch operation {
        case .keep: return [selection]
        case .remove:
            return [AudioTrimRange(start: 0, end: selection.start), AudioTrimRange(start: selection.end, end: sourceDuration)]
                .filter { $0.duration > 0 }
        }
    }

    func previewStart(restart: Bool) -> TimeInterval {
        if operation == .keep { return selection.start }
        return !restart && hasJoin ? max(0, selection.start - 3) : 0
    }

    func sourceTime(forPreviewTime time: TimeInterval) -> TimeInterval {
        if operation == .keep { return min(max(time, selection.start), selection.end) }
        guard time >= selection.start else { return time }
        return time + selection.duration
    }

    func editedTime(forSourceTime time: TimeInterval) -> TimeInterval {
        if operation == .keep { return time - selection.start }
        if time < selection.start { return time }
        return max(selection.start, time - selection.duration)
    }
}

struct AudioTrimEdits {
    private let originalEdit: AudioTrimEdit
    private(set) var edit: AudioTrimEdit
    private var undoStack: [AudioTrimEdit] = []
    private var redoStack: [AudioTrimEdit] = []
    private var dragStart: AudioTrimEdit?

    init(duration: TimeInterval) {
        let full = AudioTrimRange(start: 0, end: duration)
        originalEdit = AudioTrimEdit(sourceDuration: duration, selection: full)
        edit = originalEdit
    }

    var original: AudioTrimRange { originalEdit.selection }
    var selection: AudioTrimRange { edit.selection }
    var hasChanges: Bool { edit != originalEdit }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func setOperation(_ operation: AudioTrimOperation) {
        guard edit.operation != operation else { return }
        let previous = edit
        edit.operation = operation
        if operation == .remove, selection == original {
            let duration = original.duration
            let width = min(max(0.25, duration * 0.2), duration / 2)
            edit.selection = AudioTrimRange(start: (duration - width) / 2, end: (duration + width) / 2)
        }
        record(previous)
    }

    mutating func drag(_ edge: AudioTrimRange.Edge, to position: TimeInterval) {
        if dragStart == nil { dragStart = edit }
        move(edge, to: position)
    }

    mutating func finishDrag() {
        guard let start = dragStart else { return }
        dragStart = nil
        record(start)
    }

    mutating func nudge(_ edge: AudioTrimRange.Edge, by step: TimeInterval) {
        let previous = edit
        let position = ((selection.value(for: edge) + step) * 10).rounded() / 10
        move(edge, to: position)
        record(previous)
    }

    mutating func reset() {
        let previous = edit
        edit = originalEdit
        record(previous)
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edit)
        edit = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edit)
        edit = next
    }

    private mutating func move(_ edge: AudioTrimRange.Edge, to position: TimeInterval) {
        let minimum = edit.operation == .remove ? min(0.25, original.duration / 2) : 0.25
        edit.selection = selection.moving(edge, to: position, in: original.duration, minimumLength: minimum)
    }

    private mutating func record(_ previous: AudioTrimEdit) {
        guard previous != edit else { return }
        undoStack.append(previous)
        redoStack.removeAll()
    }
}

enum AudioTrimFile {
    static func asset(at url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    static func duration(of asset: AVURLAsset) async throws -> TimeInterval {
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isFinite, duration > 0,
              !audioTracks.isEmpty, try await asset.load(.isPlayable) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return duration
    }

    @MainActor
    static func previewItem(for asset: AVURLAsset, edit: AudioTrimEdit) async throws -> AVPlayerItem {
        let source = try await source(for: asset, edit: edit)
        let item = AVPlayerItem(asset: source.asset)
        item.forwardPlaybackEndTime = source.range.end
        return item
    }

    static func waveform(at url: URL, bins: Int = 80) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let length = Double(file.length)
        guard length > 0, bins > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
              let channels = buffer.floatChannelData else { return [] }
        var peaks = [Float](repeating: 0, count: bins)
        while Double(file.framePosition) < length {
            try Task.checkCancellation()
            let start = file.framePosition
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            for frame in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
                let bin = min(bins - 1, Int(Double(start + Int64(frame)) * Double(bins) / length))
                for channel in 0..<Int(buffer.format.channelCount) {
                    peaks[bin] = max(peaks[bin], abs(channels[channel][frame]))
                }
            }
        }
        guard let maximum = peaks.max(), maximum > 0 else { return peaks }
        return peaks.map { sqrt($0 / maximum) }
    }

    static func export(_ asset: AVURLAsset, edit: AudioTrimEdit, to destination: URL, artwork: Data? = nil) async throws {
        let source = try await source(for: asset, edit: edit)
        guard let session = AVAssetExportSession(asset: source.asset, presetName: AVAssetExportPresetAppleM4A),
              session.supportedFileTypes.contains(.m4a) else { throw CocoaError(.fileWriteUnknown) }
        session.timeRange = source.range
        if let artwork, let cover = coverMetadata(for: artwork) { session.metadata = [cover] }

        if #available(iOS 18, macOS 15, *) {
            try await session.export(to: destination, as: .m4a)
        } else {
            session.outputURL = destination
            session.outputFileType = .m4a
            await withTaskCancellationHandler {
                await session.export()
            } onCancel: {
                session.cancelExport()
            }
            try Task.checkCancellation()
            guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
        }
    }

    private static func source(for asset: AVURLAsset, edit: AudioTrimEdit) async throws -> (asset: AVAsset, range: CMTimeRange) {
        guard edit.canPreview else { throw CocoaError(.fileReadCorruptFile) }
        if edit.operation == .keep { return (asset, edit.selection.timeRange) }

        let segments = edit.remainingRanges.map(\.timeRange)
        let duration = segments.reduce(CMTime.zero) { $0 + $1.duration }
        let composition = AVMutableComposition()
        for sourceTrack in try await asset.loadTracks(withMediaType: .audio) {
            let trackRange = try await sourceTrack.load(.timeRange)
            guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var position = CMTime.zero
            for segment in segments {
                let intersection = CMTimeRangeGetIntersection(segment, otherRange: trackRange)
                if intersection.isValid, intersection.duration > .zero {
                    try destination.insertTimeRange(intersection, of: sourceTrack, at: position + (intersection.start - segment.start))
                }
                position = position + segment.duration
            }
        }
        let inserted = try await composition.load(.duration)
        guard inserted > .zero else { throw CocoaError(.fileReadCorruptFile) }
        if inserted < duration {
            composition.insertEmptyTimeRange(CMTimeRange(start: inserted, end: duration))
        }
        return (composition, CMTimeRange(start: .zero, duration: duration))
    }

    private static func coverMetadata(for artwork: Data) -> AVMetadataItem? {
        let item = AVMutableMetadataItem()
        item.identifier = .iTunesMetadataCoverArt
        if artwork.starts(with: [0xff, 0xd8]) {
            item.dataType = kCMMetadataBaseDataType_JPEG as String
        } else if artwork.starts(with: [0x89, 0x50, 0x4e, 0x47]) {
            item.dataType = kCMMetadataBaseDataType_PNG as String
        } else {
            return nil
        }
        item.value = artwork as NSData
        return item
    }
}

#if os(iOS)
import Combine
import SwiftData
import SwiftUI

struct AudioTrimView: View {
    private enum SaveMode { case newClip, original }

    let song: Song

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale

    @State private var asset: AVURLAsset?
    @State private var edits: AudioTrimEdits?
    @State private var waveform: [Float] = []
    @State private var loadFailed = false
    @State private var preview = AVPlayer()
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRunning = false
    @State private var suspendedPlayback: (songID: UUID, sleepDeadline: Date?)?
    @State private var exportNames: [AudioTrimEdit: String] = [:]
    @State private var isSaving = false
    @State private var showingSaveOptions = false
    @State private var savedMode: SaveMode?
    @State private var errorMessage: LocalizedStringKey?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.title2.bold())
                        Text(MetadataText.artist(song.artist)).foregroundStyle(AppTheme.secondaryText)
                    }
                    if let edits {
                        trimControls(edits)
                    } else if loadFailed {
                        ContentUnavailableView("Audiodatei konnte nicht geöffnet werden", systemImage: "waveform.slash")
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .frame(maxWidth: 560)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Audio schneiden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }.disabled(isSaving)
                }
            }
            .musicScreen()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let edits {
                    Button {
                        showingSaveOptions = true
                    } label: {
                        if isSaving {
                            ProgressView("Audio wird gespeichert …")
                                .tint(AppTheme.onAccent)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Speichern").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(AppTheme.onAccent)
                    .controlSize(.large)
                    .disabled(isSaving || !edits.hasChanges || !edits.edit.canPreview)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .background(AppTheme.background)
                }
            }
        }
        .musicScreen()
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog("Audio speichern", isPresented: $showingSaveOptions, titleVisibility: .visible, presenting: edits?.edit) { edit in
            Button("Neuen Clip erstellen") { save(edit, as: .newClip) }
            Button("Original kürzen", role: .destructive) { save(edit, as: .original) }
            Button("Abbrechen", role: .cancel) {}
        } message: { edit in
            if edit.operation == .remove {
                Text("Beim Kürzen des Originals entfernst du den markierten Bereich aus diesem Titel.")
            } else {
                Text("Beim Kürzen des Originals entfernst du den Ton vor und nach der Auswahl aus diesem Titel.")
            }
        }
        .task { await loadAudio() }
        .onDisappear(perform: finishPreview)
        .onChange(of: player.current?.id) { _, _ in cancelPreview() }
        .onChange(of: player.isPlaying) { _, playing in if playing { cancelPreview() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancelPreview() } }
        .onChange(of: player.sleepDeadline) { previous, _ in
            if let previous, previous <= Date() { cancelPreview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { note in
            if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                cancelPreview()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { note in
            if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                cancelPreview()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification).receive(on: RunLoop.main)) { note in
            if let item = note.object as? AVPlayerItem, item === preview.currentItem { stopPreview(reset: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification).receive(on: RunLoop.main)) { note in
            if let item = note.object as? AVPlayerItem, item === preview.currentItem { previewDidFail() }
        }
        .alert("Audio schneiden", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
        .alert(LocalizedStringKey(savedMode == .original ? "Original gekürzt" : "Ausschnitt gespeichert"),
               isPresented: Binding(get: { savedMode != nil }, set: { if !$0 { savedMode = nil } }), presenting: savedMode) { _ in
            Button("Fertig") { dismiss() }
        } message: { mode in
            if mode == .newClip { Text("Du findest den Ausschnitt als eigenen Titel in deiner Bibliothek.") }
        }
    }

    private func trimControls(_ edits: AudioTrimEdits) -> some View {
        let edit = edits.edit
        return VStack(spacing: 14) {
            operationPicker(edit.operation)
            VStack(spacing: 8) {
                Text("Ziehe die Griffe, um Start und Ende festzulegen.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !previewRunning)) { _ in
                    AudioTrimTimeline(
                        edit: edit, waveform: waveform,
                        playhead: preview.currentItem == nil ? nil : edit.sourceTime(forPreviewTime: preview.currentTime().seconds),
                        onDrag: { edge, position in
                            if previewRunning || preview.currentItem != nil { stopPreview(reset: true) }
                            self.edits?.drag(edge, to: position)
                        },
                        onFinish: { self.edits?.finishDrag() }
                    )
                }
            }
            VStack(spacing: 6) {
                edgeControl("Startpunkt", edge: .start, at: edits.selection.start)
                edgeControl("Endpunkt", edge: .end, at: edits.selection.end)
                LabeledContent("Dauer") { Text(time(edit.duration)).monospacedDigit() }
            }
            .padding(12)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))

            if !edit.canPreview {
                Text("Wähle einen kleineren Bereich, damit Audio übrig bleibt.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            HStack(spacing: 12) {
                Button {
                    startPreview(restart: true)
                } label: {
                    Image(systemName: "backward.end.fill").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Vorschau von vorn abspielen")

                Button {
                    if previewRunning { stopPreview() }
                    else { startPreview() }
                } label: {
                    Label(previewTitle(for: edit),
                          systemImage: previewRunning ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!edit.canPreview)

            HStack(spacing: 8) {
                Button {
                    stopPreview(reset: true)
                    self.edits?.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Schnitt rückgängig machen")
                .disabled(!edits.canUndo)

                Button {
                    stopPreview(reset: true)
                    self.edits?.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Schnitt wiederholen")
                .disabled(!edits.canRedo)
                Spacer(minLength: 0)

                Button("Auf Original zurücksetzen") {
                    stopPreview(reset: true)
                    self.edits?.reset()
                }
                .frame(minHeight: 44)
                .disabled(!edits.hasChanges)
            }
            .buttonStyle(.borderless)
        }
        .disabled(isSaving)
    }

    private func operationPicker(_ operation: AudioTrimOperation) -> some View {
        let selection = Binding(get: { self.edits?.edit.operation ?? operation }, set: { operation in
            stopPreview(reset: true)
            self.edits?.setOperation(operation)
        })
        return MusicFilterPicker(title: "Schnittmodus", options: [(.keep, "Auswahl behalten"), (.remove, "Auswahl entfernen")], selection: selection)
    }

    private func previewTitle(for edit: AudioTrimEdit) -> LocalizedStringKey {
        if previewRunning { return "Vorschau pausieren" }
        if edit.hasJoin && preview.currentItem == nil { return "Schnittstelle anhören" }
        return "Vorschau anhören"
    }

    private func edgeControl(_ label: LocalizedStringKey, edge: AudioTrimRange.Edge, at position: TimeInterval) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Spacer(minLength: 4)
            Button { adjust(edge, by: -0.1) } label: {
                Image(systemName: "minus.circle").frame(width: 44, height: 44)
            }
            Text(time(position)).monospacedDigit()
            Button { adjust(edge, by: 0.1) } label: {
                Image(systemName: "plus.circle").frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(time(position))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(edge, by: 0.1)
            case .decrement: adjust(edge, by: -0.1)
            @unknown default: break
            }
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        Duration.TimeFormatStyle(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 1), locale: locale)
            .format(.seconds(seconds))
    }

    private func adjust(_ edge: AudioTrimRange.Edge, by step: TimeInterval) {
        stopPreview(reset: true)
        edits?.nudge(edge, by: step)
    }

    private func loadAudio() async {
        let url = LibraryStore.musicURL.appendingPathComponent(song.fileName)
        let asset = AudioTrimFile.asset(at: url)
        do {
            let duration = try await AudioTrimFile.duration(of: asset)
            try Task.checkCancellation()
            self.asset = asset
            edits = AudioTrimEdits(duration: duration)
        } catch {
            if !Task.isCancelled { loadFailed = true }
            return
        }
        let worker = Task.detached(priority: .utility) { try AudioTrimFile.waveform(at: url) }
        let peaks = await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: {
            worker.cancel()
        }
        if !Task.isCancelled, let peaks { waveform = peaks }
    }

    private func startPreview(restart: Bool = false) {
        guard let asset, let edit = edits?.edit, edit.canPreview, scenePhase == .active else { return }
        guard player.sleepDeadline.map({ $0 > Date() }) ?? true else { return }
        if player.isPlaying, let current = player.current {
            suspendedPlayback = (current.id, player.sleepDeadline)
            player.stop()
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            previewDidFail()
            return
        }

        let needsSeek = restart || previewTask != nil || preview.currentItem == nil
        previewTask?.cancel()
        previewRunning = true
        previewTask = Task {
            do {
                if preview.currentItem == nil {
                    let item = try await AudioTrimFile.previewItem(for: asset, edit: edit)
                    try Task.checkCancellation()
                    preview.replaceCurrentItem(with: item)
                }
                if needsSeek {
                    preview.pause()
                    let time = AudioTrimRange.time(edit.previewStart(restart: restart))
                    let seeked = await preview.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                    try Task.checkCancellation()
                    guard seeked else { previewDidFail(); return }
                }
                try Task.checkCancellation()
                previewTask = nil
                preview.play()
            } catch {
                if !Task.isCancelled { previewDidFail() }
            }
        }
    }

    private func stopPreview(reset: Bool = false) {
        let needsReset = reset || previewTask != nil
        previewTask?.cancel()
        previewTask = nil
        preview.pause()
        preview.currentItem?.cancelPendingSeeks()
        previewRunning = false
        if needsReset { preview.replaceCurrentItem(with: nil) }
    }

    private func cancelPreview() {
        stopPreview(reset: true)
        suspendedPlayback = nil
    }

    private func finishPreview() {
        stopPreview(reset: true)
        guard let suspendedPlayback else { return }
        self.suspendedPlayback = nil
        guard scenePhase == .active, suspendedPlayback.songID == player.current?.id, !player.isPlaying,
              suspendedPlayback.sleepDeadline.map({ $0 > Date() }) ?? true else { return }
        player.toggle()
    }

    private func previewDidFail() {
        finishPreview()
        errorMessage = "Die Vorschau konnte nicht abgespielt werden."
    }

    private func save(_ edit: AudioTrimEdit, as mode: SaveMode) {
        guard let asset, edit.canPreview, !isSaving else { return }
        stopPreview(reset: true)
        isSaving = true
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let artwork = song.artworkData
        Task {
            defer {
                try? FileManager.default.removeItem(at: temporary)
                isSaving = false
            }
            do {
                try await AudioTrimFile.export(asset, edit: edit, to: temporary, artwork: artwork)
                switch mode {
                case .newClip:
                    try await saveNewClip(temporary, edit: edit)
                case .original:
                    await CatalogUpdates.finishPendingWrite()
                    let original = asset.url.lastPathComponent
                    if song.fileName == original { try await SongGenreStore.loadOriginal(song, context: context) }
                    let duration = try AVAudioPlayer(contentsOf: temporary).duration
                    try AudioTrimStore.replace(song, original: original, with: temporary, duration: duration, in: context)
                    player.reloadTrimmedSong(song, editedTime: edit.editedTime(forSourceTime:))
                }
                savedMode = mode
            } catch {
                errorMessage = "Der Ausschnitt konnte nicht gespeichert werden."
            }
        }
    }

    private func saveNewClip(_ url: URL, edit: AudioTrimEdit) async throws {
        let name = exportNames[edit] ?? UUID().uuidString + ".m4a"
        exportNames[edit] = name
        let title = L10n.format(edit.operation == .remove ? "%@ (Bearbeitet)" : "%@ (Ausschnitt)", song.title)
        var metadata = ["title": title, "artist": song.artist,
                        "album": song.album, "genre": song.importedGenre]
        if let number = song.trackNumber { metadata["track"] = String(number) }
        try await Importer.stageAndImport(url, context: context, fileName: name, metadata: metadata)
    }
}

private struct AudioTrimTimeline: View {
    let edit: AudioTrimEdit
    let waveform: [Float]
    let playhead: TimeInterval?
    let onDrag: (AudioTrimRange.Edge, TimeInterval) -> Void
    let onFinish: () -> Void

    @State private var dragStart: (edge: AudioTrimRange.Edge, time: TimeInterval)?

    var body: some View {
        GeometryReader { geometry in
            let selection = edit.selection
            let length = edit.sourceDuration
            let removesSelection = edit.operation == .remove
            let marker = removesSelection ? Color.orange : AppTheme.accent
            let inset: CGFloat = 22
            let width = max(1, geometry.size.width - 2 * inset)
            let height = geometry.size.height
            let low = width * selection.start / length
            let high = width * selection.end / length
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppTheme.surface)
                    .frame(width: width, height: height)
                    .offset(x: inset)
                Canvas { context, size in
                    let values = waveform.isEmpty ? [Float](repeating: 0, count: 80) : waveform
                    let spacing = size.width / CGFloat(values.count)
                    let barWidth = max(1, spacing * 0.54)
                    for (index, peak) in values.enumerated() {
                        let x = spacing * (CGFloat(index) + 0.5)
                        let amplitude = max(3, CGFloat(peak) * (size.height - 18))
                        let rect = CGRect(x: x - barWidth / 2, y: (size.height - amplitude) / 2, width: barWidth, height: amplitude)
                        let isSelected = x >= low && x <= high
                        let color = isSelected != removesSelection ? AppTheme.accent : AppTheme.secondaryText.opacity(0.35)
                        context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                    }
                }
                .frame(width: width, height: height)
                .offset(x: inset)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(marker, lineWidth: 2)
                    .background(removesSelection ? marker.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .frame(width: high - low, height: height)
                    .offset(x: inset + low)
                if let playhead, playhead.isFinite {
                    Rectangle().fill(AppTheme.text)
                        .frame(width: 2, height: height - 4)
                        .offset(x: inset + width * min(max(playhead, 0), length) / length, y: 2)
                }
                handle(marker).offset(x: inset + low - 13)
                handle(marker).offset(x: inset + high)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if dragStart == nil {
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        let left = abs(value.startLocation.x - (inset + low - 7))
                        let right = abs(value.startLocation.x - (inset + high + 7))
                        guard min(left, right) <= 24 else { return }
                        let edge: AudioTrimRange.Edge = left <= right ? .start : .end
                        dragStart = (edge, selection.value(for: edge))
                    }
                    if let dragStart {
                        onDrag(dragStart.edge, dragStart.time + value.translation.width * length / width)
                    }
                }
                .onEnded { _ in
                    dragStart = nil
                    onFinish()
                }
            )
        }
        .frame(height: 76)
        .accessibilityHidden(true)
    }

    private func handle(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(color)
            .frame(width: 13)
            .overlay {
                Capsule().fill(AppTheme.onAccent).frame(width: 2, height: 18)
            }
    }
}
#endif
