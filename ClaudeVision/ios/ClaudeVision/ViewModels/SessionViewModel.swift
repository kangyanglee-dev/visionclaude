import Foundation
import Combine
import UIKit

enum SessionState: String {
    case disconnected = "Disconnected"
    case idle = "Ready"
    case listening = "Listening"
    case thinking = "Thinking"
    case speaking = "Speaking"
}

@MainActor
class SessionViewModel: ObservableObject {
    @Published var state: SessionState = .disconnected
    @Published var transcript: [TranscriptMessage] = []
    @Published var currentTranscription: String = ""
    @Published var isConnected: Bool = false
    @Published var errorMessage: String?
    @Published var isProcessing: Bool = false
    @Published var glassesUploadStatus = "Waiting for a connection"
    @Published var glassesUploadLastError: String?
    @Published var connectionMode: ClaudeBridge.ConnectionMode = .channel {
        didSet {
            guard oldValue != connectionMode else { return }
            config.connectionModeRawValue = connectionMode.rawValue
            config.save()
        }
    }

    @Published var config: ClaudeConfig {
        didSet {
            bridge.updateConfig(config)
            speechManager.configureElevenLabs(
                apiKey: config.elevenLabsAPIKey,
                voiceId: config.elevenLabsVoiceId
            )
            speechManager.setVoice(config.elevenLabsVoiceId)
            speechManager.setPauseThreshold(config.speechPauseThreshold)
            config.save()
        }
    }

    // Frame sources
    @Published var activeFrameSource: FrameSourceType = .iPhone {
        didSet { switchFrameSource() }
    }
    @Published var frameSourceStatus: FrameSourceStatus = .disconnected
    @Published var rayBanFrame: UIImage?

    // Mode system
    @Published var modeManager = ModeManager()

    // QR/Barcode toast
    @Published var codeToastMessage: String?
    @Published var codeToastDetectedCode: DetectedCode?

    let bridge: ClaudeBridge
    let speechManager = SpeechManager()
    let cameraManager = CameraManager()
    let rayBanManager = RayBanManager()
    private var cancellables = Set<AnyCancellable>()
    private var glassesUploadStreamID: String?
    private var glassesUploadSequence = 0
    private var glassesUploadGeneration = 0
    private var glassesUploadInFlight = false
    private var glassesUploadTask: Task<Void, Never>?
    private var lastGlassesUploadAt: Date?

    init(config: ClaudeConfig = ClaudeConfig.load()) {
        let initialConnectionMode = ClaudeBridge.ConnectionMode(rawValue: config.connectionModeRawValue) ?? .channel
        let bridge = ClaudeBridge(config: config)
        bridge.mode = initialConnectionMode
        self.config = config
        self.bridge = bridge
        self.connectionMode = initialConnectionMode
        setupBindings()
        setupBridgeCallbacks()
        setupCodeDetection()
        rayBanManager.startMonitoringRegistration()
        speechManager.configureElevenLabs(
            apiKey: config.elevenLabsAPIKey,
            voiceId: config.elevenLabsVoiceId
        )

        // Forward Ray-Ban frames for SwiftUI reactivity
        rayBanManager.$latestImage
            .receive(on: RunLoop.main)
            .assign(to: &$rayBanFrame)

        // Forward Ray-Ban connection status
        rayBanManager.$connectionStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, self.activeFrameSource == .rayBan else { return }
                self.frameSourceStatus = status
                if status.isConnected {
                    self.startGlassesFrameUploadStreamIfReady()
                } else {
                    self.stopGlassesFrameUploadStream()
                }
            }
            .store(in: &cancellables)

        rayBanManager.$latestFrame
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] frame in
                self?.uploadGlassesFrameIfReady(frame)
            }
            .store(in: &cancellables)

        // Forward bridge connection state
        bridge.$isConnected
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                self.isConnected = connected
                if connected {
                    self.startGlassesFrameUploadStreamIfReady()
                } else {
                    self.stopGlassesFrameUploadStream()
                }
            }
            .store(in: &cancellables)

        bridge.$mode
            .receive(on: RunLoop.main)
            .assign(to: &$connectionMode)
    }

    // MARK: - Bridge Callbacks

    private func setupBridgeCallbacks() {
        // When Claude replies via the channel
        bridge.onReply = { [weak self] text, audioUrl in
            Task { @MainActor [weak self] in
                guard let self else { return }

                self.transcript.append(TranscriptMessage(role: .assistant, text: text))
                self.isProcessing = false

                if let audioUrl, let url = URL(string: audioUrl) {
                    // Play TTS audio from channel server
                    self.state = .speaking
                    self.speechManager.playRemoteAudio(url: url) { [weak self] in
                        Task { @MainActor in
                            guard let self, self.isConnected, self.state == .speaking else { return }
                            self.startListening()
                        }
                    }
                } else {
                    // Fallback to local TTS
                    self.state = .speaking
                    self.speechManager.speak(text)
                    self.observeSpeechCompletion()
                }
            }
        }

        bridge.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == "connected" {
                    self.state = .idle
                    self.errorMessage = nil
                    AudioSessionManager.shared.setGlassesCameraStreaming(self.activeFrameSource == .rayBan)
                    try? AudioSessionManager.shared.configureForVoiceChat()
                    self.startActiveFrameSource()
                    self.startGlassesFrameUploadStreamIfReady()
                }
            }
        }

        bridge.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.state = .disconnected
                self?.stopGlassesFrameUploadStream()
            }
        }
    }

    // MARK: - QR/Barcode Detection

    private func setupCodeDetection() {
        cameraManager.$lastDetectedCode
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] code in
                guard let self else { return }
                self.handleDetectedCode(code)
            }
            .store(in: &cancellables)
    }

    private func handleDetectedCode(_ code: DetectedCode) {
        if modeManager.activeMode.id == "qr_scanner" {
            // In QR Scanner mode: automatically send to Claude
            let message = "I scanned a \(code.type) code: \(code.value). What is this?"
            Task { await self.sendText(message) }
        } else {
            // In other modes: show a toast notification
            codeToastDetectedCode = code
            codeToastMessage = "\(code.type): \(code.value)"
            // Auto-dismiss toast after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.codeToastDetectedCode?.timestamp == code.timestamp {
                    self?.codeToastMessage = nil
                    self?.codeToastDetectedCode = nil
                }
            }
        }
    }

    func sendCodeToChat(_ code: DetectedCode) {
        codeToastMessage = nil
        codeToastDetectedCode = nil
        let message = "I scanned a \(code.type) code: \(code.value). What is this?"
        Task { await self.sendText(message) }
    }

    func copyCodeToClipboard(_ code: DetectedCode) {
        UIPasteboard.general.string = code.value
        codeToastMessage = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.codeToastMessage = nil
            self?.codeToastDetectedCode = nil
        }
    }

    // MARK: - Connection

    func connect() async {
        errorMessage = nil
        stopGlassesFrameUploadStream()
        bridge.disconnect()
        bridge.mode = connectionMode

        if connectionMode == .channel && config.wsURL == nil {
            errorMessage = ClaudeBridgeError.invalidGatewayAddress.localizedDescription
            state = .disconnected
            return
        }

        if connectionMode == .gateway {
            do {
                let health = try await bridge.checkHealth()
                guard health.status == "ok" else { throw ClaudeBridgeError.invalidResponse }
                bridge.isConnected = true
                state = .idle
                AudioSessionManager.shared.setGlassesCameraStreaming(activeFrameSource == .rayBan)
                try? AudioSessionManager.shared.configureForVoiceChat()
                startActiveFrameSource()
                startGlassesFrameUploadStreamIfReady()
            } catch {
                bridge.isConnected = false
                errorMessage = error.localizedDescription
                state = .disconnected
            }
            return
        }

        // Channel mode uses the Claude Code WebSocket.
        bridge.connectWebSocket()

        // Also check health endpoint for status
        do {
            let health = try await bridge.checkHealth()
            if health.status == "ok" {
                print("[Session] Channel server health OK")
            }
        } catch {
            print("[Session] Health check failed (channel may still connect via WS): \(error.localizedDescription)")
        }
    }

    func disconnect() {
        stopGlassesFrameUploadStream()
        speechManager.stopListening()
        speechManager.stopSpeaking()
        cameraManager.stop()
        rayBanManager.stop()
        bridge.disconnect()
        frameSourceStatus = .disconnected
        state = .disconnected
    }

    func connectGlasses() async {
        await rayBanManager.register()
    }

    // MARK: - Frame Source

    private func switchFrameSource() {
        stopGlassesFrameUploadStream()
        cameraManager.stop()
        rayBanManager.stop()

        if activeFrameSource == .rayBan {
            AudioSessionManager.shared.setGlassesCameraStreaming(true)
            try? AudioSessionManager.shared.configureForVoiceChat()
            if isConnected && !speechManager.isListening {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.startListening()
                }
            }
        } else {
            AudioSessionManager.shared.setGlassesCameraStreaming(false)
        }
        startActiveFrameSource()
    }

    private func startGlassesFrameUploadStreamIfReady() {
        guard activeFrameSource == .rayBan,
              isConnected,
              rayBanManager.connectionStatus.isConnected else {
            stopGlassesFrameUploadStream()
            return
        }
        guard glassesUploadStreamID == nil else { return }
        glassesUploadGeneration += 1
        glassesUploadSequence = 0
        lastGlassesUploadAt = nil
        glassesUploadStreamID = UUID().uuidString
        glassesUploadStatus = "Ready; waiting for a fresh Ray-Ban frame"
        print("[Session] Glasses frame upload stream started")
    }

    private func stopGlassesFrameUploadStream() {
        if glassesUploadStreamID != nil || glassesUploadInFlight {
            glassesUploadGeneration += 1
            glassesUploadStreamID = nil
            glassesUploadSequence = 0
            lastGlassesUploadAt = nil
            print("[Session] Glasses frame upload stream stopped")
        }
        glassesUploadStatus = glassesUploadReadinessStatus()
    }

    private func glassesUploadReadinessStatus() -> String {
        if activeFrameSource != .rayBan { return "Idle; select Meta Ray-Ban as camera source" }
        if !isConnected { return "Waiting for Gateway connection" }
        if !rayBanManager.connectionStatus.isConnected { return "Waiting for glasses video stream" }
        if config.channelToken.isEmpty { return "Waiting for Gateway key" }
        return "Waiting for a fresh Ray-Ban frame"
    }

    private func uploadGlassesFrameIfReady(_ frame: Data) {
        guard activeFrameSource == .rayBan,
              isConnected,
              rayBanManager.connectionStatus.isConnected else {
            glassesUploadStatus = glassesUploadReadinessStatus()
            return
        }
        guard !glassesUploadInFlight else { return }
        guard !config.channelToken.isEmpty else {
            glassesUploadStatus = "Waiting for Gateway key"
            return
        }
        startGlassesFrameUploadStreamIfReady()
        guard let streamID = glassesUploadStreamID else { return }
        guard frame.count <= 1_048_576 else {
            glassesUploadLastError = "Frame skipped: JPEG exceeds the 1 MiB limit"
            return
        }

        let now = Date()
        if let lastGlassesUploadAt, now.timeIntervalSince(lastGlassesUploadAt) < 1.0 { return }

        glassesUploadInFlight = true
        lastGlassesUploadAt = now
        let sequence = glassesUploadSequence
        let generation = glassesUploadGeneration
        glassesUploadStatus = "Uploading frame #\(sequence)…"
        glassesUploadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.glassesUploadInFlight = false
                self.glassesUploadTask = nil
            }
            do {
                let statusCode = try await self.bridge.uploadGlassesFrame(frame, streamID: streamID, sequence: sequence)
                if self.glassesUploadGeneration == generation,
                   self.glassesUploadStreamID == streamID,
                   self.glassesUploadSequence == sequence {
                    self.glassesUploadSequence += 1
                    self.glassesUploadLastError = nil
                    self.glassesUploadStatus = "Uploaded frame #\(sequence) (HTTP \(statusCode))"
                }
            } catch {
                self.glassesUploadLastError = self.glassesUploadErrorDescription(error)
                if self.glassesUploadGeneration == generation,
                   self.glassesUploadStreamID == streamID {
                    self.glassesUploadStatus = "Frame upload failed"
                }
                print("[Session] Glasses frame upload failed: \(error.localizedDescription)")
            }
        }
    }

    private func glassesUploadErrorDescription(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLSession error \(urlError.code.rawValue): \(urlError.localizedDescription)"
        }
        return error.localizedDescription
    }

    private func startActiveFrameSource() {
        do {
            switch activeFrameSource {
            case .iPhone:
                cameraManager.configure(frameInterval: config.videoFrameInterval, jpegQuality: config.videoJPEGQuality)
                try cameraManager.start()
                frameSourceStatus = .connected
            case .rayBan:
                rayBanManager.configure(frameInterval: config.videoFrameInterval, jpegQuality: config.videoJPEGQuality)
                try rayBanManager.start()
            }
            errorMessage = nil
        } catch {
            frameSourceStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Interrupt

    func interruptSpeaking() {
        speechManager.stopSpeaking()
        print("[Session] Speaking interrupted by user — resuming listening")
        // Brief delay for audio session to settle after stopping playback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startListening()
        }
    }

    // MARK: - Voice

    func toggleListening() {
        if speechManager.isListening {
            speechManager.stopListening()
            state = .idle
        } else {
            startListening()
        }
    }

    func startListening() {
        if speechManager.isSpeaking {
            speechManager.stopSpeaking()
        }
        do {
            try speechManager.startListening()
            state = .listening
            errorMessage = nil
        } catch {
            errorMessage = "Mic: \(error.localizedDescription)"
        }
    }

    private func setupBindings() {
        speechManager.$transcribedText
            .receive(on: RunLoop.main)
            .assign(to: &$currentTranscription)

        speechManager.onSpeechPause = { [weak self] text in
            Task { @MainActor in
                await self?.handleUserSpeech(text)
            }
        }

        speechManager.setPauseThreshold(config.speechPauseThreshold)

        NotificationCenter.default.publisher(for: .audioInterruptionBegan)
            .sink { [weak self] _ in
                self?.speechManager.stopListening()
                self?.speechManager.stopSpeaking()
                self?.state = .idle
            }
            .store(in: &cancellables)
    }

    // MARK: - Send Message

    func sendText(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await handleUserSpeech(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func handleUserSpeech(_ text: String) async {
        guard !isProcessing else { return }
        isProcessing = true

        transcript.append(TranscriptMessage(role: .user, text: text))
        currentTranscription = ""
        state = .thinking
        errorMessage = nil

        // Prepend mode system prompt as context
        let modeContext = modeManager.activeMode.systemPrompt
        let fullText = "[Mode: \(modeManager.activeMode.name)] \(modeContext)\n\nUser: \(text)"

        // Grab latest frame
        var image: Data?
        let source: String
        switch activeFrameSource {
        case .iPhone:
            image = cameraManager.consumeFrame()
            source = "iphone"
        case .rayBan:
            image = rayBanManager.consumeFrame()
            source = "rayban"
        }

        if bridge.mode == .channel {
            // Channel mode: send via WebSocket or HTTP upload
            if let imageData = image, imageData.count > 100_000 {
                // Large images: use HTTP multipart (avoids base64 bloat)
                do {
                    try await bridge.uploadImage(text: fullText, image: imageData, source: source)
                } catch {
                    print("[Session] Upload error, falling back to WS: \(error)")
                    bridge.sendMessage(text: fullText, image: imageData, source: source)
                }
            } else {
                // Small images or text-only: send via WebSocket
                bridge.sendMessage(text: fullText, image: image, source: source)
            }
            print("[Session] Sent to channel: \"\(text)\" with \(image != nil ? "image" : "no image") [mode: \(modeManager.activeMode.name)]")
            // Reply comes back via onReply callback — don't set isProcessing = false here

        } else {
            // Gateway mode: REST fallback
            do {
                let response = try await bridge.chatREST(text: fullText, images: image.map { [$0] } ?? [])
                transcript.append(TranscriptMessage(
                    role: .assistant,
                    text: response.text,
                    toolCalls: response.tool_calls
                ))
                state = .speaking
                speechManager.speak(response.text)
                observeSpeechCompletion()
            } catch {
                errorMessage = error.localizedDescription
                state = .idle
            }
            isProcessing = false
        }
    }

    private func observeSpeechCompletion() {
        speechManager.$isSpeaking
            .dropFirst()
            .filter { !$0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isConnected, self.state == .speaking else { return }
                self.startListening()
            }
            .store(in: &cancellables)
    }

    func resetConversation() async {
        transcript.removeAll()
        bridge.resetConversation()
        errorMessage = nil
    }
}
