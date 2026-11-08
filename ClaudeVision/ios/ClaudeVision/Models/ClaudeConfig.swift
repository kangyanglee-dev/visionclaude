import Foundation

struct ClaudeConfig: Codable {
    var gatewayHost: String = "MR-DULA-SOLUTIONS.local"
    var gatewayPort: Int = 18790
    var videoFrameInterval: TimeInterval = 1.0
    var videoJPEGQuality: Double = 0.85
    var speechPauseThreshold: TimeInterval = 1.5
    var elevenLabsAPIKey: String = ""
    var elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM" // Rachel (default)
    var channelToken: String = ""

    var baseURL: URL? {
        guard let host = normalizedGatewayHost else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = gatewayPort
        return components.url
    }

    var wsURL: URL? {
        guard let host = normalizedGatewayHost else { return nil }
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = host
        comps.port = gatewayPort
        comps.path = "/ws"
        return comps.url
    }

    var chatURL: URL? { baseURL?.appendingPathComponent("chat") }
    var healthURL: URL? { baseURL?.appendingPathComponent("health") }
    var toolsURL: URL? { baseURL?.appendingPathComponent("tools") }

    private var normalizedGatewayHost: String? {
        let host = gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              !host.contains("://"),
              !host.contains("/"),
              !host.contains(" ") else { return nil }
        return host
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
