import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Dark Theme Design System
extension Color {
    static let darkBackground = Color(red: 0.06, green: 0.08, blue: 0.11) // #10141d
    static let darkPanel = Color(red: 0.09, green: 0.11, blue: 0.15) // #161b26
    static let darkPanelHover = Color(red: 0.12, green: 0.14, blue: 0.21) // #1e2535
    static let darkBorder = Color(red: 0.17, green: 0.20, blue: 0.29) // #2a3449
    static let darkAccentPrimary = Color(red: 0.49, green: 0.23, blue: 0.93) // #7c3aed
    static let darkAccentSecondary = Color(red: 0.93, green: 0.28, blue: 0.60) // #ec4899
    static let darkTextPrimary = Color(red: 0.89, green: 0.91, blue: 0.94) // #e2e8f0
    static let darkTextSecondary = Color(red: 0.58, green: 0.64, blue: 0.75) // #94a3b8
}

struct ContentView: View {
    @EnvironmentObject var backend: Backend
    @StateObject private var players = Players()
    @AppStorage("style") private var style = "Korean, soft city pop, warm female voice, analog synth, gentle piano, 95 BPM"
    @AppStorage("lyrics") private var lyrics = "[Verse]\n밤하늘 아래 걸어요\n별빛이 비추는 길에서\n너의 미소가 보여요\n모든 게 아름답게 변해요\n\n[Chorus]\n새벽 두 시의 우리\n두려움 없이 걸어요\n도시의 별 아래에서\n우리의 이야기가 시작돼요"
    @AppStorage("cot") private var cot = "full"
    @AppStorage("seed") private var seed = 831001
    @AppStorage("randomSeed") private var randomSeed = false
    @AppStorage("batch") private var batch = 2
    @AppStorage("maxSeconds") private var maxSeconds = 120.0
    @AppStorage("qualityMode") private var qualityMode = "draft-gpu"
    @AppStorage("useRemote") private var useRemote = true
    @StateObject private var remote = RemoteBrowser()
    private var quality: String { qualityMode.hasPrefix("draft") ? "draft" : "full" }
    private var engines: String { qualityMode.hasSuffix("-ane") ? "gpu+ane" : "gpu" }
    @AppStorage("instrumental") private var instrumental = false
    @AppStorage("abc") private var abc = ""
    @AppStorage("abcOpen") private var abcOpen = false
    @State private var humming = false
    @State private var showScore: Song?
    @StateObject private var sheetsage = SheetSageInstaller()
    @State private var transcribeSource: PickedAudio?
    @AppStorage("logPanelHeight") private var logPanelHeight = 130.0
    @State private var logDragStart: Double? = nil
    @AppStorage("title") private var title = ""
    @AppStorage("titleAuto") private var titleAuto = ""
    @State private var naming = false
    @State private var writingLyrics = false
    @State private var lyricsAlert: String?
    @State private var askAbout = false
    @State private var lyricsVersion = 0
    @AppStorage("lyricsAbout") private var lyricsAbout = ""
    @AppStorage("styleHeight") private var styleHeight = 72.0
    @State private var styleDragStart: Double? = nil
    @State private var showGeminiSettings = false
    @AppStorage("autoSaveMP3") private var autoSaveMP3 = true
    @AppStorage("deleteOriginalWAV") private var deleteOriginalWAV = false

    // Style tags for quick selection
    let styleTags = [
        "시티팝", "트로트", "발라드", "K-pop 댄스", "R&B", "어쿠스틱 포크", "신스웨이브", "록 밴드", "재즈 보사노바", "동요"
    ]

    var body: some View {
        HSplitView {
            mainWorkspace.frame(minWidth: 420, idealWidth: 520)
            VStack(spacing: 0) {
                results.frame(minHeight: 180)
                TransportBar(players: players)
                logSplitter
                logView.frame(height: max(64, min(logPanelHeight, 600)))
            }.frame(minWidth: 500)
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(Color.darkBackground)
        .onAppear {
            backend.rescan(); if backend.process == nil { backend.start() }; remote.start()
            backend.remoteRetry = { if useRemote, let phone = remote.phone { backend.useRemote(phone) } }
        }
        .onChange(of: remote.phone) { _, phone in backend.useRemote(useRemote ? phone : nil) }
        .onChange(of: useRemote) { _, on in backend.useRemote(on ? remote.phone : nil) }
        .onChange(of: backend.connected) { _, up in if up { backend.useRemote(useRemote ? remote.phone : nil) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in backend.rescan() }
        .sheet(item: $transcribeSource) { picked in
            TranscribeSheetView(source: picked.url, hum: picked.hum, abc: $abc, abcOpen: $abcOpen, cot: $cot, sheetsage: sheetsage).environmentObject(backend)
        }
        .sheet(isPresented: $humming) {
            HumSheetView { url in
                backend.transcribe = .idle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { transcribeSource = PickedAudio(url: url, hum: true) }
            }
        }
        .sheet(isPresented: $showGeminiSettings) {
            GeminiSettingsView().environmentObject(backend)
        }
    }

    // MARK: - Main Workspace (Left Panel)
    private var mainWorkspace: some View {
        VStack(spacing: 16) {
            // Top Bar
            topBar

            // Lyrics Section
            lyricsSection

            // Style Tags
            styleTagsSection

            // Style Prompt
            stylePromptSection

            // Generate Button
            generateButton

            // Pipeline Status
            pipelineStatus
        }
        .padding(16)
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .foregroundStyle(Color.darkAccentPrimary)
                Text("YuE Studio")
                    .font(.headline)
                    .foregroundStyle(Color.darkTextPrimary)
                Text("v2.0")
                    .font(.caption)
                    .foregroundStyle(Color.darkTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.darkPanel, in: Capsule())
            }
            Spacer()
            // Gemini Key Status
            HStack(spacing: 6) {
                if !TitleSuggester.geminiApiKey.isEmpty {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.green)
                    Text("Gemini 3.5 Flash").font(.caption).foregroundStyle(Color.darkTextSecondary)
                } else {
                    Image(systemName: "key")
                        .foregroundStyle(Color.darkTextSecondary)
                    Text("Gemini 설정").font(.caption).foregroundStyle(Color.darkTextSecondary)
                }
                Button(action: { showGeminiSettings = true }) {
                    Image(systemName: "gear")
                        .foregroundStyle(Color.darkTextSecondary)
                }
                .buttonStyle(.plain)
                .help("Gemini API 키 설정")
            }
            // Hardware Info
            if !backend.hardwareInfo.isEmpty {
                Text(backend.hardwareInfo)
                    .font(.caption)
                    .foregroundStyle(Color.darkTextSecondary)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Lyrics Section
    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("가사")
                    .font(.subheadline)
                    .foregroundStyle(Color.darkTextPrimary)
                Spacer()
                HStack(spacing: 8) {
                    Toggle("가사 없이 (연주곡)", isOn: $instrumental)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    TextField("곡 제목", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Button("태그 안내") { showTagGuide = true }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            }
            TextEditor(text: $lyrics)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .disabled(writingLyrics)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.darkBorder, lineWidth: 1)
                )
                .overlay {
                    if writingLyrics {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("AI 가사 작성 중...").font(.caption).foregroundStyle(Color.darkTextSecondary)
                        }
                        .padding(16)
                        .background(Color.darkPanel.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            Text("[Verse] [Pre-Chorus] [Chorus] [Bridge] 로 구간을 나누면 곡 구조가 좋아집니다.")
                .font(.caption)
                .foregroundStyle(Color.darkTextSecondary)
        }
        .padding(12)
        .background(Color.darkPanel, in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showTagGuide) {
            TagGuideView()
        }
    }

    @State private var showTagGuide = false

    // MARK: - Style Tags
    private var styleTagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("스타일")
                .font(.subheadline)
                .foregroundStyle(Color.darkTextPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(styleTags, id: \.self) { tag in
                        Button(action: { applyStyleTag(tag) }) {
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.darkBorder, in: Capsule())
                                .foregroundStyle(Color.darkTextPrimary)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            // Visual feedback handled by button style
                        }
                    }
                }
            }
        }
    }

    private func applyStyleTag(_ tag: String) {
        let tagPrompts: [String: String] = [
            "시티팝": "Korean city pop, warm analog synth, smooth bass, 95 BPM",
            "트로트": "Korean trot, accordion, brass, upbeat rhythm, 120 BPM",
            "발라드": "Korean ballad, piano, strings, emotional, 70 BPM",
            "K-pop 스": "K-pop dance, electronic, energetic, 128 BPM",
            "R&B": "R&B, soulful vocals, smooth production, 90 BPM",
            "어쿠스틱 포크": "Acoustic folk, guitar, warm, 85 BPM",
            "신스웨이브": "Synthwave, retro 80s, neon, 110 BPM",
            "록 밴드": "Rock band, electric guitar, drums, 130 BPM",
            "재즈 보사노바": "Jazz bossa nova, piano, light percussion, 100 BPM",
            "동요": "Children's song, simple melody, playful, 110 BPM"
        ]

        if let prompt = tagPrompts[tag] {
            if style.isEmpty || style.contains("Korean") {
                style = prompt
            } else {
                style = style + ", " + prompt
            }
        }
    }

    // MARK: - Style Prompt
    private var stylePromptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("스타일 프롬프트")
                    .font(.subheadline)
                    .foregroundStyle(Color.darkTextPrimary)
                Spacer()
                HStack {
                    TextField("시드", value: $seed, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(randomSeed)
                    Toggle("랜덤", isOn: $randomSeed)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            TextEditor(text: $style)
                .font(.system(.body, design: .monospaced))
                .frame(height: max(60, min(styleHeight, 300)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.darkBorder, lineWidth: 1)
                )
            Text("장르, 악기, 보컬 , 분위기, BPM을 영어로 적으면 가장 잘 나옵니다.")
                .font(.caption)
                .foregroundStyle(Color.darkTextSecondary)
        }
        .padding(12)
        .background(Color.darkPanel, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Generate Button
    private var generateButton: some View {
        Button(action: { Task { await generateTapped() } }) {
            HStack {
                if naming {
                    ProgressView()
                    Text("제목 선택 중...")
                } else if backend.busy {
                    Image(systemName: "plus")
                    Text("대기열에 추가")
                } else {
                    Image(systemName: "play.fill")
                    Text("곡 만들기")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [Color.darkAccentPrimary, Color.darkAccentSecondary],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(.white)
            .font(.headline)
        }
        .disabled(!backend.connected || naming)
        .keyboardShortcut(.return, modifiers: .command)
    }

    // MARK: - Results (Right Sidebar)
    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Library Header
            HStack {
                Text("내 곡")
                    .font(.headline)
                    .foregroundStyle(Color.darkTextPrimary)
                Spacer()
                Button("폴더") { NSWorkspace.shared.open(Paths.output) }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }

            // Options
            VStack(alignment: .leading, spacing: 4) {
                Toggle("완성되면 MP3로 자동 저장", isOn: $autoSaveMP3)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Toggle("원본(WAV) 지워 용량 아끼기", isOn: $deleteOriginalWAV)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            // Songs List
            Text("이미 만든 곡 정리")
                .font(.caption)
                .foregroundStyle(Color.darkTextSecondary)

            if backend.songs.isEmpty {
                Text("생성된 곡이 없습니다")
                    .font(.caption)
                    .foregroundStyle(Color.darkTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                List {
                    ForEach(backend.songs.filter { !$0.inFlight }) { song in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button(action: { players.toggle(song) }) {
                                    Image(systemName: players.playing == song.id ? "pause.circle.fill" : "play.circle.fill")
                                        .foregroundStyle(players.current?.id == song.id ? Color.darkAccentPrimary : Color.darkTextPrimary)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading) {
                                    Text(song.rowName)
                                        .font(.caption)
                                        .bold()
                                        .foregroundStyle(Color.darkTextPrimary)
                                    Text("\(String(format: "%.1f", song.seconds)) s · seed \(song.seed)")
                                        .font(.caption2)
                                        .foregroundStyle(Color.darkTextSecondary)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.darkPanel, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.darkPanel)
    }

    // MARK: - Pipeline Status
    private var pipelineStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            stageLine("Planning · GPU", backend.songs.filter { $0.status == .planning })
            stageLine("Tokenizing · GPU", backend.songs.filter { $0.status == .tokens })
            stageLine("Synthing · " + (backend.songs.first { $0.status == .synth }?.engineLabel ?? "Neural Engine"), backend.songs.filter { $0.status == .synth })
            stageLine("Rendering · GPU", backend.songs.filter { $0.status == .decode })
            HStack {
                Text("대기열").bold()
                Spacer()
                let queued = backend.songs.filter { $0.status == .queued }.count
                Text(queued == 0 ? "—" : "\(queued) 곡").foregroundStyle(Color.darkTextSecondary)
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color.darkPanel, in: RoundedRectangle(cornerRadius: 8))
    }

    private func stageLine(_ title: String, _ songs: [Song]) -> some View {
        HStack {
            Text(title).bold().font(.caption)
            Spacer()
            if let first = songs.first {
                Text("\(first.runLabel)" + (first.detail.isEmpty ? "" : " · \(first.detail)"))
                    .font(.caption)
                    .foregroundStyle(Color.darkTextSecondary)
                    .lineLimit(1)
            } else {
                Text("대기 중").font(.caption).foregroundStyle(Color.darkTextSecondary)
            }
        }
    }

    // MARK: - Log View
    private var logView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log").font(.caption).bold(); Spacer()
                Button("모두 복사") {
                    let text = backend.log.map { "\($0.time)  \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }.font(.caption)
                Button("지우기") { backend.log.removeAll() }.font(.caption)
            }.padding(.horizontal, 8).padding(.vertical, 4)
            LogTextView(lines: backend.log)
        }
    }

    // MARK: - Helpers
    private func writeLyricsTapped() {
        if backend.busy {
            lyricsAlert = "곡이 생성 중입니다. AI 가사 작성을 기다려주세요."
            return
        }
        askAbout = true
    }

    private func writeLyrics() async {
        writingLyrics = true
        defer { writingLyrics = false }
        let typed = title.trimmingCharacters(in: .whitespaces)
        let userTitle = (typed.isEmpty || typed == titleAuto) ? "" : typed
        if userTitle.isEmpty { title = ""; titleAuto = "" }
        switch await TitleSuggester.writeLyrics(style: style, title: userTitle,
                                                 about: lyricsAbout.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case .success(let text)?: lyrics = text; lyricsVersion += 1
        case .failure(let error)?: lyricsAlert = "AI 가사 작성 실패: \(error.localizedDescription)"
        case nil: lyricsAlert = "AI 가사 작성을 사용할 수 없습니다. Gemini API 키를 설정하세요."
        }
    }

    private func generateTapped() async {
        let typed = title.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty || typed == titleAuto {
            naming = true
            let suggested = await TitleSuggester.suggest(lyrics: lyrics, style: style, instrumental: instrumental)
            naming = false
            title = suggested; titleAuto = suggested
        }
        backend.generate(title: title.trimmingCharacters(in: .whitespaces), style: style, lyrics: lyrics, cot: cot, seed: seed, randomSeed: randomSeed, batch: batch,
                         maxTokens: Int(maxSeconds * 25), engine: "auto", abc: abc, abcOpen: abcOpen, quality: quality, engines: engines, instrumental: instrumental)
    }

    private var qualityCaption: String {
        switch qualityMode {
        case "draft-gpu": return "GPU에서 8단계: 같은 곡의 빠른 미리보기. 행에서full 품질로 렌더링 가능"
        case "draft-gpu-ane": return "8단계; Neural Engine가 컴파일 가능한 곡을 처리, GPU는 나머지"
        case "full-gpu": return "GPU에서 32단계; Memory 최소, 16GB Mac에 적합"
        default: return "32단계; Neural Engine와 GPU가 함께 작동, 긴 곡은 1시간 이상 소요 가능"
        }
    }

    private func pickRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "멜로디로 전사할 녹음을 선택하세요"
        if panel.runModal() == .OK, let url = panel.url {
            backend.transcribe = .idle
            transcribeSource = PickedAudio(url: url)
        }
    }

    private func resizeHandle(height: Binding<Double>, dragStart: Binding<Double?>, range: ClosedRange<Double>) -> some View {
        HStack { Spacer(); Capsule().fill(Color.darkBorder).frame(width: 44, height: 4); Spacer() }
            .frame(height: 10).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let start = dragStart.wrappedValue ?? height.wrappedValue
                    dragStart.wrappedValue = start
                    height.wrappedValue = min(range.upperBound, max(range.lowerBound, start + v.translation.height))
                }
                .onEnded { _ in dragStart.wrappedValue = nil })
    }

    private var logSplitter: some View {
        ZStack { Divider() }
            .frame(height: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let start = logDragStart ?? logPanelHeight
                    logDragStart = start
                    logPanelHeight = min(600, max(64, start - v.translation.height))
                }
                .onEnded { _ in logDragStart = nil })
    }
}
