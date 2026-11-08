import Foundation

struct ClaudeConfig: Codable {
    var gatewayHost: String = "MR-DULA-SOLUTIONS.local"
    var gatewayPort: Int = 18790
    var gatewayUsesHTTPS: Bool = false
    var videoFrameInterval: TimeInterval = 1.0
    var videoJPEGQuality: Double = 0.85
    var speechPauseThreshold: TimeInterval = 1.5
    var elevenLabsAPIKey: String = ""
    var elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM" // Rachel (default)
    var channelToken: String = ""

    var baseURL: URL? {
        guard let host = normalizedGatewayHost else { return nil }
        var components = URLComponents()
        components.scheme = gatewayUsesHTTPS ? "https" : "http"
        components.host = host
        components.port = gatewayPort
        return components.url
    }

    var wsURL: URL? {
        guard let host = normalizedGatewayHost else { return nil }
        var comps = URLComponents()
        comps.scheme = gatewayUsesHTTPS ? "wss" : "ws"
        comps.host = host
        comps.port = gatewayPort
        comps.path = "/ws"
        return comps.url
    }

    var chatURL: URL? { baseURL?.appendingPathComponent("chat") }
    var healthURL: URL? { baseURL?.appendingPathComponent("health") }
    var toolsURL: URL? { baseURL?.appendingPathComponent("tools") }

    init(
        gatewayHost: String = "MR-DULA-SOLUTIONS.local",
        gatewayPort: Int = 18790,
        gatewayUsesHTTPS: Bool = false,
        videoFrameInterval: TimeInterval = 1.0,
        videoJPEGQuality: Double = 0.85,
        speechPauseThreshold: TimeInterval = 1.5,
        elevenLabsAPIKey: String = "",
        elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM",
        channelToken: String = ""
    ) {
        self.gatewayHost = gatewayHost
        self.gatewayPort = gatewayPort
        self.gatewayUsesHTTPS = gatewayUsesHTTPS
        self.videoFrameInterval = videoFrameInterval
        self.videoJPEGQuality = videoJPEGQuality
        self.speechPauseThreshold = speechPauseThreshold
        self.elevenLabsAPIKey = elevenLabsAPIKey
        self.elevenLabsVoiceId = elevenLabsVoiceId
        self.channelToken = channelToken
    }

    private var normalizedGatewayHost: String? {
        let host = gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              !host.contains("://"),
              !host.contains("/"),
              !host.contains(" ") else { return nil }
        return host
    }

    private enum CodingKeys: String, CodingKey {
        case gatewayHost
        case gatewayPort
        case gatewayUsesHTTPS
        case videoFrameInterval
        case videoJPEGQuality
        case speechPauseThreshold
        case elevenLabsAPIKey
        case elevenLabsVoiceId
        case channelToken
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        gatewayHost = try values.decodeIfPresent(String.self, forKey: .gatewayHost) ?? "MR-DULA-SOLUTIONS.local"
        gatewayPort = try values.decodeIfPresent(Int.self, forKey: .gatewayPort) ?? 18790
        gatewayUsesHTTPS = try values.decodeIfPresent(Bool.self, forKey: .gatewayUsesHTTPS) ?? false
        videoFrameInterval = try values.decodeIfPresent(TimeInterval.self, forKey: .videoFrameInterval) ?? 1.0
        videoJPEGQuality = try values.decodeIfPresent(Double.self, forKey: .videoJPEGQuality) ?? 0.85
        speechPauseThreshold = try values.decodeIfPresent(TimeInterval.self, forKey: .speechPauseThreshold) ?? 1.5
        elevenLabsAPIKey = try values.decodeIfPresent(String.self, forKey: .elevenLabsAPIKey) ?? ""
        elevenLabsVoiceId = try values.decodeIfPresent(String.self, forKey: .elevenLabsVoiceId) ?? "21m00Tcm4TlvDq8ikWAM"
        channelToken = try values.decodeIfPresent(String.self, forKey: .channelToken) ?? ""
    }

    // MARK: - Persistence

    private static let storageKey = "ClaudeConfig"

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    static func load() -> ClaudeConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(ClaudeConfig.self, from: data) else {
            return ClaudeConfig()
        }
        return config
    }
}
