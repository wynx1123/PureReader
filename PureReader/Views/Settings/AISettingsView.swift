import SwiftUI
import AVFoundation

struct AISettingsView: View {
    @State private var rewriteBaseURL = AIConfig.rewriteBaseURL
    @State private var rewriteAPIKey = AIConfig.rewriteAPIKey
    @State private var chatModel = AIConfig.chatModel
    @State private var embeddingBaseURL = AIConfig.embeddingBaseURL
    @State private var embeddingAPIKey = AIConfig.embeddingAPIKey
    @State private var embeddingModel = AIConfig.embeddingModel
    @State private var embeddingDimensions = Double(max(AIConfig.embeddingDimensions, 1536))
    @State private var automaticEmbeddingDimensions = AIConfig.embeddingDimensions == 0
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
    @State private var showRewriteKey = false
    @State private var showEmbeddingKey = false
    @State private var showTTSKeys = false
    @State private var rewriteTestMessage: String?
    @State private var embeddingTestMessage: String?
    @State private var isTestingRewrite = false
    @State private var isTestingEmbedding = false
    @State private var openAITTSTestMessage: String?
    @State private var miMoTTSTestMessage: String?
    @State private var isTestingOpenAITTS = false
    @State private var isTestingMiMoTTS = false
    @State private var ttsPreviewPlayer: AVAudioPlayer?
    @State private var fishTestMessage: String?
    @State private var isTestingFishTTS = false
    @State private var fishPreviewPlayer: AVAudioPlayer?
    @State private var rewriteModels: [String] = []
    @State private var embeddingModels: [String] = []
    @State private var openAITTSModels: [String] = []
    @State private var miMoTTSModels: [String] = []
    @State private var fishTTSModels: [String] = []
    @State private var isLoadingRewriteModels = false
    @State private var isLoadingEmbeddingModels = false
    @State private var isLoadingOpenAITTSModels = false
    @State private var isLoadingMiMoTTSModels = false
    @State private var isLoadingFishTTSModels = false
    @State private var rewriteModelMessage: String?
    @State private var embeddingModelMessage: String?
    @State private var openAITTSModelMessage: String?
    @State private var miMoTTSModelMessage: String?
    @State private var fishTTSModelMessage: String?

    private enum ModelTarget {
        case rewrite
        case embedding
        case openAITTS
        case miMoTTS
        case fishTTS
    }

    var body: some View {
        Form {
            Section {
                Text(String(localized: "AI 改写、向量索引与语音接口可独立配置，密钥仅存本机。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "AI 改写接口")) {
                TextField(String(localized: "Base URL"), text: $rewriteBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                HStack {
                    Group {
                        if showRewriteKey {
                            TextField(String(localized: "API Key"), text: $rewriteAPIKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField(String(localized: "API Key"), text: $rewriteAPIKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    Button {
                        showRewriteKey.toggle()
                    } label: {
                        Image(systemName: showRewriteKey ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(String(localized: "显示密钥"))
                }

                modelSelectionRow(
                    title: String(localized: "对话模型"),
                    selection: $chatModel,
                    options: rewriteModels,
                    isLoading: isLoadingRewriteModels,
                    message: rewriteModelMessage
                ) {
                    Task { await fetchModels(for: .rewrite) }
                }

                Button {
                    Task { await testRewriteConnection() }
                } label: {
                    testButtonLabel(
                        title: String(localized: "测试改写接口"),
                        isTesting: isTestingRewrite
                    )
                }
                .disabled(
                    isTestingRewrite
                        || rewriteAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || chatModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if let rewriteTestMessage {
                    Text(rewriteTestMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "向量接口")) {
                TextField(String(localized: "Base URL"), text: $embeddingBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                HStack {
                    Group {
                        if showEmbeddingKey {
                            TextField(String(localized: "API Key"), text: $embeddingAPIKey)
                        } else {
                            SecureField(String(localized: "API Key"), text: $embeddingAPIKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        showEmbeddingKey.toggle()
                    } label: {
                        Image(systemName: showEmbeddingKey ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(String(localized: "显示向量密钥"))
                }

                modelSelectionRow(
                    title: String(localized: "向量模型"),
                    selection: $embeddingModel,
                    options: embeddingModels,
                    isLoading: isLoadingEmbeddingModels,
                    message: embeddingModelMessage
                ) {
                    Task { await fetchModels(for: .embedding) }
                }

                Toggle(
                    String(localized: "由向量模型决定维度"),
                    isOn: $automaticEmbeddingDimensions
                )
                if !automaticEmbeddingDimensions {
                    VStack(alignment: .leading) {
                        Text(String(localized: "Embedding 维度：\(Int(embeddingDimensions))"))
                        Slider(value: $embeddingDimensions, in: 256...3072, step: 256)
                    }
                }

                Button {
                    Task { await testEmbeddingConnection() }
                } label: {
                    testButtonLabel(
                        title: String(localized: "测试向量接口"),
                        isTesting: isTestingEmbedding
                    )
                }
                .disabled(
                    isTestingEmbedding
                        || embeddingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if let embeddingTestMessage {
                    Text(embeddingTestMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

                modelSelectionRow(
                    title: String(localized: "TTS 模型"),
                    selection: $openAITTSModel,
                    options: openAITTSModels,
                    isLoading: isLoadingOpenAITTSModels,
                    message: openAITTSModelMessage
                ) {
                    Task { await fetchModels(for: .openAITTS) }
                }

                Button {
                    Task { await testTTS(provider: .openAICompatible, voice: "marin") }
                } label: {
                    testButtonLabel(
                        title: String(localized: "测试并播放语音"),
                        isTesting: isTestingOpenAITTS
                    )
                }
                .disabled(
                    isTestingOpenAITTS
                        || openAITTSAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || openAITTSModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if let openAITTSTestMessage {
                    Text(openAITTSTestMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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

                modelSelectionRow(
                    title: String(localized: "MiMo TTS 模型"),
                    selection: $miMoTTSModel,
                    options: miMoTTSModels,
                    isLoading: isLoadingMiMoTTSModels,
                    message: miMoTTSModelMessage
                ) {
                    Task { await fetchModels(for: .miMoTTS) }
                }

                Button {
                    Task { await testTTS(provider: .xiaomiMiMo, voice: "mimo_default") }
                } label: {
                    testButtonLabel(
                        title: String(localized: "测试并播放语音"),
                        isTesting: isTestingMiMoTTS
                    )
                }
                .disabled(
                    isTestingMiMoTTS
                        || miMoTTSAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || miMoTTSModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if let miMoTTSTestMessage {
                    Text(miMoTTSTestMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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

                modelSelectionRow(
                    title: String(localized: "模型"),
                    selection: $fishTTSModel,
                    options: fishTTSModels,
                    isLoading: isLoadingFishTTSModels,
                    message: fishTTSModelMessage
                ) {
                    Task { await fetchModels(for: .fishTTS) }
                }

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
                        || fishTTSModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

            }

            Section(String(localized: "说明")) {
                Text(String(localized: "• 公网地址需使用 HTTPS；本机或局域网地址可用 HTTP"))
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
        .onDisappear {
            save()
            stopPreviewAudio()
        }
    }

    private func load() {
        rewriteBaseURL = AIConfig.rewriteBaseURL
        rewriteAPIKey = AIConfig.rewriteAPIKey
        chatModel = AIConfig.chatModel
        embeddingBaseURL = AIConfig.embeddingBaseURL
        embeddingAPIKey = AIConfig.embeddingAPIKey
        embeddingModel = AIConfig.embeddingModel
        automaticEmbeddingDimensions = AIConfig.embeddingDimensions == 0
        embeddingDimensions = Double(max(AIConfig.embeddingDimensions, 1536))
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
        AIConfig.rewriteBaseURL = rewriteBaseURL
        AIConfig.rewriteAPIKey = rewriteAPIKey
        AIConfig.chatModel = chatModel
        AIConfig.embeddingBaseURL = embeddingBaseURL
        AIConfig.embeddingAPIKey = embeddingAPIKey
        AIConfig.embeddingModel = embeddingModel
        AIConfig.embeddingDimensions = automaticEmbeddingDimensions ? 0 : Int(embeddingDimensions)
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

    private func testRewriteConnection() async {
        save()
        isTestingRewrite = true
        rewriteTestMessage = nil
        defer { isTestingRewrite = false }
        do {
            let reply = try await LLMClient.chat(
                messages: [
                    .init(role: "user", content: "Reply with exactly: OK")
                ],
                temperature: 0,
                timeout: 30
            )
            rewriteTestMessage = String(localized: "改写接口正常：\(String(reply.prefix(80)))")
        } catch {
            rewriteTestMessage = error.localizedDescription
        }
    }

    private func modelSelectionRow(
        title: String,
        selection: Binding<String>,
        options: [String],
        isLoading: Bool,
        message: String?,
        onRefresh: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(title, text: selection)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Menu {
                    ForEach(options, id: \.self) { model in
                        Button(model) {
                            selection.wrappedValue = model
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .frame(width: 36, height: 36)
                }
                .disabled(options.isEmpty)
                .accessibilityLabel(String(localized: "选择已拉取的模型"))

                Button(action: onRefresh) {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 36, height: 36)
                }
                .disabled(isLoading)
                .accessibilityLabel(String(localized: "从服务端拉取模型"))
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fetchModels(for target: ModelTarget) async {
        setModelLoading(true, message: nil, for: target)
        defer { setModelLoading(false, message: nil, for: target, preserveMessage: true) }

        let baseURL: String
        let apiKey: String
        let authorization: LLMClient.ModelAuthorization
        switch target {
        case .rewrite:
            baseURL = rewriteBaseURL
            apiKey = rewriteAPIKey
            authorization = .bearer
        case .embedding:
            baseURL = embeddingBaseURL
            apiKey = embeddingAPIKey
            authorization = .bearer
        case .openAITTS:
            baseURL = openAITTSBaseURL
            apiKey = openAITTSAPIKey
            authorization = .bearer
        case .miMoTTS:
            baseURL = miMoTTSBaseURL
            apiKey = miMoTTSAPIKey
            authorization = .apiKey
        case .fishTTS:
            baseURL = fishTTSBaseURL
            apiKey = fishTTSAPIKey
            authorization = .bearer
        }

        do {
            let models = try await LLMClient.fetchModels(
                baseURL: baseURL,
                apiKey: apiKey,
                authorization: authorization
            )
            setModels(models, for: target)
            setModelMessage(
                String(localized: "已从服务端拉取 \(models.count) 个模型"),
                for: target
            )
        } catch {
            setModels([], for: target)
            setModelMessage(error.localizedDescription, for: target)
        }
    }

    private func setModels(_ models: [String], for target: ModelTarget) {
        switch target {
        case .rewrite: rewriteModels = models
        case .embedding: embeddingModels = models
        case .openAITTS: openAITTSModels = models
        case .miMoTTS: miMoTTSModels = models
        case .fishTTS: fishTTSModels = models
        }
    }

    private func setModelMessage(_ message: String?, for target: ModelTarget) {
        switch target {
        case .rewrite: rewriteModelMessage = message
        case .embedding: embeddingModelMessage = message
        case .openAITTS: openAITTSModelMessage = message
        case .miMoTTS: miMoTTSModelMessage = message
        case .fishTTS: fishTTSModelMessage = message
        }
    }

    private func setModelLoading(
        _ isLoading: Bool,
        message: String?,
        for target: ModelTarget,
        preserveMessage: Bool = false
    ) {
        switch target {
        case .rewrite: isLoadingRewriteModels = isLoading
        case .embedding: isLoadingEmbeddingModels = isLoading
        case .openAITTS: isLoadingOpenAITTSModels = isLoading
        case .miMoTTS: isLoadingMiMoTTSModels = isLoading
        case .fishTTS: isLoadingFishTTSModels = isLoading
        }
        if !preserveMessage {
            setModelMessage(message, for: target)
        }
    }

    private func testEmbeddingConnection() async {
        save()
        isTestingEmbedding = true
        embeddingTestMessage = nil
        defer { isTestingEmbedding = false }
        do {
            _ = try await LLMClient.embed(texts: ["测试向量"], timeout: 30)
            embeddingTestMessage = String(localized: "向量接口正常")
        } catch {
            embeddingTestMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func testButtonLabel(title: String, isTesting: Bool) -> some View {
        if isTesting {
            HStack {
                ProgressView()
                Text(String(localized: "正在测试"))
            }
        } else {
            Label(title, systemImage: "play.circle")
        }
    }

    private func testTTS(provider: TTSProvider, voice: String) async {
        save()
        stopPreviewAudio()
        switch provider {
        case .openAICompatible:
            isTestingOpenAITTS = true
            openAITTSTestMessage = nil
        case .xiaomiMiMo:
            isTestingMiMoTTS = true
            miMoTTSTestMessage = nil
        case .system, .fishAudio:
            return
        }
        defer {
            isTestingOpenAITTS = false
            isTestingMiMoTTS = false
        }

        do {
            let audio = try await TTSEngine.previewAudio(provider: provider, voice: voice)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: audio)
            player.prepareToPlay()
            guard player.play() else {
                throw NSError(
                    domain: "PureReader.TTSPreview",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "测试音频无法播放")]
                )
            }
            ttsPreviewPlayer = player
            let message = String(localized: "请求成功，正在播放测试语音")
            if provider == .openAICompatible {
                openAITTSTestMessage = message
            } else {
                miMoTTSTestMessage = message
            }
        } catch {
            if provider == .openAICompatible {
                openAITTSTestMessage = error.localizedDescription
            } else {
                miMoTTSTestMessage = error.localizedDescription
            }
        }
    }

    private func testFishAudio() async {
        save()
        stopPreviewAudio()
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

    private func stopPreviewAudio() {
        ttsPreviewPlayer?.stop()
        fishPreviewPlayer?.stop()
        ttsPreviewPlayer = nil
        fishPreviewPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}
