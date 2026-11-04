// Native AVAudioPlayer smoke test using silent PCM WAV files and device-clock scheduling.
// Run with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift Tests/check_native_audio.swift
// This checks decoder/scheduling APIs on macOS, not sample-accurate iOS output.
import Foundation
import AVFoundation

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-audio-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
func wave(_ name: String, frames: UInt32) throws -> URL {
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func word(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    func dword(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    text("RIFF"); dword(36 + frames * 2); text("WAVEfmt "); dword(16)
    word(1); word(1); dword(44100); dword(88200); word(2); word(16)
    text("data"); dword(frames * 2); data.append(Data(repeating: 0, count: Int(frames * 2)))
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
}
let firstURL = try wave("first.wav", frames: 22050)
let secondURL = try wave("second.wav", frames: 22050)
let first = try AVAudioPlayer(contentsOf: firstURL)
let second = try AVAudioPlayer(contentsOf: secondURL)
precondition(abs(first.duration - 0.5) < 0.001 && first.format.sampleRate == 44100)
precondition(first.format.channelCount == second.format.channelCount)
guard first.prepareToPlay(), second.prepareToPlay(), first.play() else {
    fatalError("Native audio output is unavailable on this host")
}
defer { first.stop(); second.stop() }
let boundary = first.deviceCurrentTime + first.duration - first.currentTime
precondition(second.play(atTime: boundary), "Native scheduled playback must be accepted")
let until = Date().addingTimeInterval(0.65)
RunLoop.current.run(until: until)
precondition(second.isPlaying && second.currentTime > 0, "The scheduled successor must start without a track-completion callback")
second.setVolume(0, fadeDuration: 0.1)
RunLoop.current.run(until: Date().addingTimeInterval(0.15))
precondition(second.volume < 0.01, "Native fading must reach silence")
print("PASS: native PCM decoding, compatible formats, shared device-clock successor scheduling and native volume fade (macOS)")
