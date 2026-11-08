import AVFoundation
import CoreImage
import CoreMedia
import UIKit
import VideoToolbox

/// Decodes Meta DAT's compressed HEVC frames on a single background worker.
/// At most one frame is queued or decoding; frames that arrive while busy are
/// dropped and decoding resumes at the next keyframe to avoid growing latency.
final class GlassesVideoFrameDecoder {
    private let queue = DispatchQueue(label: "com.claudevision.glasses-video-decoder", qos: .utility)
    private let lock = NSLock()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: true])

    private var isBusy = false
    private var frameWasDropped = false
    private var appIsActive = true
    private var minimumImageInterval: TimeInterval = 1.0
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var awaitingKeyframe = true
    private var lastRenderedAt = Date.distantPast
    private var consecutiveFailures = 0

    func updateSettings(appIsActive: Bool, minimumImageInterval: TimeInterval) {
        lock.lock()
        self.appIsActive = appIsActive
        self.minimumImageInterval = minimumImageInterval
        lock.unlock()
    }

    func decode(_ sampleBuffer: CMSampleBuffer,
                completion: @escaping (Result<UIImage?, Error>) -> Void) {
        lock.lock()
        guard !isBusy else {
            frameWasDropped = true
            lock.unlock()
            return
        }
        isBusy = true
        let hadDroppedFrame = frameWasDropped
        let renderEveryFrame = appIsActive
        let imageInterval = minimumImageInterval
        frameWasDropped = false
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.isBusy = false
                self.lock.unlock()
            }

            do {
                if hadDroppedFrame {
                    self.awaitingKeyframe = true
                }
                let now = Date()
                let shouldRender = renderEveryFrame || now.timeIntervalSince(self.lastRenderedAt) >= imageInterval
                let image = try self.decodeSynchronously(sampleBuffer, makeImage: shouldRender)
                if image != nil {
                    self.lastRenderedAt = now
                }
                if image != nil || shouldRender {
                    completion(.success(image))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    func reset() {
        lock.lock()
        frameWasDropped = false
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            if let session = self.session {
                VTDecompressionSessionInvalidate(session)
            }
            self.session = nil
            self.formatDescription = nil
            self.awaitingKeyframe = true
            self.lastRenderedAt = .distantPast
            self.consecutiveFailures = 0
        }
    }

    private func decodeSynchronously(_ sampleBuffer: CMSampleBuffer, makeImage: Bool) throws -> UIImage? {
        guard CMSampleBufferGetDataBuffer(sampleBuffer) != nil,
              let incomingFormat = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw DecodeError.invalidFrame
        }

        if let currentFormat = formatDescription,
           let session,
           !CMFormatDescriptionEqual(currentFormat, otherFormatDescription: incomingFormat) {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            formatDescription = nil
            awaitingKeyframe = true
            consecutiveFailures = 0
        }

        if let session,
           !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: incomingFormat) {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            formatDescription = nil
            awaitingKeyframe = true
            consecutiveFailures = 0
        }

        if session == nil {
            let decoderSpecification = [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: false
            ] as CFDictionary
            let outputAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
            ]
            var newSession: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: incomingFormat,
                decoderSpecification: decoderSpecification,
                imageBufferAttributes: outputAttributes as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &newSession
            )
            guard status == noErr, let newSession else {
                throw DecodeError.sessionCreation(status)
            }
            session = newSession
            formatDescription = incomingFormat
            awaitingKeyframe = true
        }

        let isKeyframe = sampleBuffer.isHEVCKeyframe
        if awaitingKeyframe && !isKeyframe {
            return nil
        }
        guard let session else { throw DecodeError.sessionUnavailable }

        nonisolated(unsafe) var outputPixelBuffer: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: nil
        ) { decodeStatus, _, imageBuffer, _, _ in
            if decodeStatus == noErr {
                outputPixelBuffer = imageBuffer
            }
        }
        guard status == noErr else {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
                formatDescription = nil
                awaitingKeyframe = true
                consecutiveFailures = 0
            }
            throw DecodeError.frameDecode(status)
        }

        consecutiveFailures = 0
        if isKeyframe {
            awaitingKeyframe = false
        }
        guard makeImage, let pixelBuffer = outputPixelBuffer else { return nil }

        let bounds = CGRect(x: 0, y: 0,
                            width: CVPixelBufferGetWidth(pixelBuffer),
                            height: CVPixelBufferGetHeight(pixelBuffer))
        guard let cgImage = ciContext.createCGImage(CIImage(cvPixelBuffer: pixelBuffer), from: bounds) else {
            throw DecodeError.imageConversion
        }
        return UIImage(cgImage: cgImage)
    }
}

private enum DecodeError: LocalizedError {
    case invalidFrame
    case sessionCreation(OSStatus)
    case sessionUnavailable
    case frameDecode(OSStatus)
    case imageConversion

    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "DAT provided an HEVC frame without compressed video data."
        case .sessionCreation(let status): return "Could not create the software HEVC decoder (VideoToolbox status \(status))."
        case .sessionUnavailable: return "The software HEVC decoder is unavailable."
        case .frameDecode(let status): return "Software HEVC frame decoding failed (VideoToolbox status \(status))."
        case .imageConversion: return "Could not convert a decoded glasses frame to an image."
        }
    }
}

private extension CMSampleBuffer {
    var isHEVCKeyframe: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return false
        }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}
