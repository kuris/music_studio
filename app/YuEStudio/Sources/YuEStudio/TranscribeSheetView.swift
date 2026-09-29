import SwiftUI
import AppKit

struct PickedAudio: Identifiable { let id = UUID(); let url: URL; var hum = false }

/// Pick a recording → (install SheetSage2 on first use) → transcribe → review melody and lyrics.
/// "Use melody" fills the form's ABC field and forces Planning to "melody" for a cover; any
/// recognised lyrics go into the lyrics field at the same time, and the timed lines can be
/// saved as an .srt.
struct TranscribeSheetView: View {
    let source: URL
    var hum = false                     // a hummed melody: vocal task, and the score may be left open
    @Binding var abc: String
    @Binding var abcOpen: Bool
    @Binding var cot: String
    @Binding var lyrics: String
    @ObservedObject var sheetsage: SheetSageInstaller
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss
    @AppStorage("transcribeTask") private var storedTask = "melody-full"
    @AppStorage("transcribeLyrics") private var wantLyrics = true
    @AppStorage("transcribeLyricsLanguage") private var lyricsLanguage = "ko"
    @State private var openScore = true
    @State private var editedABC = ""
    @State private var editedLyrics = ""
    @State private var reviewing = ReviewTab.melody
    private enum ReviewTab { case melody, lyrics }
    private var task: String { hum ? "melody-vocal" : storedTask }
    /// A hum has no words to recognise, so the lyrics pass is only offered for real recordings.
    private var lyricsEnabled: Bool { wantLyrics && !hum }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hum ? "Your hum as a melody score" : "Transcribe \"\(source.lastPathComponent)\"").font(.headline)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            bottomBar
        }
        .padding().frame(width: 640, height: 520)
        .onAppear {
            sheetsage.check()
            if sheetsage.state == .ready && backend.connected { start() }
        }
        .onChange(of: sheetsage.state) { _, s in
            if s == .ready && backend.transcribe == .idle && backend.connected { start() }
        }
        .onChange(of: backend.transcribe) { _, t in
            if t == .review {
                editedABC = backend.transcribeABC
                editedLyrics = backend.transcribeLyrics
                reviewing = .melody
            }
        }
    }

    private func start() {
        backend.startTranscription(audio: source, task: task,
                                   lyrics: lyricsEnabled, lyricsLanguage: lyricsLanguage)
    }

    private var needsInstall: Bool {
        if sheetsage.state != .ready { return true }
        if case .failed(_, let code) = backend.transcribe, code == "no_env" { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        if needsInstall {
            installPhase
        } else {
            switch backend.transcribe {
            case .idle, .transcribing: progressPhase
            case .review: reviewPhase
            case .failed(let message, let code): failedPhase(message, code)
            }
        }
    }

    @ViewBuilder private var installPhase: some View {
        if !Paths.packaged {
            Text("SheetSage2 is not set up. In development mode, create its environment by hand:").font(.callout)
            Text("""
                 python3.11 -m venv .venv-sheetsage2
                 .venv-sheetsage2/bin/pip install torch==2.8.0 torchaudio==2.8.0
                 .venv-sheetsage2/bin/pip install -r <SheetSage2 snapshot>/requirements.txt soundfile
                 """).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("See docs/covers.md for details, then reopen this sheet.").font(.caption).foregroundStyle(.secondary)
        } else if sheetsage.state == .running {
            ForEach(sheetsage.steps) { s in
                HStack {
                    Image(systemName: s.done ? "checkmark.circle.fill" : (s.id == sheetsage.current ? "arrow.triangle.2.circlepath" : "circle"))
                        .foregroundStyle(s.done ? .green : .secondary)
                    Text(s.title)
                }.font(.callout)
            }
            ProgressView(value: sheetsage.progress)
            Text(sheetsage.detail).font(.caption).foregroundStyle(.secondary)
            if let last = sheetsage.log.last { Text("\(last.time)  \(last.message)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
        } else {
            Text("Transcription uses SheetSage2, installed on first use: a small model (about 2 GB with its audio encoder) and its own Python environment.").font(.callout)
            Text("SheetSage2 weights are CC BY-NC 4.0 (non-commercial).").font(.caption).foregroundStyle(.secondary)
            if case .failed(let message) = sheetsage.state {
                Text(message).foregroundStyle(.red).font(.caption)
            }
            Button("Install transcription support") { sheetsage.install() }.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var progressPhase: some View {
        Picker("Melody", selection: $storedTask) { Text("Full melody").tag("melody-full"); Text("Vocal only").tag("melody-vocal") }
            .pickerStyle(.segmented).disabled(backend.transcribe == .transcribing)
        if !hum {
            HStack {
                Toggle("가사 자동 인식", isOn: $wantLyrics)
                Picker("", selection: $lyricsLanguage) {
                    Text("언어 자동").tag("auto"); Text("한국어").tag("ko")
                    Text("영어").tag("en"); Text("일본어").tag("ja")
                }.labelsHidden().frame(width: 120).disabled(!wantLyrics)
                Spacer()
            }.disabled(backend.transcribe == .transcribing).font(.callout)
        }
        if backend.transcribe == .transcribing {
            if let f = backend.transcribeFraction { ProgressView(value: f) } else { ProgressView() }
            Text(backend.transcribeDetail).font(.caption).foregroundStyle(.secondary)
            if backend.busy { Text("Songs are generating — transcription shares the machine and both will be slower.").font(.caption).foregroundStyle(.orange) }
        } else if !backend.connected {
            Text("Worker not connected").foregroundStyle(.red).font(.caption)
        } else {
            Button("Transcribe") { start() }.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var reviewPhase: some View {
        if !backend.transcribeLyrics.isEmpty {
            Picker("", selection: $reviewing) {
                Text("멜로디").tag(ReviewTab.melody); Text("가사").tag(ReviewTab.lyrics)
            }.pickerStyle(.segmented).labelsHidden()
        }
        if reviewing == .lyrics {
            Text("인식된 가사 — 틀린 부분을 고친 뒤 사용하세요. 구간 태그는 전사된 곡 구조에서 붙였습니다.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $editedLyrics).font(.callout).frame(maxHeight: .infinity)
        } else {
            Text("Review the melody — edit any wrong notes before using it.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $editedABC).font(.system(.caption, design: .monospaced)).frame(maxHeight: .infinity)
        }
        if !backend.transcribeWarnings.isEmpty {
            Text(backend.transcribeWarnings.joined(separator: " · ")).font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }

    /// Copy the worker's lyrics.srt out to wherever the user wants it.
    private func saveSRT() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".srt"
        panel.allowedContentTypes = []
        panel.message = "인식된 가사를 자막(SRT) 파일로 저장합니다"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: backend.transcribeSRT), to: target)
        } catch {
            NSSound.beep()
        }
    }

    @ViewBuilder private func failedPhase(_ message: String, _ code: String) -> some View {
        Text(message).foregroundStyle(.red).font(.callout)
        if code == "afconvert" {
            Text("The file could not be decoded (protected or unsupported) — export it as WAV or M4A first.").font(.caption).foregroundStyle(.secondary)
        }
        Button("Retry") { start() }.disabled(!backend.connected)
    }

    private var bottomBar: some View {
        HStack {
            if backend.transcribe == .review {
                Button("Reveal artifacts") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backend.transcribeOutput)]) }
                if !backend.transcribeSRT.isEmpty {
                    Button("SRT 저장") { saveSRT() }
                }
            }
            if hum && backend.transcribe == .review {
                Picker("", selection: $openScore) {
                    Text("Continue from my hum").tag(true)
                    Text("Song is exactly my hum").tag(false)
                }.pickerStyle(.segmented).frame(width: 340).labelsHidden()
            }
            Spacer()
            Button(backend.transcribe == .review ? "Discard" : "Cancel") {
                if backend.transcribe == .transcribing { backend.cancelTranscription() }
                backend.transcribe = .idle
                dismiss()
            }.keyboardShortcut(.cancelAction)
            if backend.transcribe == .review {
                Button(editedLyrics.isEmpty ? "Use melody" : "멜로디 + 가사 사용") {
                    abc = editedABC
                    abcOpen = hum && openScore
                    cot = "melody"                 // external ABC requires melody/full planning
                    if !editedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lyrics = editedLyrics
                    }
                    backend.transcribe = .idle
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(editedABC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
