import SwiftUI
import AppKit

struct GeminiSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("geminiApiKey") private var apiKey = ""
    @AppStorage("geminiModel") private var model = "gemini-3.5-flash"
    @State private var testing = false
    @State private var testResult: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gemini API 설정")
                .font(.headline)

            // API Key Input
            VStack(alignment: .leading, spacing: 8) {
                Text("API 키")
                    .font(.subheadline)
                SecureField("Gemini API 키를 입력하세요", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Google AI Studio에서 API 키를 생성할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Model Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("모델")
                    .font(.subheadline)
                Picker("모델 선택", selection: $model) {
                    Text("gemini-3.5-flash").tag("gemini-3.5-flash")
                    Text("gemini-2.5-flash").tag("gemini-2.5-flash")
                    Text("gemini-1.5-flash").tag("gemini-1.5-flash")
                    TextField("사용자 정의 모델", text: $model)
                }
                .pickerStyle(.menu)
                .textFieldStyle(.roundedBorder)
            }

            // Test Button
            Button(action: testConnection) {
                HStack {
                    if testing {
                        ProgressView()
                        Text("연결 테스트 중...")
                    } else {
                        Image(systemName: "checkmark.circle")
                        Text("연결 테스트")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
            }
            .disabled(testing || apiKey.isEmpty)

            // Test Result
            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.contains("성공") == true ? .green : .red)
            }

            Spacer()

            // Info Text
            Text("이 설정은 AI 가사 작성 및 곡 제목 추천에 사용됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Buttons
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") {
                    UserDefaults.standard.set(apiKey, forKey: "geminiApiKey")
                    UserDefaults.standard.set(model, forKey: "geminiModel")
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500, height: 400)
    }

    private func testConnection() {
        testing = true
        testResult = nil

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            testResult = "잘못된 URL입니다."
            testing = false
            return
        }

        let payload: [String: Any] = [
            "contents": [["parts": [["text": "Say hello in one word."]]]],
            "generationConfig": ["maxOutputTokens": 10]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.testing = false
                if let error = error {
                    self.testResult = "오류: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    self.testResult = "성공! Gemini API 연결 확인"
                } else if let http = response as? HTTPURLResponse {
                    self.testResult = "실패: HTTP \(http.statusCode)"
                } else {
                    self.testResult = "오류: 연결 실패"
                }
            }
        }
        task.resume()
    }
}
