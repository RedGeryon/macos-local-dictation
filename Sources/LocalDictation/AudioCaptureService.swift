@preconcurrency import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError {
    case microphoneUnavailable
    case formatConversionFailed

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: return "No usable microphone input is available."
        case .formatConversionFailed: return "Microphone audio could not be converted for transcription."
        }
    }
}

/// Captures at the hardware cadence, converts to mono 16 kHz PCM16, and emits
/// 80 ms transport batches. NeMo retains its own 160 ms inference state.
final class AudioCaptureService: @unchecked Sendable {
    private final class ConverterInputState: @unchecked Sendable {
        var supplied = false
    }

    static let sampleRate = 16_000.0
    static let transportBatchSamples = 1_280 // 80 ms

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let callbackCondition = NSCondition()
    private var converter: AVAudioConverter?
    private var accumulator = Data()
    private var handler: ((Data) -> Void)?
    private var callbacksInFlight = 0
    private var acceptingCallbacks = false
    private(set) var isCapturing = false

    func start(onPCM: @escaping (Data) -> Void) throws {
        guard !isCapturing else { return }
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioCaptureError.microphoneUnavailable
        }

        self.converter = converter
        self.handler = onPCM
        accumulator.removeAll(keepingCapacity: true)
        callbackCondition.lock()
        acceptingCallbacks = true
        callbacksInFlight = 0
        callbackCondition.unlock()

        input.installTap(onBus: 0, bufferSize: 512, format: sourceFormat) { [weak self] buffer, _ in
            guard let self, self.beginCallback() else { return }
            defer { self.endCallback() }
            self.consume(buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
            isCapturing = true
        } catch {
            input.removeTap(onBus: 0)
            stopAcceptingCallbacksAndWait()
            self.converter = nil
            self.handler = nil
            throw error
        }
    }

    /// Stops capture and synchronously emits the final sub-80 ms tail before
    /// returning, allowing the caller to queue commit after every audio byte.
    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        stopAcceptingCallbacksAndWait()

        lock.lock()
        let tail = accumulator
        accumulator.removeAll(keepingCapacity: true)
        let callback = handler
        handler = nil
        lock.unlock()

        if !tail.isEmpty { callback?(tail) }
        converter = nil
    }

    func cancel() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        stopAcceptingCallbacksAndWait()
        lock.lock()
        accumulator.removeAll(keepingCapacity: true)
        handler = nil
        lock.unlock()
        converter = nil
    }

    private func beginCallback() -> Bool {
        callbackCondition.lock()
        defer { callbackCondition.unlock() }
        guard acceptingCallbacks else { return false }
        callbacksInFlight += 1
        return true
    }

    private func endCallback() {
        callbackCondition.lock()
        callbacksInFlight -= 1
        if callbacksInFlight == 0 { callbackCondition.broadcast() }
        callbackCondition.unlock()
    }

    private func stopAcceptingCallbacksAndWait() {
        callbackCondition.lock()
        acceptingCallbacks = false
        while callbacksInFlight > 0 { callbackCondition.wait() }
        callbackCondition.unlock()
    }

    private func consume(
        _ input: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
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
              let bytes = output.audioBufferList.pointee.mBuffers.mData else {
            return
        }

        let data = Data(bytes: bytes, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        let batchBytes = Self.transportBatchSamples * MemoryLayout<Int16>.size

        lock.lock()
        accumulator.append(data)
        var batches: [Data] = []
        while accumulator.count >= batchBytes {
            batches.append(Data(accumulator.prefix(batchBytes)))
            accumulator.removeFirst(batchBytes)
        }
        let callback = handler
        lock.unlock()

        for batch in batches { callback?(batch) }
    }
}
