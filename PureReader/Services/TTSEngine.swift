import Foundation
import AVFoundation
import MediaPlayer

struct TTSVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// 系统与网络 TTS 的统一播放引擎。
@MainActor
final class TTSEngine: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var isLoading = false

    /// 当前朗读起点在章节全文中的 UTF-16 offset。
    var spokenOffset: Int = 0
    var onFinishUtterance: (() -> Void)?
    var onBoundary: ((Int) -> Void)?
    var onError: ((String) -> Void)?

    private struct SpeechChunk {
        let text: String
        let relativeOffset: Int
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var networkTask: Task<Void, Never>?
    private var currentUtterance: AVSpeechUtterance?
    private var networkChunks: [SpeechChunk] = []
    private var networkChunkIndex = 0
    private var sessionID = UUID()

    private var provider: TTSProvider = .system
    private var rateMultiplier: Double = 1
    private var voiceIdentifier: String?
    private var bookTitle = ""
    private var chapterTitle = ""

    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
        setupRemoteCommands()
    }

    func configure(rate: Double, provider: TTSProvider, voiceIdentifier: String?) {
        rateMultiplier = min(2, max(0.5, rate))
        self.provider = provider
        self.voiceIdentifier = voiceIdentifier
    }

    func speak(
        text: String,
        bookTitle: String,
        chapterTitle: String,
        startOffset: Int = 0
    ) {
        stop()

        let source = text as NSString
        let safeOffset = min(max(0, startOffset), source.length)
        let remaining = source.substring(from: safeOffset)
        guard !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onFinishUtterance?()
            return
        }

        sessionID = UUID()
        spokenOffset = safeOffset
        self.bookTitle = bookTitle
        self.chapterTitle = chapterTitle
        activateAudioSession()
        isSpeaking = true
        isPaused = false

        switch provider {
        case .system:
            speakWithSystem(remaining)
        case .openAICompatible, .xiaomiMiMo, .fishAudio:
            networkChunks = Self.makeChunks(from: remaining)
            networkChunkIndex = 0
            playCurrentNetworkChunk(session: sessionID)
        }
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        switch provider {
        case .system:
            synthesizer.pauseSpeaking(at: .word)
        case .openAICompatible, .xiaomiMiMo, .fishAudio:
            audioPlayer?.pause()
        }
        isPaused = true
        updateNowPlaying(elapsed: audioPlayer?.currentTime ?? 0, duration: audioPlayer?.duration ?? 1)
    }

    func resume() {
        guard isPaused else { return }
        switch provider {
        case .system:
            synthesizer.continueSpeaking()
        case .openAICompatible, .xiaomiMiMo, .fishAudio:
            audioPlayer?.play()
        }
        isPaused = false
        updateNowPlaying(elapsed: audioPlayer?.currentTime ?? 0, duration: audioPlayer?.duration ?? 1)
    }

    func toggle() {
        if isPaused {
            resume()
        } else if isSpeaking {
            pause()
        }
    }

    func stop() {
        sessionID = UUID()
        networkTask?.cancel()
        networkTask = nil
        networkChunks = []
        networkChunkIndex = 0
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
        isPaused = false
        isLoading = false
        spokenOffset = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateAudioSession()
    }

    static func availableVoices(for provider: TTSProvider) -> [TTSVoiceOption] {
        switch provider {
        case .system:
            return AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.lowercased().hasPrefix("zh") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { TTSVoiceOption(id: $0.identifier, name: $0.name) }
        case .openAICompatible:
            return [
                "marin", "cedar", "alloy", "ash", "ballad", "coral", "echo",
                "fable", "nova", "onyx", "sage", "shimmer", "verse"
            ].map { TTSVoiceOption(id: $0, name: $0.capitalized) }
        case .xiaomiMiMo:
            return [
                .init(id: "mimo_default", name: String(localized: "MiMo 默认")),
                .init(id: "default_zh", name: String(localized: "中文女声")),
                .init(id: "冰糖", name: String(localized: "冰糖（中文女声）")),
                .init(id: "茉莉", name: String(localized: "茉莉（中文女声）")),
                .init(id: "苏打", name: String(localized: "苏打（中文男声）")),
                .init(id: "白桦", name: String(localized: "白桦（中文男声）")),
                .init(id: "default_en", name: String(localized: "英文女声")),
                .init(id: "Mia", name: "Mia"),
                .init(id: "Chloe", name: "Chloe"),
                .init(id: "Milo", name: "Milo"),
                .init(id: "Dean", name: "Dean")
            ]
        case .fishAudio:
            return []
        }
    }

    static func previewAudio(
        provider: TTSProvider,
        voice: String,
        text: String = "你好，欢迎使用纯享阅读。"
    ) async throws -> Data {
        try await requestAudio(text: text, provider: provider, voice: voice)
    }

    // MARK: - System speech

    private func speakWithSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        let base = AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = min(
            AVSpeechUtteranceMaximumSpeechRate,
            max(AVSpeechUtteranceMinimumSpeechRate, Float(Double(base) * rateMultiplier))
        )
        utterance.pitchMultiplier = 1
        if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        currentUtterance = utterance
        updateNowPlaying(elapsed: 0, duration: Double(text.count) / 12)
        synthesizer.speak(utterance)
    }

    // MARK: - Network speech

    private func playCurrentNetworkChunk(session: UUID) {
        guard session == sessionID else { return }
        guard networkChunks.indices.contains(networkChunkIndex) else {
            finishNetworkSpeech()
            return
        }

        let chunk = networkChunks[networkChunkIndex]
        let selectedProvider = provider
        let voice = voiceIdentifier ?? selectedProvider.defaultVoice
        isLoading = true

        networkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await Self.requestAudio(
                    text: chunk.text,
                    provider: selectedProvider,
                    voice: voice
                )
                try Task.checkCancellation()
                guard session == self.sessionID else { return }

                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.enableRate = true
                player.rate = Float(self.rateMultiplier)
                player.prepareToPlay()
                self.audioPlayer = player
                self.isLoading = false
                self.onBoundary?(chunk.relativeOffset)
                self.updateNowPlaying(elapsed: 0, duration: player.duration)
                if !self.isPaused {
                    player.play()
                }
            } catch is CancellationError {
                return
            } catch {
                guard session == self.sessionID else { return }
                self.failNetworkSpeech(error.localizedDescription)
            }
        }
    }

    private func finishNetworkSpeech() {
        audioPlayer = nil
        networkTask = nil
        isSpeaking = false
        isPaused = false
        isLoading = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateAudioSession()
        onFinishUtterance?()
    }

    private func failNetworkSpeech(_ message: String) {
        networkTask = nil
        audioPlayer = nil
        isSpeaking = false
        isPaused = false
        isLoading = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateAudioSession()
        onError?(message)
    }

    private static func requestAudio(
        text: String,
        provider: TTSProvider,
        voice: String
    ) async throws -> Data {
        guard NetworkTTSConfig.isConfigured(for: provider) else {
            throw TTSNetworkError.notConfigured(provider.displayName)
        }
        guard let base = NetworkTTSConfig.resolvedBaseURL(for: provider) else {
            throw TTSNetworkError.invalidURL
        }

        switch provider {
        case .system:
            throw TTSNetworkError.unsupportedProvider
        case .openAICompatible:
            return try await requestOpenAICompatibleAudio(
                base: base,
                apiKey: NetworkTTSConfig.apiKey(for: provider),
                model: NetworkTTSConfig.model(for: provider),
                voice: voice,
                text: text
            )
        case .xiaomiMiMo:
            return try await requestMiMoAudio(
                base: base,
                apiKey: NetworkTTSConfig.apiKey(for: provider),
                model: NetworkTTSConfig.model(for: provider),
                voice: voice,
                text: text
            )
        case .fishAudio:
            return try await requestFishAudio(
                base: base,
                apiKey: NetworkTTSConfig.apiKey(for: provider),
                model: NetworkTTSConfig.model(for: provider),
                referenceID: voice,
                text: text
            )
        }
    }

    private static func requestOpenAICompatibleAudio(
        base: URL,
        apiKey: String,
        model: String,
        voice: String,
        text: String
    ) async throws -> Data {
        var request = URLRequest(url: endpointURL(base: base, path: "audio/speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "mp3"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(data: data, response: response)
        guard !data.isEmpty else { throw TTSNetworkError.emptyAudio }
        return data
    }

    private static func requestMiMoAudio(
        base: URL,
        apiKey: String,
        model: String,
        voice: String,
        text: String
    ) async throws -> Data {
        var request = URLRequest(url: endpointURL(base: base, path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "assistant", "content": text]],
            "audio": ["format": "pcm16", "voice": voice],
            "stream": true
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(data: data, response: response)
        guard let eventText = String(data: data, encoding: .utf8) else {
            throw TTSNetworkError.invalidResponse
        }

        var pcm = Data()
        for rawLine in eventText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let encoded = extractAudioBase64(from: json),
                  let chunk = Data(base64Encoded: encoded)
            else { continue }
            pcm.append(chunk)
        }

        guard !pcm.isEmpty else { throw TTSNetworkError.emptyAudio }
        return wavData(fromPCM16: pcm, sampleRate: 24_000, channels: 1)
    }

    private static func requestFishAudio(
        base: URL,
        apiKey: String,
        model: String,
        referenceID: String,
        text: String
    ) async throws -> Data {
        var request = URLRequest(url: endpointURL(base: base, path: "tts"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(model, forHTTPHeaderField: "model")

        var body: [String: Any] = [
            "text": text,
            "format": "mp3",
            "normalize": true,
            "latency": "balanced"
        ]
        let cleanedReferenceID = referenceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedReferenceID.isEmpty {
            body["reference_id"] = cleanedReferenceID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(data: data, response: response)
        guard !data.isEmpty else { throw TTSNetworkError.emptyAudio }
        return data
    }

    private static func endpointURL(base: URL, path: String) -> URL {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath == normalizedPath || basePath.hasSuffix("/\(normalizedPath)") {
            return base
        }
        return base.appendingPathComponent(normalizedPath)
    }

    private static func extractAudioBase64(from json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else {
            return nil
        }
        for containerName in ["delta", "message"] {
            guard let container = first[containerName] as? [String: Any],
                  let audio = container["audio"] as? [String: Any]
            else { continue }
            if let data = audio["data"] as? String { return data }
        }
        return nil
    }

    private static func validate(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TTSNetworkError.httpStatus(http.statusCode, String(body.prefix(300)))
        }
    }

    private static func makeChunks(from text: String, maximumUTF16Length: Int = 900) -> [SpeechChunk] {
        let source = text as NSString
        var result: [SpeechChunk] = []
        var location = 0
        let separators = ["\n", "。", "！", "？", ".", "!", "?"]

        while location < source.length {
            var end = min(source.length, location + maximumUTF16Length)
            while end > location,
                  Range<String.Index>(
                    NSRange(location: location, length: end - location),
                    in: text
                  ) == nil {
                end -= 1
            }
            if end <= location { break }

            if end < source.length {
                let searchStart = location + maximumUTF16Length / 3
                let searchRange = NSRange(location: searchStart, length: end - searchStart)
                var bestEnd = 0
                for separator in separators {
                    let match = source.range(of: separator, options: .backwards, range: searchRange)
                    if match.location != NSNotFound {
                        bestEnd = max(bestEnd, NSMaxRange(match))
                    }
                }
                if bestEnd > location { end = bestEnd }
            }

            let range = NSRange(location: location, length: end - location)
            result.append(SpeechChunk(text: source.substring(with: range), relativeOffset: location))
            location = end
        }
        return result
    }

    private static func wavData(fromPCM16 pcm: Data, sampleRate: UInt32, channels: UInt16) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var wav = Data("RIFF".utf8)
        wav.appendLittleEndian(UInt32(36 + pcm.count))
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(channels)
        wav.appendLittleEndian(sampleRate)
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.append(Data("data".utf8))
        wav.appendLittleEndian(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }

    // MARK: - Audio session and lock screen

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
            )
        } catch {
            // 音频会话失败不阻断阅读。
        }
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // 音频会话失败不阻断阅读。
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
    }

    private func updateNowPlaying(elapsed: Double, duration: Double) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: chapterTitle,
            MPMediaItemPropertyAlbumTitle: bookTitle,
            MPMediaItemPropertyArtist: String(localized: "纯享阅读"),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: max(duration, 1),
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0 : rateMultiplier
        ]
    }
}

extension TTSEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard utterance === self.currentUtterance else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
            self.isPaused = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            self.deactivateAudioSession()
            self.onFinishUtterance?()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard utterance === self.currentUtterance else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
            self.isPaused = false
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard utterance === self.currentUtterance else { return }
            self.onBoundary?(characterRange.location)
            self.updateNowPlaying(
                elapsed: Double(characterRange.location) / 12,
                duration: Double(utterance.speechString.count) / 12
            )
        }
    }
}

extension TTSEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.audioPlayer, flag else {
                if player === self.audioPlayer {
                    self.failNetworkSpeech(String(localized: "网络语音播放失败"))
                }
                return
            }
            let session = self.sessionID
            self.audioPlayer = nil
            self.networkChunkIndex += 1
            self.playCurrentNetworkChunk(session: session)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard player === self.audioPlayer else { return }
            self.failNetworkSpeech(error?.localizedDescription ?? String(localized: "无法解码网络语音"))
        }
    }
}

private enum TTSNetworkError: LocalizedError {
    case notConfigured(String)
    case invalidURL
    case unsupportedProvider
    case httpStatus(Int, String)
    case invalidResponse
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .notConfigured(let provider):
            return String(localized: "请先配置 \(provider) 的 API Key")
        case .invalidURL:
            return String(localized: "TTS API 地址无效")
        case .unsupportedProvider:
            return String(localized: "当前语音引擎不支持网络合成")
        case .httpStatus(let code, let body):
            return String(localized: "TTS API 错误 \(code)：\(body)")
        case .invalidResponse:
            return String(localized: "无法解析 TTS API 响应")
        case .emptyAudio:
            return String(localized: "TTS API 未返回音频")
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
