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
    @Published var compatibilityMessage: String?
    @Published var glassesAppUpdateRequired = false
    @Published var isOpeningGlassesAppUpdate = false
    @Published var isUnregisteringForReconnect = false

    // DAT SDK
    private var deviceSession: DeviceSession?
    private var camera: Camera?
    private var deviceSelector: AutoDeviceSelector?
    private var sessionStateToken: AnyListenerToken?
    private var sessionErrorToken: AnyListenerToken?
    private var streamStateToken: AnyListenerToken?
    private var frameToken: AnyListenerToken?
    private var errorToken: AnyListenerToken?
    private let videoFrameDecoder = GlassesVideoFrameDecoder()
    private var deviceMonitorTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var sessionSetupInProgress = false
    private var sessionGeneration = 0
    private var activeSessionGeneration: Int?
    private var sessionErrorMessage: String?

    private var frameInterval: TimeInterval = 1.0
    private var jpegQuality: CGFloat = 0.5
    private var lastCaptureTime: Date = .distantPast
    private var appIsActive = UIApplication.shared.applicationState == .active
    private var appLifecycleObservers: [NSObjectProtocol] = []

    // MARK: - Configuration

    func configure(frameInterval: TimeInterval = 1.0, jpegQuality: CGFloat = 0.5) {
        self.frameInterval = frameInterval
        self.jpegQuality = jpegQuality
        videoFrameDecoder.updateSettings(appIsActive: appIsActive, minimumImageInterval: frameInterval)
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
                    if !self.isUnregisteringForReconnect {
                        self.registrationMessage = nil
                    }
                    print("[RayBan] Registration complete")
                case .registering:
                    self.registrationState = "registering"
                    self.registrationMessage = self.isUnregisteringForReconnect
                        ? "Waiting for Meta AI to confirm disconnecting VisionClaude…"
                        : "Waiting for Meta AI approval…"
                    print("[RayBan] Registration in progress...")
                case .available:
                    self.registrationState = "available"
                    self.isRegistered = false
                    if self.isUnregisteringForReconnect {
                        self.isUnregisteringForReconnect = false
                        self.registrationMessage = "Registration reset. Tap Connect Glasses via Meta AI to register again."
                    }
                case .unavailable:
                    self.registrationState = "unavailable"
                    self.isRegistered = false
                    if self.isUnregisteringForReconnect {
                        self.isUnregisteringForReconnect = false
                        self.registrationMessage = "Meta AI reports DAT registration unavailable. Check its confirmation, then tap Connect Glasses via Meta AI."
                    } else {
                        self.registrationMessage = "DAT registration is unavailable. Check Meta AI and Developer Mode."
                    }
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

    func openGlassesAppUpdate() async {
        isOpeningGlassesAppUpdate = true
        defer { isOpeningGlassesAppUpdate = false }

        do {
            try await Wearables.shared.openDATGlassesAppUpdate()
            registrationMessage = "Meta AI opened. Follow its App Connections instructions to update the app on your glasses, then tap Connect again."
        } catch {
            registrationMessage = "Could not open the glasses app update in Meta AI: \(error.localizedDescription)"
        }
    }

    func reconnectMetaRegistration() async {
        guard isRegistered, !isUnregisteringForReconnect else { return }

        isUnregisteringForReconnect = true
        registrationMessage = "Waiting for Meta AI to confirm disconnecting VisionClaude…"

        do {
            try await Wearables.shared.startUnregistration()
            if isUnregisteringForReconnect {
                registrationMessage = "Confirm removing VisionClaude in Meta AI. Return here after Meta AI confirms."
            }
        } catch {
            isUnregisteringForReconnect = false
            registrationMessage = "Could not start the Meta AI registration reset: \(error.localizedDescription)"
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
        guard deviceMonitorTask == nil else { return }
        observeAppLifecycle()

        sessionGeneration += 1
        let generation = sessionGeneration

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

        // A session can only be created after DAT discovers a device.
        deviceMonitorTask = Task { @MainActor [weak self] in
            for await identifier in selector.activeDeviceStream() {
                guard let self else { return }
                guard self.sessionGeneration == generation else { return }
                guard let identifier else {
                    self.hasActiveDevice = false
                    self.glassesName = "No Device"
                    self.compatibilityMessage = nil
                    continue
                }
                guard let device = wearables.deviceForIdentifier(identifier) else { continue }
                self.hasActiveDevice = true
                self.glassesName = device.nameOrId()
                self.compatibilityMessage = device.compatibility().displayString
                print("[RayBan] Found \(device.nameOrId()), type \(device.deviceType()), compatibility \(device.compatibility())")
                await self.startSession(for: identifier, wearables: wearables, generation: generation)
            }
        }
    }

    private func startSession(for identifier: DeviceIdentifier, wearables: any WearablesInterface, generation: Int) async {
        guard deviceSession == nil, !sessionSetupInProgress else { return }
        sessionSetupInProgress = true
        defer {
            if sessionGeneration == generation {
                sessionSetupInProgress = false
            }
        }
        do {
            let permission = try await wearables.checkPermissionStatus(.camera)
            guard sessionGeneration == generation, deviceMonitorTask != nil else { return }
            if permission != .granted {
                registrationMessage = "Requesting camera permission in Meta AI…"
                let result = try await wearables.requestPermission(.camera)
                guard sessionGeneration == generation, deviceMonitorTask != nil else { return }
                guard result == .granted else {
                    connectionStatus = .error("Camera permission was not granted in Meta AI.")
                    return
                }
            }

            let session = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: identifier))
            deviceSession = session
            activeSessionGeneration = nil
            sessionErrorMessage = nil
            registrationMessage = nil

            sessionStateToken = session.statePublisher.listen { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.sessionGeneration == generation, self.deviceSession === session else { return }
                    print("[RayBan] Device session: \(state)")
                    if state == .started {
                        self.activeSessionGeneration = generation
                        self.addCamera(generation: generation)
                    } else if state == .stopped {
                        // A terminal session event may arrive before its matching
                        // error event. Let the error listener capture the cause first.
                        guard self.activeSessionGeneration == generation else {
                            print("[RayBan] Ignoring stopped state before session startup")
                            return
                        }
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(200))
                            guard let self,
                                  self.sessionGeneration == generation,
                                  self.deviceSession === session,
                                  self.activeSessionGeneration == generation else { return }
                            self.finishStoppedSession()
                        }
                    } else if state == .starting || state == .paused || state == .stopping {
                        self.activeSessionGeneration = generation
                        self.connectionStatus = .connecting
                    } else {
                        self.connectionStatus = .connecting
                    }
                }
            }
            sessionErrorToken = session.errorPublisher.listen { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.sessionGeneration == generation, self.deviceSession === session else { return }
                    self.sessionErrorMessage = error.localizedDescription
                    if error == .datAppOnTheGlassesUpdateRequired {
                        self.glassesAppUpdateRequired = true
                    }
                    self.connectionStatus = .error(error.localizedDescription)
                }
            }
            try session.start()
            if session.state == .started {
                activeSessionGeneration = generation
                addCamera(generation: generation)
            }
        } catch {
            let message = error.localizedDescription
            print("[RayBan] Device session failed: \(message)")
            if let sessionError = error as? DeviceSessionError,
               sessionError == .datAppOnTheGlassesUpdateRequired {
                glassesAppUpdateRequired = true
            }
            connectionStatus = .error(message)
        }
    }

    private func finishStoppedSession() {
        sessionGeneration += 1
        activeSessionGeneration = nil
        isRunning = false
        camera = nil
        deviceSession = nil
        sessionStateToken = nil
        sessionErrorToken = nil
        streamStateToken = nil
        frameToken = nil
        errorToken = nil
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil
        deviceSelector = nil

        if let reason = sessionErrorMessage {
            connectionStatus = .error("Glasses session stopped: \(reason)")
        } else {
            connectionStatus = .error("Glasses session stopped before video started. Check that the glasses are awake and close to the iPhone, then tap Connect to retry.")
        }
        sessionErrorMessage = nil
    }

    private func addCamera(generation: Int) {
        guard camera == nil else { return }
        guard let session = deviceSession else { return }
        do {
            let config = StreamConfiguration(videoCodec: .hvc1, audioCodec: nil, resolution: .high, frameRate: 30)
            guard let camera = try session.addCamera(config: config) else {
                connectionStatus = .error("Meta DAT did not provide a camera for this device.")
                return
            }
            self.camera = camera
            let frameDecoder = videoFrameDecoder
            streamStateToken = camera.stream.statePublisher.listen { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.sessionGeneration == generation else { return }
                    print("[RayBan] Camera stream: \(state)")
                    switch state {
                    case .streaming:
                        self.isRunning = true
                        self.connectionStatus = .connected
                    case .stopped, .stopping:
                        self.isRunning = false
                        self.connectionStatus = .connecting
                    case .waitingForDevice, .starting, .paused:
                        self.connectionStatus = .connecting
                    @unknown default:
                        break
                    }
                }
            }
            frameToken = camera.stream.videoFramePublisher.listen { [weak self] videoFrame in
                frameDecoder.decode(videoFrame.sampleBuffer) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionGeneration == generation else { return }
                        switch result {
                        case .success(let image):
                            guard let image else { return }
                            self.connectionStatus = .connected
                            self.latestImage = image
                            self.frameCount += 1
                            let now = Date()
                            if now.timeIntervalSince(self.lastCaptureTime) >= self.frameInterval {
                                self.lastCaptureTime = now
                                if let data = image.jpegData(compressionQuality: self.jpegQuality) {
                                    self.latestFrame = data
                                    print("[RayBan] Captured JPEG frame (\(data.count) bytes)")
                                }
                            }
                        case .failure(let error):
                            print("[RayBan] HEVC decode failed: \(error.localizedDescription)")
                            self.connectionStatus = .error("Glasses video decode failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
            errorToken = camera.stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.sessionGeneration == generation else { return }
                    let message = error.localizedDescription
                    print("[RayBan] Camera error: \(message)")
                    self.connectionStatus = .error(message)
                }
            }
            camera.stream.start()
        } catch {
            let message = error.localizedDescription
            print("[RayBan] Camera setup failed: \(message)")
            connectionStatus = .error(message)
        }
    }
    func stop() {
        sessionGeneration += 1
        activeSessionGeneration = nil
        sessionErrorMessage = nil
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil
        sessionSetupInProgress = false
        camera?.stop()
        deviceSession?.stop()
        videoFrameDecoder.reset()
        sessionStateToken = nil
        sessionErrorToken = nil
        streamStateToken = nil
        frameToken = nil
        errorToken = nil
        deviceSession = nil
        camera = nil
        deviceSelector = nil
        isRunning = false
        connectionStatus = .disconnected
        latestFrame = nil
        latestImage = nil
        glassesName = "Not Connected"
        hasActiveDevice = false
        removeAppLifecycleObservers()
    }

    func consumeFrame() -> Data? {
        return latestFrame
    }

    func cleanup() {
        stop()
        registrationTask?.cancel()
        registrationTask = nil
    }

    private func observeAppLifecycle() {
        guard appLifecycleObservers.isEmpty else { return }
        appIsActive = UIApplication.shared.applicationState == .active
        videoFrameDecoder.updateSettings(appIsActive: appIsActive, minimumImageInterval: frameInterval)
        let center = NotificationCenter.default
        appLifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appIsActive = false
                    self.videoFrameDecoder.updateSettings(appIsActive: false, minimumImageInterval: self.frameInterval)
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appIsActive = true
                    self.videoFrameDecoder.updateSettings(appIsActive: true, minimumImageInterval: self.frameInterval)
                }
            }
        ]
    }

    private func removeAppLifecycleObservers() {
        for observer in appLifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        appLifecycleObservers.removeAll()
    }

}
