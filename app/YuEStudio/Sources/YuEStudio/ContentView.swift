import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - White Theme Design System
extension Color {
    static let whiteBackground = Color(red: 0.98, green: 0.98, blue: 0.99) // #FAFAFA
    static let whitePanel = Color(red: 1.0, green: 1.0, blue: 1.0) // #FFFFFF
    static let whitePanelHover = Color(red: 0.96, green: 0.96, blue: 0.98) // #F5F5FA
    static let whiteBorder = Color(red: 0.88, green: 0.88, blue: 0.92) // #E0E0EC
    static let whiteAccentPrimary = Color(red: 0.49, green: 0.23, blue: 0.93) // #7c3aed
    static let whiteAccentSecondary = Color(red: 0.93, green: 0.28, blue: 0.60) // #ec4899
    static let whiteTextPrimary = Color(red: 0.15, green: 0.15, blue: 0.20) // #262633
    static let whiteTextSecondary = Color(red: 0.50, green: 0.50, blue: 0.58) // #808094
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
    @State private var generatingLyrics = false  // Gemini 가사 생성 중 상태
    @State private var upgradingStyle = false    // 스타일 업그레이드 중 상태
    @State private var showTranscribeSheet = false  // 음원 전사 시트 표시
    @State private var showStyleConversionSheet = false  // 스타일 변환 시트 표시
    @StateObject private var youtubeConverter = YouTubeConverter()  // YouTube 변환기
    @State private var youtubeURL = ""  // YouTube 링크

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
        .background(Color.whiteBackground)
        .onAppear {
            backend.rescan(); if backend.process == nil { backend.start() }; remote.start()
            backend.remoteRetry = { if useRemote, let phone = remote.phone { backend.useRemote(phone) } }
        }
        .onChange(of: remote.phone) { _, phone in backend.useRemote(useRemote ? phone : nil) }
        .onChange(of: useRemote) { _, on in backend.useRemote(on ? remote.phone : nil) }
        .onChange(of: backend.connected) { _, up in if up { backend.useRemote(useRemote ? remote.phone : nil) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in backend.rescan() }
        .sheet(item: $transcribeSource) { picked in
            TranscribeSheetView(source: picked.url, hum: picked.hum, abc: $abc, abcOpen: $abcOpen, cot: $cot, lyrics: $lyrics, sheetsage: sheetsage).environmentObject(backend)
        }
        .sheet(isPresented: $showTranscribeSheet) {
            // Empty view to trigger the transcribe sheet with audio upload
            Color.clear.onAppear {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio]
                panel.allowsMultipleSelection = false
                panel.message = "멜로디로 전사할 원곡 오디오를 선택하세요 (WAV, MP3, M4A, FLAC)"
                if panel.runModal() == .OK, let url = panel.url {
                    backend.transcribe = .idle
                    transcribeSource = PickedAudio(url: url)
                    showTranscribeSheet = false
                }
            }
        }
        .sheet(isPresented: $showStyleConversionSheet) {
            StyleConversionSheet()
                .environmentObject(backend)
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
                    .foregroundStyle(Color.whiteAccentPrimary)
                Text("YuE Studio")
                    .font(.headline)
                    .foregroundStyle(Color.whiteTextPrimary)
                Text("v2.0")
                    .font(.caption)
                    .foregroundStyle(Color.whiteTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.whitePanel, in: Capsule())
            }
            Spacer()
            // Gemini Key Status
            HStack(spacing: 6) {
                if !TitleSuggester.geminiApiKey.isEmpty {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.green)
                    Text("Gemini 3.5 Flash").font(.caption).foregroundStyle(Color.whiteTextSecondary)
                } else {
                    Image(systemName: "key")
                        .foregroundStyle(Color.whiteTextSecondary)
                    Text("Gemini 설정").font(.caption).foregroundStyle(Color.whiteTextSecondary)
                }
                Button(action: { showGeminiSettings = true }) {
                    Image(systemName: "gear")
                        .foregroundStyle(Color.whiteTextSecondary)
                }
                .buttonStyle(.plain)
                .help("Gemini API 키 설정")
            }
            // Hardware Info
            if !backend.hardwareInfo.isEmpty {
                Text(backend.hardwareInfo)
                    .font(.caption)
                    .foregroundStyle(Color.whiteTextSecondary)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Lyrics Section
    private var lyricsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("가사")
                        .font(.subheadline)
                        .foregroundStyle(Color.whiteTextPrimary)
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
                    .frame(minHeight: 120, maxHeight: 200)
                    .disabled(writingLyrics || generatingLyrics)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.whiteBorder, lineWidth: 1)
                    )
                    .overlay {
                        if writingLyrics || generatingLyrics {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text(writingLyrics ? "AI 가사 작성 중..." : "스타일별 가사 생성 중...")
                                    .font(.caption)
                                    .foregroundStyle(Color.whiteTextSecondary)
                            }
                            .padding(16)
                            .background(Color.whitePanel.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                Text("[Verse] [Pre-Chorus] [Chorus] [Bridge] 로 구간을 나누면 곡 구조가 좋아집니다.")
                    .font(.caption)
                    .foregroundStyle(Color.whiteTextSecondary)

                // Auto Generate Lyrics Button
                Button(action: { Task { await autoGenerateLyrics() } }) {
                    HStack {
                        if generatingLyrics {
                            ProgressView()
                                .controlSize(.small)
                            Text("생성 중...")
                        } else {
                            Image(systemName: "sparkles")
                            Text("가사 자동 생성 (Gemini)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [Color.whiteAccentPrimary, Color.whiteAccentSecondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(.white)
                    .font(.headline)
                }
                .disabled(!TitleSuggester.modelAvailable || writingLyrics || generatingLyrics)
                .help(TitleSuggester.geminiApiKey.isEmpty ? "Gemini API 키를 설정하세요" : "스타일과 제목을 기반으로 AI가 가사를 생성합니다")
            }
            .padding(12)
            .background(Color.whitePanel, in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxHeight: 300)
        .sheet(isPresented: $showTagGuide) {
            TagGuideView()
        }
    }

    @State private var showTagGuide = false

    // MARK: - Style Tags
    private var styleTagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("스타일")
                    .font(.subheadline)
                    .foregroundStyle(Color.whiteTextPrimary)
                Spacer()
                // Style Conversion Button (only show when ABC exists)
                if !abc.isEmpty {
                    Button(action: {
                        showStyleConversionSheet = true
                    }) {
                        HStack {
                            Image(systemName: "arrow.right.circle")
                            Text("스타일 변환")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            LinearGradient(
                                colors: [Color.whiteAccentPrimary, Color.whiteAccentSecondary],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                        .foregroundStyle(.white)
                    }
                    .disabled(backend.busy)
                }
            }

            // Style Tags (chips)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(styleTags, id: \.self) { tag in
                        Button(action: { Task { await applyStyleTag(tag) } }) {
                            HStack(spacing: 6) {
                                Text(tag)
                                    .font(.caption)
                                    .foregroundStyle(Color.whiteTextPrimary)
                                if generatingLyrics || upgradingStyle {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.8)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.whiteBorder, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func applyStyleTag(_ tag: String) async {
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
            // Update style
            if style.isEmpty || style.contains("Korean") {
                style = prompt
            } else {
                style = style + ", " + prompt
            }

            // If no ABC score, generate lyrics with Gemini
            if abc.isEmpty {
                await autoGenerateLyrics()
            }
            // If ABC exists, just update style (cover song mode)
        }
    }

    // MARK: - Style Conversion (Cover Song)
    private func convertToStyle(_ tag: String) async {
        // First apply the style tag (updates style only if ABC exists)
        await applyStyleTag(tag)

        // Then generate the cover song immediately
        await generateTapped()
    }

    // MARK: - Auto Lyrics Generation
    private func autoGenerateLyrics() async {
        generatingLyrics = true
        defer { generatingLyrics = false }

        // Use Gemini to generate lyrics based on current style
        let result = await TitleSuggester.writeLyricsViaGemini(
            apiKey: TitleSuggester.geminiApiKey,
            model: TitleSuggester.geminiModel,
            style: style,
            title: title,
            about: lyricsAbout
        )

        switch result {
        case .success(let lyrics):
            self.lyrics = lyrics
            lyricsVersion += 1
            // Try to extract and apply suggested style (if provided)
            if let styleRange = lyrics.range(of: "\nSTYLE: ", options: .backwards) {
                let suggestedStyle = String(lyrics[lyrics.index(after: styleRange.upperBound)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !suggestedStyle.isEmpty {
                    // Append suggested style to current style
                    if self.style.isEmpty {
                        self.style = suggestedStyle
                    } else {
                        self.style = self.style + ", " + suggestedStyle
                    }
                }
            }
        case .failure(let error):
            lyricsAlert = "AI 가사 생성 실패: \(error.localizedDescription)"
        }
    }

    // MARK: - Style Upgrade
    private func upgradeStyle() async {
        upgradingStyle = true
        defer { upgradingStyle = false }

        // Use Gemini to suggest an improved style based on current lyrics and style
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(TitleSuggester.geminiModel):generateContent?key=\(TitleSuggester.geminiApiKey)"
        guard let url = URL(string: urlString) else {
            lyricsAlert = "Gemini API URL이 올바르지 않습니다."
            return
        }

        let prompt = """
        You are a professional music producer and songwriter.
        Analyze the lyrics' mood, theme, imagery, and emotional tone.
        Then suggest a style description that perfectly matches the lyrics.

        Focus on:
        - Genre that fits the lyrics' mood and theme
        - Instruments that complement the lyrics' imagery
        - Vocal style matching the emotional tone
        - Tempo that matches the lyrics' pacing and rhythm
        - Production quality that enhances the lyrics' atmosphere

        Current Style: \(style.isEmpty ? "generic" : style)
        Lyrics: \(lyrics)

        Return ONLY the improved style as a comma-separated list of descriptors. No explanation.
        """

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.7,
                "maxOutputTokens": 200
            ]
        ]

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let errBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                lyricsAlert = "스타일 업그레이드 실패: \(http.statusCode) - \(errBody)"
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else {
                lyricsAlert = "스타일 업그레이드 실패: 응답 파싱 실패"
                return
            }

            let improvedStyle = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !improvedStyle.isEmpty {
                if self.style.isEmpty {
                    self.style = improvedStyle
                } else {
                    self.style = self.style + ", " + improvedStyle
                }
            }
        } catch {
            lyricsAlert = "스타일 업그레이드 실패: \(error.localizedDescription)"
        }
    }

    // MARK: - Style Prompt
    private var stylePromptSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("스타일 프롬프트")
                        .font(.subheadline)
                        .foregroundStyle(Color.whiteTextPrimary)
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
                    .frame(minHeight: 80, maxHeight: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.whiteBorder, lineWidth: 1)
                    )
                Text("장르, 악기, 보컬 톤, 분위기, BPM을 영어로 적으면 가장 잘 나옵니다.")
                    .font(.caption)
                    .foregroundStyle(Color.whiteTextSecondary)

                // Style Upgrade Button
                Button(action: { Task { await upgradeStyle() } }) {
                    HStack {
                        if upgradingStyle {
                            ProgressView()
                                .controlSize(.small)
                            Text("업그레이드 중...")
                        } else {
                            Image(systemName: "arrow.up.right")
                            Text("스타일 업그레이드 (Gemini)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [Color.whiteAccentPrimary.opacity(0.8), Color.whiteAccentSecondary.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .foregroundStyle(.white)
                    .font(.subheadline)
                }
                .disabled(!TitleSuggester.modelAvailable || upgradingStyle)
                .help(TitleSuggester.geminiApiKey.isEmpty ? "Gemini API 키를 설정하세요" : "현재 스타일과 가사를 기반으로 AI가 더 나은 스타일을 추천합니다")
            }
            .padding(12)
            .background(Color.whitePanel, in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxHeight: 220)
    }

    // MARK: - Generate Button
    private var generateButton: some View {
        VStack(spacing: 12) {
            // YouTube Conversion Section
            if !youtubeURL.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(Color.whiteAccentPrimary)
                        Text(youtubeURL.prefix(60))
                            .font(.caption)
                            .foregroundStyle(Color.whiteTextSecondary)
                        Spacer()
                        Button("변환 중...") {
                            youtubeConverter.cancel()
                        }
                        .font(.caption)
                        .disabled(!youtubeConverter.isConverting)
                    }

                    // Progress Bar
                    if youtubeConverter.isConverting {
                        ProgressView(value: youtubeConverter.progress)
                            .progressViewStyle(.linear)
                            .tint(Color.whiteAccentPrimary)
                        Text(youtubeConverter.statusMessage)
                            .font(.caption2)
                            .foregroundStyle(Color.whiteTextSecondary)
                    }
                }
                .padding(10)
                .background(Color.whitePanelHover, in: RoundedRectangle(cornerRadius: 6))
            }

            // YouTube Input
            HStack {
                TextField("YouTube 링크 (예: https://www.youtube.com/watch?v=...)", text: $youtubeURL)
                    .textFieldStyle(.roundedBorder)
                Button(action: { Task { await convertAndTranscribe() } }) {
                    HStack {
                        if youtubeConverter.isConverting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text("YouTube에서 변환")
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background {
                        if youtubeConverter.isConverting {
                            Color.gray.opacity(0.3)
                        } else {
                            LinearGradient(
                                colors: [Color.whiteAccentPrimary, Color.whiteAccentSecondary],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .disabled(youtubeURL.isEmpty || youtubeConverter.isConverting)
            }

            // Cover Song Section (when ABC exists)
            if !abc.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "music.note")
                            .foregroundStyle(Color.whiteAccentPrimary)
                        Text("음악 커버: \(abc.prefix(50))...")
                            .font(.caption)
                            .foregroundStyle(Color.whiteTextSecondary)
                        Spacer()
                        Button("수정") { showTranscribeSheet = true }
                            .font(.caption)
                    }
                }
                .padding(10)
                .background(Color.whitePanelHover, in: RoundedRectangle(cornerRadius: 6))
            }

            // Generate Button
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
                        Text(abc.isEmpty ? "곡 만들기" : "커버곡 만들기")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [Color.whiteAccentPrimary, Color.whiteAccentSecondary],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .foregroundStyle(.white)
                .font(.headline)
            }
            .disabled(!backend.connected || naming || youtubeConverter.isConverting)
            .keyboardShortcut(.return, modifiers: .command)

            // Manual Audio Upload Button (fallback)
            Button(action: { showTranscribeSheet = true }) {
                HStack {
                    Image(systemName: "upload.circle")
                    Text("음원 직접 업로드")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.whiteBorder, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Color.whiteTextPrimary)
                .font(.subheadline)
            }
            .help("WAV, MP3, M4A, FLAC 파일 직접 업로드")
        }
    }

    // MARK: - YouTube Convert & Transcribe
    private func convertAndTranscribe() async {
        guard !youtubeURL.isEmpty else { return }

        youtubeConverter.statusMessage = "YouTube 링크 분석 중..."
        youtubeConverter.progress = 0.2

        do {
            // Get output directory
            let outputDir = Paths.output.appendingPathComponent("youtube_transcriptions")
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            // Convert YouTube to MP3
            let mp3URL = try await youtubeConverter.convertYouTubeToMP3(
                urlString: youtubeURL,
                outputDir: outputDir
            )

            guard let mp3URL = mp3URL else {
                throw ConversionError.noOutputFile
            }

            // Trigger transcription with the converted MP3
            backend.transcribe = .idle
            transcribeSource = PickedAudio(url: mp3URL)
            showTranscribeSheet = false

            // Clear YouTube URL after successful conversion
            youtubeURL = ""
        } catch {
            lyricsAlert = "YouTube 변환 실패: \(error.localizedDescription)"
            youtubeConverter.isConverting = false
        }
    }

    // MARK: - Results (Right Sidebar)
    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Library Header
            HStack {
                Text("내 곡")
                    .font(.headline)
                    .foregroundStyle(Color.whiteTextPrimary)
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
                .foregroundStyle(Color.whiteTextSecondary)

            if backend.songs.isEmpty {
                Text("생성된 곡이 없습니다")
                    .font(.caption)
                    .foregroundStyle(Color.whiteTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                List {
                    ForEach(backend.songs.filter { !$0.inFlight }) { song in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button(action: { players.toggle(song) }) {
                                    Image(systemName: players.playing == song.id ? "pause.circle.fill" : "play.circle.fill")
                                        .foregroundStyle(players.current?.id == song.id ? Color.whiteAccentPrimary : Color.whiteTextPrimary)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading) {
                                    Text(song.rowName)
                                        .font(.caption)
                                        .bold()
                                        .foregroundStyle(Color.whiteTextPrimary)
                                    Text("\(String(format: "%.1f", song.seconds)) s · seed \(song.seed)")
                                        .font(.caption2)
                                        .foregroundStyle(Color.whiteTextSecondary)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.whitePanel, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.whitePanel)
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
                Text(queued == 0 ? "—" : "\(queued) 곡").foregroundStyle(Color.whiteTextSecondary)
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color.whitePanel, in: RoundedRectangle(cornerRadius: 8))
    }

    private func stageLine(_ title: String, _ songs: [Song]) -> some View {
        HStack {
            Text(title).bold().font(.caption)
            Spacer()
            if let first = songs.first {
                Text("\(first.runLabel)" + (first.detail.isEmpty ? "" : " · \(first.detail)"))
                    .font(.caption)
                    .foregroundStyle(Color.whiteTextSecondary)
                    .lineLimit(1)
            } else {
                Text("대기 중").font(.caption).foregroundStyle(Color.whiteTextSecondary)
            }
        }
    }

    // MARK: - Log View
    private var logView: some View {
        let allLogs = backend.log + youtubeConverter.logs
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log").font(.caption).bold(); Spacer()
                Button("모두 복사") {
                    let text = allLogs.map { "\($0.time)  \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }.font(.caption)
                Button("지우기") {
                    backend.log.removeAll()
                    youtubeConverter.logs.removeAll()
                }.font(.caption)
            }.padding(.horizontal, 8).padding(.vertical, 4)
            LogTextView(lines: allLogs)
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
        HStack { Spacer(); Capsule().fill(Color.whiteBorder).frame(width: 44, height: 4); Spacer() }
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
