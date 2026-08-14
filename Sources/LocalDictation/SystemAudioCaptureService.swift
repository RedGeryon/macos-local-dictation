@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import Foundation

enum SystemAudioCaptureError: LocalizedError {
    case permissionRequired
    case noDisplay
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Allow Local Dictation under System Audio Recording in System Settings, then try again."
        case .noDisplay:
            return "No Mac display is available for system-audio capture."
        case .invalidAudioFormat:
            return "The Mac speaker audio could not be converted for transcription."
        }
    }
}

/// Captures only the system-audio output selected by ScreenCaptureKit. No video
/// output is registered, and Local Dictation's own process audio is excluded.
final class SystemAudioCaptureService: NSObject, @unchecked Sendable {
    private final class ConverterInputState: @unchecked Sendable {
        var supplied = false
    }

    private final class ChannelState: @unchecked Sendable {
        var converter: AVAudioConverter?
        var targetFormat: AVAudioFormat?
        var accumulator = Data()
        var handler: (@Sendable (Data) -> Void)?

        func prepare(handler: @escaping @Sendable (Data) -> Void) {
            self.handler = handler
            accumulator = Data()
            converter = nil
            targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: AudioCaptureService.sampleRate,
                channels: 1,
                interleaved: true
            )
        }

        func reset() {
            accumulator = Data()
            converter = nil
            targetFormat = nil
            handler = nil
        }
    }

    private let processingQueue = DispatchQueue(label: "org.localdictation.system-audio")
    private var stream: SCStream?
    private let systemAudio = ChannelState()
    private let microphone = ChannelState()
    private var capturesMicrophone = false

    var onError: (@Sendable (Error) -> Void)?

    private(set) var isCapturing = false

    func start(
        onPCM: @escaping @Sendable (Data) -> Void,
        onMicrophonePCM: (@Sendable (Data) -> Void)? = nil
    ) async throws {
        guard !isCapturing else { return }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw Self.actionable(error)
        }
        let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first
        guard let display else { throw SystemAudioCaptureError.noDisplay }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(AudioCaptureService.sampleRate)
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)

        let useUnifiedMicrophone: Bool
        if #available(macOS 15.0, *), onMicrophonePCM != nil {
            configuration.captureMicrophone = true
            // A nil device ID means the current macOS default microphone. This
            // follows AirPods/device changes without overriding user settings.
            configuration.microphoneCaptureDeviceID = nil
            useUnifiedMicrophone = true
        } else {
            useUnifiedMicrophone = false
        }

        processingQueue.sync {
            self.systemAudio.prepare(handler: onPCM)
            if let onMicrophonePCM, useUnifiedMicrophone {
                self.microphone.prepare(handler: onMicrophonePCM)
            } else {
                self.microphone.reset()
            }
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
            if #available(macOS 15.0, *), useUnifiedMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: processingQueue)
            }
            try await stream.startCapture()
            self.stream = stream
            capturesMicrophone = useUnifiedMicrophone
            isCapturing = true
        } catch {
            try? stream.removeStreamOutput(self, type: .audio)
            if #available(macOS 15.0, *), useUnifiedMicrophone {
                try? stream.removeStreamOutput(self, type: .microphone)
            }
            processingQueue.sync { self.resetBuffers() }
            throw Self.actionable(error)
        }
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .audio)
        if #available(macOS 15.0, *), capturesMicrophone {
            try? stream.removeStreamOutput(self, type: .microphone)
        }
        self.stream = nil
        isCapturing = false
        capturesMicrophone = false
        processingQueue.sync { self.flushAndReset() }
    }

    func cancel() async {
        guard let stream else {
            processingQueue.sync { self.resetBuffers() }
            return
        }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .audio)
        if #available(macOS 15.0, *), capturesMicrophone {
            try? stream.removeStreamOutput(self, type: .microphone)
        }
        self.stream = nil
        isCapturing = false
        capturesMicrophone = false
        processingQueue.sync { self.resetBuffers() }
    }

    private func consume(_ sampleBuffer: CMSampleBuffer, channel: ChannelState) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let targetFormat = channel.targetFormat else { return }

        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        if channel.converter == nil || channel.converter?.inputFormat != sourceFormat {
            channel.converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter = channel.converter else { return }

        let maximumBuffers = max(1, Int(sourceFormat.channelCount))
        let bufferList = AudioBufferList.allocate(maximumBuffers: maximumBuffers)
        defer { free(bufferList.unsafeMutablePointer) }
        var retainedBlockBuffer: CMBlockBuffer?
        let bufferListSize = MemoryLayout<AudioBufferList>.size
            + max(0, maximumBuffers - 1) * MemoryLayout<AudioBuffer>.size
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        ) == noErr,
        let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            bufferListNoCopy: bufferList.unsafePointer,
            deallocator: nil
        ) else { return }
        input.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }
        let inputState = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if inputState.supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error,
              conversionError == nil,
              output.frameLength > 0,
              let bytes = output.audioBufferList.pointee.mBuffers.mData else { return }
        emit(
            Data(bytes: bytes, count: Int(output.frameLength) * MemoryLayout<Int16>.size),
            channel: channel
        )
    }

    private func emit(_ data: Data, channel: ChannelState) {
        let batchBytes = AudioCaptureService.transportBatchSamples * MemoryLayout<Int16>.size
        channel.accumulator.append(data)
        while channel.accumulator.count >= batchBytes {
            let batch = Data(channel.accumulator.prefix(batchBytes))
            channel.accumulator.removeFirst(batchBytes)
            channel.handler?(batch)
        }
    }

    private func flushAndReset() {
        let systemTail = systemAudio.accumulator
        let systemCallback = systemAudio.handler
        let microphoneTail = microphone.accumulator
        let microphoneCallback = microphone.handler
        resetBuffers()
        if !systemTail.isEmpty { systemCallback?(systemTail) }
        if !microphoneTail.isEmpty { microphoneCallback?(microphoneTail) }
    }

    private func resetBuffers() {
        // Assigning fresh storage avoids mutating a copy-on-write buffer that
        // may still be retained as the final tail while stopCapture drains its
        // last callback. That race previously crashed exactly when the user
        // pressed the conversation shortcut to stop and save.
        systemAudio.reset()
        microphone.reset()
    }

    private static func actionable(_ error: Error) -> Error {
        let cocoaError = error as NSError
        let permissionCodes = [
            SCStreamError.Code.userDeclined.rawValue,
            SCStreamError.Code.failedToStartAudioCapture.rawValue
        ]
        if cocoaError.domain == SCStreamErrorDomain,
           permissionCodes.contains(cocoaError.code) {
            return SystemAudioCaptureError.permissionRequired
        }
        return error
    }
}

extension SystemAudioCaptureService: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        switch outputType {
        case .audio:
            consume(sampleBuffer, channel: systemAudio)
        case .microphone:
            if #available(macOS 15.0, *) {
                consume(sampleBuffer, channel: microphone)
            }
        default:
            break
        }
    }
}

extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        isCapturing = false
        onError?(error)
    }
}
