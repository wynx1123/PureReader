import SwiftUI

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
    @State private var showKey = false
    @State private var showTTSKeys = false
    @State private var testMessage: String?
    @State private var isTesting = false

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
}
