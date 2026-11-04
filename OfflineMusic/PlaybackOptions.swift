import Foundation
import SwiftUI

enum PlaybackTiming {
    static func overlap(requested: Double, outgoing: Double, incoming: Double, remaining: Double) -> Double {
        guard [requested, outgoing, incoming, remaining].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return 0 }
        return max(0, min(12, requested, outgoing / 2, incoming / 2, remaining - 0.05))
    }

    static func sleepGain(deadline: Date, now: Date, fadeDuration: Double) -> Float {
        guard fadeDuration > 0 else { return now < deadline ? 1 : 0 }
        return Float(min(1, max(0, deadline.timeIntervalSince(now) / fadeDuration)))
    }
}

struct PlaybackSettingsView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Crossfade", isOn: Binding(get: { player.crossfadeEnabled }, set: player.setCrossfadeEnabled))
                    LabeledContent("Dauer", value: "\(Int(player.crossfadeDuration)) Sekunden")
                    Slider(value: Binding(get: { player.crossfadeDuration }, set: player.setCrossfadeDuration), in: 0...12, step: 1)
                        .disabled(!player.crossfadeEnabled)
                } footer: { Text("Blendet aufeinanderfolgende Titel ineinander. Bei kurzen Titeln wird die Überblendung automatisch verkürzt.") }
                Section {
                    Toggle("Lückenarme Wiedergabe", isOn: Binding(get: { player.gaplessEnabled }, set: player.setGaplessEnabled))
                        .disabled(player.crossfadeEnabled && player.crossfadeDuration > 0)
                } footer: { Text("Bereitet den nächsten Titel vor und startet kompatible Dateien direkt im Anschluss. Verfügbare Encoderinformationen werden vom Audiodecoder berücksichtigt. Bei aktivem Crossfade werden Titel stattdessen überblendet.") }
            }
            .navigationTitle("Wiedergabeeinstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

struct SleepTimerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if player.sleepDeadline != nil || player.sleepAfterCurrentSong {
                    Section("Aktiver Timer") {
                        if let deadline = player.sleepDeadline {
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                let remaining = max(0, Int(ceil(deadline.timeIntervalSince(timeline.date))))
                                LabeledContent("Verbleibend", value: String(format: "%02d:%02d", remaining / 60, remaining % 60))
                            }
                        } else { Text("Stoppt nach dem aktuellen Titel") }
                        Button("Timer abbrechen", role: .destructive) { player.cancelSleepTimer() }
                    }
                }
                Section("Wiedergabe stoppen nach") {
                    ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                        Button("\(minutes) Minuten") { player.startSleepTimer(minutes: minutes); dismiss() }
                    }
                    Button("Ende des aktuellen Titels") { player.sleepAtEndOfCurrentSong(); dismiss() }
                        .disabled(player.current == nil)
                }
                Section {
                    Toggle("Sanft ausblenden", isOn: Binding(get: { player.sleepFadeEnabled }, set: player.setSleepFadeEnabled))
                } footer: { Text("Die Lautstärke wird in den letzten 5 Sekunden reduziert. Der Timer zählt auch während einer Pause weiter.") }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}
