import SwiftUI
import AVFoundation

struct AISettingsView: View {
    @State private var apiBaseURL = AIConfig.apiBaseURL
    @State private var apiKey = AIConfig.apiKey
    @State private var chatModel = AIConfig.chatModel
    @State private var embeddingModel = AIConfig.embeddingModel
    @State private var embeddingDimensions = Double(AIConfig.embeddingDimensions)
    @State private var enableBookUnderstanding = AIConfig.enableBookUnderstanding
    @State private var style = AIConfig.stylePreset
    @State private var temperature = AIConfig.temperature
    @State private var maxContextTokens = Double(AIConfig.maxContextTokens)
    @State private var openAITTSBaseURL = NetworkTTSConfig.openAIBaseURL
    @State private var openAITTSAPIKey = NetworkTTSConfig.openAIAPIKey
    @State private var openAITTSModel = NetworkTTSConfig.openAIModel
    @State private var miMoTTSBaseURL = NetworkTTSConfig.miMoBaseURL
    @State private var miMoTTSAPIKey = NetworkTTSConfig.miMoAPIKey
    @State private var miMoTTSModel = NetworkTTSConfig.miMoModel
    @State private var fishTTSBaseURL = NetworkTTSConfig.fishBaseURL
    @State private var fishTTSAPIKey = NetworkTTSConfig.fishAPIKey
    @State private var fishTTSModel = NetworkTTSConfig.fishModel
    @State private var fishReferenceID = NetworkTTSConfig.fishReferenceID
    @State private var showKey = false
    @State private var showTTSKeys = false
    @State private var testMessage: String?
    @State private var isTesting = false
    @State private var fishTestMessage: String?
    @State private var isTestingFishTTS = false
    @State private var fishPreviewPlayer: AVAudioPlayer?

    var body: some View {
        Form {
            Section {
                Text(String(localized: "使用 OpenAI 兼容接口（Chat Completions + Embeddings）。密钥仅存本机。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "API")) {
                TextField(String(localized: "Base URL"), text: $apiBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                HStack {
                    Group {
                        if showKey {
                            TextField(String(localized: "API Key"), text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField(String(localized: "API Key"), text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(String(localized: "显示密钥"))
                }

                TextField(String(localized: "对话模型"), text: $chatModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField(String(localized: "向量模型"), text: $embeddingModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                VStack(alignment: .leading) {
                    Text(String(localized: "Embedding 维度：\(Int(embeddingDimensions))"))
                    Slider(value: $embeddingDimensions, in: 256...3072, step: 256)
                }
            }

            Section(String(localized: "改写")) {
                Picker(String(localized: "默认风格"), selection: $style) {
                    ForEach(RewriteStylePreset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                VStack(alignment: .leading) {
                    Text(String(localized: "Temperature：\(String(format: "%.1f", temperature))"))
                    Slider(value: $temperature, in: 0.0...1.5, step: 0.1)
                }
                VStack(alignment: .leading) {
                    Text(String(localized: "上下文 Token 预算：\(Int(maxContextTokens))"))
                    Slider(value: $maxContextTokens, in: 1000...8000, step: 250)
                }
            }

            Section(String(localized: "OpenAI 兼容语音")) {
                TextField(String(localized: "TTS Base URL"), text: $openAITTSBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                HStack {
                    Group {
                        if showTTSKeys {
                            TextField(String(localized: "TTS API Key"), text: $openAITTSAPIKey)
                        } else {
                            SecureField(String(localized: "TTS API Key"), text: $openAITTSAPIKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        showTTSKeys.toggle()
                    } label: {
                        Image(systemName: showTTSKeys ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(String(localized: "显示语音密钥"))
                }

                TextField(String(localized: "TTS 模型"), text: $openAITTSModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section(String(localized: "小米 MiMo 语音")) {
                TextField(String(localized: "MiMo Base URL"), text: $miMoTTSBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                if showTTSKeys {
                    TextField(String(localized: "MiMo API Key"), text: $miMoTTSAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField(String(localized: "MiMo API Key"), text: $miMoTTSAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                TextField(String(localized: "MiMo TTS 模型"), text: $miMoTTSModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text(String(localized: "MiMo-V2 系列已下线，请使用 mimo-v2.5-tts。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Fish Audio") {
                TextField("Fish Audio Base URL", text: $fishTTSBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                if showTTSKeys {
                    TextField("Fish Audio API Key", text: $fishTTSAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("Fish Audio API Key", text: $fishTTSAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                TextField(String(localized: "模型"), text: $fishTTSModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField(String(localized: "音色模型 ID（可选）"), text: $fishReferenceID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    Task { await testFishAudio() }
                } label: {
                    if isTestingFishTTS {
                        HStack {
                            ProgressView()
                            Text(String(localized: "正在测试语音"))
                        }
                    } else {
                        Label(String(localized: "测试并播放语音"), systemImage: "play.circle")
                    }
                }
                .disabled(
                    isTestingFishTTS
                        || fishTTSAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if let fishTestMessage {
                    Text(fishTestMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "全书理解")) {
                Toggle(String(localized: "AI 理解本书（向量 + 记忆锚点）"), isOn: $enableBookUnderstanding)
                Text(String(localized: "开启后会在后台静默索引与摘要，不阻塞阅读。短篇(<2.5万字)跳过向量索引。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    save()
                } label: {
                    Text(String(localized: "保存设置"))
                        .frame(maxWidth: .infinity)
                }

                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Spacer()
                        if isTesting {
                            ProgressView()
                        } else {
                            Text(String(localized: "测试连接"))
                        }
                        Spacer()
                    }
                }
                .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let testMessage {
                    Text(testMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "说明")) {
                Text(String(localized: "• Chat: POST {base}/chat/completions"))
                Text(String(localized: "• Embeddings: POST {base}/embeddings"))
                Text(String(localized: "• 支持第三方兼容网关（改 Base URL 与模型名即可）"))
                Text(String(localized: "• TTS: POST {base}/audio/speech"))
                Text(String(localized: "• MiMo TTS: POST {base}/chat/completions"))
                Text(String(localized: "• Fish Audio: POST {base}/tts"))
            }
            .font(.caption)
        }
        .navigationTitle(String(localized: "AI 设置"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .onDisappear { save() }
    }

    private func load() {
        apiBaseURL = AIConfig.apiBaseURL
        apiKey = AIConfig.apiKey
        chatModel = AIConfig.chatModel
        embeddingModel = AIConfig.embeddingModel
        embeddingDimensions = Double(AIConfig.embeddingDimensions)
        enableBookUnderstanding = AIConfig.enableBookUnderstanding
        style = AIConfig.stylePreset
        temperature = AIConfig.temperature
        maxContextTokens = Double(AIConfig.maxContextTokens)
        openAITTSBaseURL = NetworkTTSConfig.openAIBaseURL
        openAITTSAPIKey = NetworkTTSConfig.openAIAPIKey
        openAITTSModel = NetworkTTSConfig.openAIModel
        miMoTTSBaseURL = NetworkTTSConfig.miMoBaseURL
        miMoTTSAPIKey = NetworkTTSConfig.miMoAPIKey
        miMoTTSModel = NetworkTTSConfig.miMoModel
        fishTTSBaseURL = NetworkTTSConfig.fishBaseURL
        fishTTSAPIKey = NetworkTTSConfig.fishAPIKey
        fishTTSModel = NetworkTTSConfig.fishModel
        fishReferenceID = NetworkTTSConfig.fishReferenceID
    }

    private func save() {
        AIConfig.apiBaseURL = apiBaseURL
        AIConfig.apiKey = apiKey
        AIConfig.chatModel = chatModel
        AIConfig.embeddingModel = embeddingModel
        AIConfig.embeddingDimensions = Int(embeddingDimensions)
        AIConfig.enableBookUnderstanding = enableBookUnderstanding
        AIConfig.stylePreset = style
        AIConfig.temperature = temperature
        AIConfig.maxContextTokens = Int(maxContextTokens)
        NetworkTTSConfig.openAIBaseURL = openAITTSBaseURL
        NetworkTTSConfig.openAIAPIKey = openAITTSAPIKey
        NetworkTTSConfig.openAIModel = openAITTSModel
        NetworkTTSConfig.miMoBaseURL = miMoTTSBaseURL
        NetworkTTSConfig.miMoAPIKey = miMoTTSAPIKey
        NetworkTTSConfig.miMoModel = miMoTTSModel
        NetworkTTSConfig.fishBaseURL = fishTTSBaseURL
        NetworkTTSConfig.fishAPIKey = fishTTSAPIKey
        NetworkTTSConfig.fishModel = fishTTSModel
        NetworkTTSConfig.fishReferenceID = fishReferenceID
    }

    private func testConnection() async {
        save()
        isTesting = true
        defer { isTesting = false }
        do {
            let reply = try await LLMClient.chat(
                messages: [
                    .init(role: "user", content: "Reply with exactly: OK")
                ],
                temperature: 0,
                timeout: 30
            )
            testMessage = String(localized: "对话成功：\(String(reply.prefix(80)))")
            // Optional embedding smoke test
            _ = try await LLMClient.embed(texts: ["测试向量"], timeout: 30)
            testMessage = String(localized: "对话与向量均正常")
        } catch {
            testMessage = error.localizedDescription
        }
    }

    private func testFishAudio() async {
        save()
        isTestingFishTTS = true
        fishTestMessage = nil
        defer { isTestingFishTTS = false }

        do {
            let audio = try await TTSEngine.previewAudio(
                provider: .fishAudio,
                voice: fishReferenceID
            )
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: audio)
            player.prepareToPlay()
            guard player.play() else {
                throw NSError(
                    domain: "PureReader.FishAudio",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "测试音频无法播放")
                    ]
                )
            }
            fishPreviewPlayer = player
            fishTestMessage = String(localized: "Fish Audio 请求成功，正在播放测试语音")
        } catch {
            fishTestMessage = error.localizedDescription
        }
    }
}
