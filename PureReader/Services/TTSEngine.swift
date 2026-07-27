import Foundation
import AVFoundation
import MediaPlayer

/// TTS 听书：AVSpeechSynthesizer + 锁屏控制
@MainActor
final class TTSEngine: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var voiceIdentifier: String?

    /// 当前朗读到的字符 offset（相对 utterance 文本）
    var spokenOffset: Int = 0

    var onFinishUtterance: (() -> Void)?
    var onBoundary: ((Int) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var currentText: String = ""
    private var bookTitle: String = ""
    private var chapterTitle: String = ""

    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
        setupRemoteCommands()
    }

    func configure(rate: Double, voiceIdentifier: String?) {
        // settings.ttsRate 为倍速 0.5...2.0，映射到 AVSpeech 0...1
        let base = AVSpeechUtteranceDefaultSpeechRate
        let mapped = Float(Double(base) * rate)
        self.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, mapped))
        self.voiceIdentifier = voiceIdentifier
    }

    func speak(
        text: String,
        bookTitle: String,
        chapterTitle: String,
        startOffset: Int = 0
    ) {
        stop()
        self.spokenOffset = startOffset
        self.bookTitle = bookTitle
        self.chapterTitle = chapterTitle

        let ns = text as NSString
        let safe = min(max(0, startOffset), max(0, ns.length - 1))
        let slice = ns.length > 0 ? ns.substring(from: safe) : ""
        currentText = slice
        spokenOffset = safe

        let utterance = AVSpeechUtterance(string: slice)
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else if let zh = AVSpeechSynthesisVoice(language: "zh-CN") {
            utterance.voice = zh
        }

        updateNowPlaying(elapsed: 0, duration: Double(slice.count) / 12.0)
        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused = false
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
    }

    func toggle() {
        if isPaused {
            resume()
        } else if isSpeaking {
            pause()
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        spokenOffset = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    static func availableVoices(languagePrefix: String = "zh") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(languagePrefix) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Audio


    static func availableChineseVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("zh")
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            // 会话失败不阻断阅读
        }
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
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitle,
            MPMediaItemPropertyAlbumTitle: bookTitle,
            MPMediaItemPropertyArtist: String(localized: "纯享阅读"),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: max(duration, 1),
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension TTSEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused = false
            self.onFinishUtterance?()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            // characterRange 相对 utterance 文本；换算为全文 offset 由调用方处理
            self.onBoundary?(characterRange.location)
            self.updateNowPlaying(
                elapsed: Double(characterRange.location) / 12.0,
                duration: Double(utterance.speechString.count) / 12.0
            )
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused = false
        }
    }
}
