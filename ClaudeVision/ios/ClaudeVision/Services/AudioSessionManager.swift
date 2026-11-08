import Foundation
import AVFoundation

class AudioSessionManager {
    static let shared = AudioSessionManager()
    private var glassesCameraStreaming = false

    private init() {
        setupNotifications()
    }

    /// Configure for voice chat with Bluetooth mic support (Meta Ray-Ban glasses)
    func configureForVoiceChat() throws {
        let session = AVAudioSession.sharedInstance()

        // .allowBluetooth = HFP (Hands-Free Profile) — enables Bluetooth MIC INPUT
        // .allowBluetoothA2DP = A2DP — high-quality Bluetooth OUTPUT only
        // Keep HFP disabled during DAT camera sessions; opening its route can stop
        // the glasses session. Speech then uses the iPhone's built-in microphone.
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        if !glassesCameraStreaming {
            options.insert(.allowBluetooth)
        }
        try session.setCategory(
            .playAndRecord,
            mode: glassesCameraStreaming ? .default : .voiceChat,
            options: options
        )
        try session.setActive(true)

        if glassesCameraStreaming {
            routeToBuiltInMic(session)
        } else {
            routeToBluetoothMicIfAvailable()
        }
    }

    /// Route audio input to Bluetooth mic (glasses) if available
    func routeToBluetoothMicIfAvailable() {
        guard !glassesCameraStreaming else {
            print("[Audio] Keeping iPhone mic while DAT camera session is active")
            return
        }
        let session = AVAudioSession.sharedInstance()
        guard let availableInputs = session.availableInputs else {
            print("[Audio] No available inputs found")
            return
        }

        // Log all available inputs for debugging
        for input in availableInputs {
            print("[Audio] Available input: \(input.portName) type=\(input.portType.rawValue) uid=\(input.uid)")
        }

        // Log current route
        let currentRoute = session.currentRoute
        for input in currentRoute.inputs {
            print("[Audio] Current input route: \(input.portName) type=\(input.portType.rawValue)")
        }
        for output in currentRoute.outputs {
            print("[Audio] Current output route: \(output.portName) type=\(output.portType.rawValue)")
        }

        // Priority order: HFP first (best for mic), then any Bluetooth input
        let bluetoothTypes: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
        for btType in bluetoothTypes {
            for input in availableInputs {
                if input.portType == btType {
                    do {
                        try session.setPreferredInput(input)
                        print("[Audio] ✅ Routed mic to Bluetooth: \(input.portName) (\(btType.rawValue))")
                        return
                    } catch {
                        print("[Audio] Failed to route to \(input.portName): \(error)")
                    }
                }
            }
        }

        // Also check for Ray-Ban by name as fallback
        for input in availableInputs {
            if input.portName.lowercased().contains("ray-ban") || input.portName.lowercased().contains("meta") {
                do {
                    try session.setPreferredInput(input)
                    print("[Audio] ✅ Routed mic to glasses by name: \(input.portName)")
                    return
                } catch {
                    print("[Audio] Failed to route to \(input.portName): \(error)")
                }
            }
        }

        print("[Audio] No Bluetooth mic found — using iPhone mic")
    }

    func setGlassesCameraStreaming(_ active: Bool) {
        guard glassesCameraStreaming != active else { return }
        glassesCameraStreaming = active
        if active {
            print("[Audio] Disabling Bluetooth HFP while DAT camera is active")
        } else {
            print("[Audio] Re-enabling Bluetooth HFP after DAT camera mode")
        }
        // Reapply the category first; selecting the built-in input before this
        // would still leave HFP enabled in AVAudioSession's active route options.
        try? configureForVoiceChat()
    }

    private func routeToBuiltInMic(_ session: AVAudioSession) {
        guard let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            print("[Audio] Built-in iPhone microphone is not available")
            return
        }
        do {
            try session.setPreferredInput(builtInMic)
            let hfpIsActive = session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
            if hfpIsActive {
                print("[Audio] ERROR: Bluetooth HFP is still active during the DAT camera session")
            } else {
                print("[Audio] Using iPhone microphone; Bluetooth HFP is inactive")
            }
        } catch {
            print("[Audio] Failed to select iPhone microphone: \(error.localizedDescription)")
        }
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        // Monitor audio route changes (glasses connect/disconnect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .newDeviceAvailable:
            // New Bluetooth device connected — try to route mic to it
            print("[Audio] New audio device connected")
            routeToBluetoothMicIfAvailable()
        case .oldDeviceUnavailable:
            print("[Audio] Audio device disconnected — falling back to iPhone mic")
        default:
            break
        }
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil)
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    try? configureForVoiceChat()
                    NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
                }
            }
        @unknown default:
            break
        }
    }
}

extension Notification.Name {
    static let audioInterruptionBegan = Notification.Name("audioInterruptionBegan")
    static let audioInterruptionEnded = Notification.Name("audioInterruptionEnded")
}
