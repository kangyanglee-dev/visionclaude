import Foundation
import Combine
import UIKit
import MWDATCore
import MWDATCamera

@MainActor
class RayBanManager: NSObject, ObservableObject, FrameSource {

    // MARK: - FrameSource Protocol

    @Published var latestFrame: Data?
    @Published var latestImage: UIImage?
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectionStatus: FrameSourceStatus = .disconnected
    @Published var frameCount: Int = 0

    let sourceType: FrameSourceType = .rayBan

    // MARK: - State

    @Published var glassesName: String = "Not Connected"
    @Published var hasActiveDevice: Bool = false
    @Published var registrationState: String = "unregistered"
    @Published var isRegistered: Bool = false
    @Published var registrationMessage: String?
    @Published var sdkConfigurationMessage: String? = UserDefaults.standard.string(forKey: "DATConfigurationError")

    // DAT SDK
    private var streamSession: StreamSession?
    private var deviceSelector: AutoDeviceSelector?
    private var stateToken: AnyListenerToken?
    private var frameToken: AnyListenerToken?
    private var errorToken: AnyListenerToken?
    private var deviceMonitorTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?

    private var frameInterval: TimeInterval = 1.0
    private var jpegQuality: CGFloat = 0.5
    private var lastCaptureTime: Date = .distantPast

    // MARK: - Configuration

    func configure(frameInterval: TimeInterval = 1.0, jpegQuality: CGFloat = 0.5) {
        self.frameInterval = frameInterval
        self.jpegQuality = jpegQuality
    }

    // MARK: - Registration (MUST complete before streaming)

    func startMonitoringRegistration() {
        let wearables = Wearables.shared
        registrationTask = Task { @MainActor in
            for await state in wearables.registrationStateStream() {
                switch state {
                case .registered:
                    self.registrationState = "registered"
                    self.isRegistered = true
                    self.registrationMessage = nil
                    print("[RayBan] Registration complete")
                case .registering:
                    self.registrationState = "registering"
                    self.registrationMessage = "Waiting for Meta AI approval…"
                    print("[RayBan] Registration in progress...")
                case .available:
                    self.registrationState = "available"
                    self.isRegistered = false
                case .unavailable:
                    self.registrationState = "unavailable"
                    self.isRegistered = false
                    self.registrationMessage = "DAT registration is unavailable. Check Meta AI and Developer Mode."
                @unknown default:
                    break
                }
            }
        }

        // Check current state
        let currentState = wearables.registrationState
        switch currentState {
        case .registered:
            isRegistered = true
            registrationState = "registered"
        case .registering:
            registrationState = "registering"
        case .available:
            registrationState = "available"
        case .unavailable:
            registrationState = "unavailable"
            registrationMessage = "DAT registration is unavailable. Check Meta AI and Developer Mode."
        @unknown default:
            break
        }
    }

    func register() async {
        guard !isRegistered else {
            print("[RayBan] Already registered")
            return
        }

        do {
            print("[RayBan] Starting registration with Meta AI...")
            registrationMessage = "Opening Meta AI for approval…"
            connectionStatus = .connecting
            try await Wearables.shared.startRegistration()
            if Wearables.shared.registrationState == .registering {
                registrationMessage = "Waiting for Meta AI approval…"
            } else if Wearables.shared.registrationState != .registered {
                registrationMessage = "Registration was requested, but Meta AI has not approved this app yet."
            }
        } catch {
            let details = registrationErrorDescription(error)
            print("[RayBan] Registration error: \(details)")
            registrationMessage = details
            connectionStatus = .error("Registration failed: \(details)")
        }
    }

    private func registrationErrorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "MWDATCore.RegistrationError", nsError.code == 1 {
            return "Meta DAT rejected the registration configuration (configurationInvalid, code 1). Check the app ID, callback scheme, and the SDK's development-mode configuration."
        }
        return "\(nsError.domain) (code \(nsError.code)): \(nsError.localizedDescription)"
    }

    // MARK: - FrameSource Implementation

    func start() throws {
        guard !isRunning else { return }

        // Re-check registration state directly from SDK
        let currentState = Wearables.shared.registrationState
        if currentState == .registered {
            isRegistered = true
            registrationState = "registered"
        }

        guard isRegistered else {
            print("[RayBan] Not registered (state: \(currentState)) — starting registration first")
            connectionStatus = .error("Tap 'Connect Glasses' in Settings to register with Meta AI first")
            Task { await register() }
            return
        }

        connectionStatus = .connecting
        print("[RayBan] Starting stream session...")

        let wearables = Wearables.shared
        let selector = AutoDeviceSelector(wearables: wearables)
        self.deviceSelector = selector

        // Stream at 30fps, high resolution (720x1280)
        let config = StreamSessionConfig(
            videoCodec: .raw,
            resolution: .high,
            frameRate: 30
        )
        let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)
        self.streamSession = session

        // Monitor device availability
        deviceMonitorTask = Task { @MainActor in
            for await device in selector.activeDeviceStream() {
                self.hasActiveDevice = device != nil
                if device != nil {
                    self.glassesName = "Ray-Ban Meta"
                    print("[RayBan] Device active")
                } else {
                    self.glassesName = "No Device"
                    print("[RayBan] No active device")
                }
            }
        }

        // State changes
        stateToken = session.statePublisher.listen { [weak self] (state: StreamSessionState) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[RayBan] State: \(state)")
                switch state {
                case .streaming:
                    self.isRunning = true
                    self.connectionStatus = .connected
                case .stopped:
                    self.isRunning = false
                    self.connectionStatus = .disconnected
                case .waitingForDevice:
                    self.connectionStatus = .connecting
                case .starting:
                    self.connectionStatus = .connecting
                case .stopping:
                    self.connectionStatus = .connecting
                case .paused:
                    self.connectionStatus = .connecting
                @unknown default:
                    break
                }
            }
        }

        // Video frames
        frameToken = session.videoFramePublisher.listen { [weak self] (videoFrame: VideoFrame) in
            Task { @MainActor [weak self] in
                guard let self else { return }

                guard let uiImage = videoFrame.makeUIImage() else { return }

                // Always update preview
                self.latestImage = uiImage
                self.frameCount += 1

                // Throttle JPEG for Claude
                let now = Date()
                if now.timeIntervalSince(self.lastCaptureTime) >= self.frameInterval {
                    self.lastCaptureTime = now
                    if let jpegData = uiImage.jpegData(compressionQuality: self.jpegQuality) {
                        self.latestFrame = jpegData
                        print("[RayBan] Captured JPEG frame (\(jpegData.count) bytes)")
                    }
                }
            }
        }

        // Errors
        errorToken = session.errorPublisher.listen { [weak self] (error: StreamSessionError) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let msg = self.formatError(error)
                print("[RayBan] Error: \(msg)")
                self.connectionStatus = .error(msg)
            }
        }

        // Request camera permission THEN start (matches VisionClaw pattern)
        Task {
            do {
                let wearables = Wearables.shared
                print("[RayBan] Checking camera permission...")
                let status = try await wearables.checkPermissionStatus(.camera)
                print("[RayBan] Camera permission status: \(status)")
                if status == .granted {
                    print("[RayBan] Camera permission already granted — starting session")
                    await session.start()
                    print("[RayBan] Session start() returned, state: \(session.state)")
                    return
                }

                print("[RayBan] Requesting camera permission (will open Meta AI)...")
                let result = try await wearables.requestPermission(.camera)
                print("[RayBan] Permission result: \(result)")
                if result == .granted {
                    print("[RayBan] Camera permission granted — starting session")
                    await session.start()
                    print("[RayBan] Session start() returned, state: \(session.state)")
                } else {
                    print("[RayBan] Camera permission denied by user")
                    self.connectionStatus = .error("Camera permission denied. Grant in Meta AI app.")
                }
            } catch {
                print("[RayBan] Permission error: \(error)")
                // Try starting anyway — Developer Mode may bypass permissions
                print("[RayBan] Attempting session start despite permission error...")
                await session.start()
                print("[RayBan] Fallback session start() returned, state: \(session.state)")
            }
        }
    }

    func stop() {
        Task { await streamSession?.stop() }
        stateToken = nil
        frameToken = nil
        errorToken = nil
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil
        streamSession = nil
        deviceSelector = nil
        isRunning = false
        connectionStatus = .disconnected
        latestFrame = nil
        latestImage = nil
        glassesName = "Not Connected"
        hasActiveDevice = false
    }

    func consumeFrame() -> Data? {
        return latestFrame
    }

    func cleanup() {
        stop()
        registrationTask?.cancel()
        registrationTask = nil
    }

    // MARK: - Error Formatting

    private func formatError(_ error: StreamSessionError) -> String {
        switch error {
        case .deviceNotFound: return "Glasses not found. Power on and open hinges."
        case .deviceNotConnected: return "Glasses disconnected. Check Bluetooth."
        case .permissionDenied: return "Camera permission denied. Grant in Meta AI app Settings."
        case .hingesClosed: return "Open the glasses hinges to stream."
        case .thermalCritical: return "Glasses overheating. Streaming paused."
        case .timeout: return "Connection timed out. Try again."
        case .videoStreamingError: return "Video stream failed. Restart app."
        case .internalError: return "Internal SDK error. Restart app."
        @unknown default: return "Unknown glasses error."
        }
    }
}
