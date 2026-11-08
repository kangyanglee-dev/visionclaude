import Foundation
import AVFoundation

/// Bridges the iOS app to either:
/// - Channel mode (WebSocket → Claude Code session, uses ALL your MCP tools + skills)
/// - Gateway mode (REST → standalone gateway server, uses Claude API)
///
/// Channel mode is the default and preferred mode.
class ClaudeBridge: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published var isConnected: Bool = false
    @Published var mode: ConnectionMode = .channel

    enum ConnectionMode: String, CaseIterable {
        case channel  // WebSocket → Claude Code session
        case gateway  // REST → gateway server (fallback)
    }

    // Callbacks
    var onReply: ((String, String?) -> Void)?    // (text, audioURL?)
    var onStatus: ((String) -> Void)?
    var onThinking: ((String) -> Void)?
    var onDisconnect: (() -> Void)?

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var config: ClaudeConfig
    private var conversationId: String?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var isManualDisconnect = false
    private var pingTimer: Timer?

    init(config: ClaudeConfig) {
        self.config = config
        super.init()
    }

    func updateConfig(_ config: ClaudeConfig) {
        self.config = config
    }

    // MARK: - Channel Mode (WebSocket)

    func connectWebSocket() {
        isManualDisconnect = false
        reconnectAttempts = 0

        guard let wsURL = config.wsURL else {
            onStatus?("invalid configuration")
            return
        }
        print("[Bridge] Connecting WebSocket")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.urlSession = session
        var request = URLRequest(url: wsURL)
        if !config.channelToken.isEmpty {
            request.setValue("Bearer \(config.channelToken)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        self.webSocket = task
        task.resume()
        receiveMessage()
    }

    func disconnect() {
        isManualDisconnect = true
        pingTimer?.invalidate()
        pingTimer = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        onDisconnect?()
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleWebSocketMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleWebSocketMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage() // Keep listening
            case .failure(let error):
                print("[Bridge] WebSocket receive error: \(error)")
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.attemptReconnect()
                }
            }
        }
    }

    private func handleWebSocketMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case "status":
                let status = json["status"] as? String ?? ""
                print("[Bridge] Status: \(status)")
                if status == "connected" {
                    self.isConnected = true
                    self.reconnectAttempts = 0
                    self.startPingTimer()
                }
                self.onStatus?(status)

            case "reply":
                let replyText = json["text"] as? String ?? ""
                let audioUrl = json["audio_url"] as? String
                let fullAudioUrl: String?
                if let audioPath = audioUrl {
                    fullAudioUrl = "http://\(self.config.gatewayHost):\(self.config.gatewayPort)\(audioPath)"
                } else {
                    fullAudioUrl = nil
                }
                print("[Bridge] Reply: \(replyText.prefix(80))...")
                self.onReply?(replyText, fullAudioUrl)

            case "thinking":
                let thinkText = json["text"] as? String ?? ""
                self.onThinking?(thinkText)

            default:
                break
            }
        }
    }

    // MARK: - Send Messages

    /// Send text + optional image via WebSocket (channel mode)
    func sendMessage(text: String, image: Data? = nil, source: String = "iphone") {
        guard mode == .channel else {
            // Fallback to REST
            Task { try? await chatREST(text: text, images: image.map { [$0] } ?? []) }
            return
        }

        var payload: [String: Any] = [
            "id": "ios-\(Date().timeIntervalSince1970)",
            "text": text,
            "source": source,
        ]

        if let imageData = image {
            payload["image"] = imageData.base64EncodedString()
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        webSocket?.send(.string(jsonString)) { error in
            if let error {
                print("[Bridge] WebSocket send error: \(error)")
            }
        }

        print("[Bridge] Sent: \"\(text.prefix(60))\" source=\(source) image=\(image != nil)")
    }

    /// Upload image via HTTP multipart (for large images, avoids base64 bloat over WS)
    func uploadImage(text: String, image: Data, source: String = "iphone") async throws {
        guard let url = config.baseURL?.appendingPathComponent("upload") else {
            throw ClaudeBridgeError.invalidGatewayAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !config.channelToken.isEmpty {
            request.setValue("Bearer \(config.channelToken)", forHTTPHeaderField: "Authorization")
        }

        let boundary = "VisionClaude-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let fields: [(String, String)] = [
            ("id", "ios-\(Date().timeIntervalSince1970)"),
            ("text", text),
            ("source", source),
        ]
        for (key, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(image)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 204 else {
            throw ClaudeBridgeError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Upload failed")
        }
        print("[Bridge] Uploaded \(source) image (\(image.count / 1024)KB)")
    }

    /// Publish one fresh Ray-Ban JPEG to the local gateway for on-demand MCP reads.
    /// This route does not call an AI provider.
    func uploadGlassesFrame(_ image: Data, streamID: String, sequence: Int) async throws {
        guard !config.channelToken.isEmpty else { throw ClaudeBridgeError.missingGatewayToken }
        guard image.count <= 1_048_576 else { throw ClaudeBridgeError.frameTooLarge }
        guard let url = config.baseURL?.appendingPathComponent("glasses/frame") else {
            throw ClaudeBridgeError.invalidGatewayAddress
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(config.channelToken, forHTTPHeaderField: "X-Gateway-Key")
        request.setValue(streamID, forHTTPHeaderField: "X-Glasses-Stream-Id")
        request.setValue(String(sequence), forHTTPHeaderField: "X-Frame-Sequence")
        request.httpBody = image

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClaudeBridgeError.invalidResponse
        }
    }

    // MARK: - Gateway Mode (REST fallback)

    func chatREST(text: String, images: [Data] = []) async throws -> ChatResponse {
        guard !config.channelToken.isEmpty else { throw ClaudeBridgeError.missingGatewayToken }
        let base64Images = images.map { $0.base64EncodedString() }
        let request = ChatRequest(text: text, images: base64Images, conversation_id: conversationId)

        guard let chatURL = config.chatURL else {
            throw ClaudeBridgeError.invalidGatewayAddress
        }
        var urlRequest = URLRequest(url: chatURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(config.channelToken, forHTTPHeaderField: "X-Gateway-Key")
        urlRequest.timeoutInterval = 60
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeBridgeError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: body)
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        conversationId = chatResponse.conversation_id
        return chatResponse
    }

    func checkHealth() async throws -> HealthResponse {
        guard !config.channelToken.isEmpty else { throw ClaudeBridgeError.missingGatewayToken }
        guard let healthURL = config.healthURL else {
            throw ClaudeBridgeError.invalidGatewayAddress
        }
        var request = URLRequest(url: healthURL)
        request.setValue(config.channelToken, forHTTPHeaderField: "X-Gateway-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeBridgeError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: body)
        }
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    // MARK: - Reconnection

    private func attemptReconnect() {
        guard !isManualDisconnect, reconnectAttempts < maxReconnectAttempts else {
            print("[Bridge] Giving up reconnection after \(reconnectAttempts) attempts")
            return
        }
        reconnectAttempts += 1
        let delay = min(Double(reconnectAttempts) * 2.0, 10.0)
        print("[Bridge] Reconnecting in \(delay)s (attempt \(reconnectAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connectWebSocket()
        }
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.webSocket?.sendPing { error in
                if let error {
                    print("[Bridge] Ping failed: \(error)")
                }
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        print("[Bridge] WebSocket opened")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("[Bridge] WebSocket closed: \(closeCode)")
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.attemptReconnect()
        }
    }

    func resetConversation() {
        conversationId = nil
    }
}

enum ClaudeBridgeError: LocalizedError {
    case invalidResponse
    case invalidGatewayAddress
    case frameTooLarge
    case missingGatewayToken
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .invalidGatewayAddress:
            return "Enter a hostname or IP address only, without http:// or a path"
        case .frameTooLarge:
            return "Glasses frame exceeds the 1 MB gateway limit"
        case .missingGatewayToken:
            return "Enter the gateway key in Channel Token settings"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        }
    }
}
