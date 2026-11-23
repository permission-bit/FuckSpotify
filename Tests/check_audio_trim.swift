// Compiled alongside OfflineMusic/AudioTrim.swift by run_swift_regressions.py.
import AVFoundation
import Foundation

@main
struct AudioTrimTests {
    static func main() async throws {
        var edits = AudioTrimEdits(duration: 3)
        edits.drag(.start, to: 0.4)
        edits.drag(.start, to: 0.7)
        edits.finishDrag()
        edits.undo()
        precondition(edits.selection == edits.original && !edits.canUndo, "A complete drag is one undo step")
        edits.redo()
        edits.drag(.end, to: 0)
        edits.finishDrag()
        precondition(abs(edits.selection.duration - 0.25) < 0.000_001, "The handles must not cross")
        edits.undo()
        edits.nudge(.end, by: -0.1)
        precondition(!edits.canRedo, "A new edit replaces redo history")
        edits.reset()
        edits.undo()
        precondition(edits.selection == AudioTrimRange(start: 0.7, end: 2.9), "Reset remains undoable")
        var shortEdits = AudioTrimEdits(duration: 0.1)
        shortEdits.drag(.start, to: 0.1)
        shortEdits.finishDrag()
        precondition(shortEdits.selection == shortEdits.original && !shortEdits.canUndo)
        edits.reset()
        edits.setOperation(.remove)
        precondition(edits.edit.canPreview && edits.edit.hasJoin && edits.hasChanges)
        let middleSelection = edits.edit
        edits.undo()
        precondition(!edits.hasChanges)
        edits.redo()
        precondition(edits.edit == middleSelection, "Undo and redo must restore the cut operation and its handles")
        edits.drag(.start, to: 0)
        edits.drag(.end, to: 3)
        edits.finishDrag()
        precondition(!edits.edit.canPreview, "Removing all audio must be prevented")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trim-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let output = directory.appendingPathComponent("cut.m4a")
        try writeFixture(to: source)
        let original = try Data(contentsOf: source)
        let asset = AudioTrimFile.asset(at: source)
        let duration = try await AudioTrimFile.duration(of: asset)
        precondition(abs(duration - 3) < 0.001)
        let waveform = try AudioTrimFile.waveform(at: source, bins: 12)
        precondition(waveform.count == 12 && waveform.prefix(4).allSatisfy { $0 == 0 })
        precondition(waveform.suffix(8).allSatisfy { $0 > 0.9 })

        let artwork = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7hcAAAAASUVORK5CYII=")!
        let clip = AudioTrimEdit(sourceDuration: duration, selection: AudioTrimRange(start: 0.7, end: 1.5))
        try await checkPreview(of: asset, edit: clip)
        try await AudioTrimFile.export(asset, edit: clip, to: output, artwork: artwork)
        let exported = AudioTrimFile.asset(at: output)
        let exportedDuration = try await AudioTrimFile.duration(of: exported)
        precondition(abs(exportedDuration - clip.duration) < 0.03, "The saved file must contain only the selection")
        let exportedWaveform = try AudioTrimFile.waveform(at: output, bins: 8)
        precondition(exportedWaveform.prefix(2).allSatisfy { $0 < 0.05 } && exportedWaveform.suffix(3).allSatisfy { $0 > 0.6 },
                     "The exported timeline must start at the selected offset")
        let metadata = try await exported.load(.commonMetadata)
        let cover = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first
        let storedArtwork = try await cover?.load(.dataValue)
        precondition(storedArtwork == artwork, "Artwork must survive reimport of the exported file")

        let remove = AudioTrimEdit(sourceDuration: duration, selection: AudioTrimRange(start: 0.75, end: 2.25), operation: .remove)
        precondition(remove.editedTime(forSourceTime: 0.5) == 0.5)
        precondition(remove.editedTime(forSourceTime: 1.5) == 0.75, "Positions inside the removed audio move to the join")
        precondition(remove.editedTime(forSourceTime: 2.75) == 1.25)
        precondition(remove.sourceTime(forPreviewTime: 0.75) == 2.25, "The playhead should skip the selected audio")
        let lateJoin = AudioTrimEdit(sourceDuration: 80, selection: AudioTrimRange(start: 30, end: 50), operation: .remove)
        precondition(lateJoin.previewStart(restart: false) == 27 && lateJoin.previewStart(restart: true) == 0)
        try await checkPreview(of: asset, edit: remove)
        let joined = directory.appendingPathComponent("joined.m4a")
        try await AudioTrimFile.export(asset, edit: remove, to: joined, artwork: artwork)
        let joinedDuration = try await AudioTrimFile.duration(of: AudioTrimFile.asset(at: joined))
        precondition(abs(joinedDuration - 1.5) < 0.03)
        let joinedWaveform = try AudioTrimFile.waveform(at: joined, bins: 8)
        precondition(joinedWaveform.prefix(3).allSatisfy { $0 < 0.05 } && joinedWaveform.suffix(3).allSatisfy { $0 > 0.75 })
        let tone = try frequency(in: joined, startingAt: 1)
        precondition(abs(tone - 880) < 20, "The audio after the join must come from after the removed range")

        for (name, selection) in [("head", AudioTrimRange(start: 0, end: 1)), ("tail", AudioTrimRange(start: 2, end: 3))] {
            let trimEdge = AudioTrimEdit(sourceDuration: duration, selection: selection, operation: .remove)
            let url = directory.appendingPathComponent(name + ".m4a")
            try await AudioTrimFile.export(asset, edit: trimEdge, to: url)
            let length = try await AudioTrimFile.duration(of: AudioTrimFile.asset(at: url))
            precondition(abs(length - 2) < 0.03, "Removing either edge must export a nonempty clip of the remaining audio")
        }
        let unchanged = try Data(contentsOf: source)
        precondition(unchanged == original, "The source file must stay intact")
        print("PASS: audio trim and removal, undo/redo/reset, bounded preview, exact joins and export, preserved cover and source")
    }

    @MainActor private static func checkPreview(of asset: AVURLAsset, edit: AudioTrimEdit) async throws {
        let item = try await AudioTrimFile.previewItem(for: asset, edit: edit)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let start = edit.previewStart(restart: false)
        let end = edit.operation == .keep ? edit.selection.end : edit.duration
        let seeked = await player.seek(to: AudioTrimRange.time(start), toleranceBefore: .zero, toleranceAfter: .zero)
        precondition(seeked && abs(player.currentTime().seconds - start) < 0.01)
        player.play()
        defer { player.pause() }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let position = player.currentTime().seconds
            precondition(position <= end + 0.05, "The preview must stop at the end marker")
            if position >= end - 0.05, player.rate == 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("The preview did not reach its selected end")
    }

    private static func frequency(in url: URL, startingAt start: TimeInterval) throws -> Double {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(start * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate / 4))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let frames = Int(buffer.frameLength)
        let crossings = (1..<frames).filter { samples[$0 - 1] < 0 && samples[$0] >= 0 }.count
        return Double(crossings) * rate / Double(frames)
    }

    private static func writeFixture(to url: URL) throws {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * 3)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            let tone = frame < Int(sampleRate * 2) ? 440.0 : 880.0
            samples[frame] = frame < Int(sampleRate) ? 0 : Float(0.5 * sin(2 * .pi * tone * Double(frame) / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
