import Darwin
import Foundation
import OSLog

struct SpeechServerLaunchPlan: Equatable, Sendable {
    let executableURL: URL
    let modelURL: URL
    let host: String
    let port: Int

    var arguments: [String] {
        [
            "serve",
            "--asr-model", modelURL.path,
            "--asr.streaming.rnnt_right_context", "1",
            "--endpointing",
            "--host", host,
            "--port", String(port)
        ]
    }

    var readyURL: URL {
        URL(string: "http://\(host):\(port)/ready")!
    }

    var playgroundURL: URL {
        URL(string: "http://\(host):\(port)/")!
    }

    var realtimeURL: URL {
        URL(string: "ws://\(host):\(port)/v1/realtime")!
    }
}

enum SpeechServerError: LocalizedError {
    case alreadyRunning
    case launchFailed(String)
    case exitedBeforeReady(Int32)
    case readinessTimedOut

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "The speech engine is already running."
        case .launchFailed(let detail):
            return "The speech engine could not start: \(detail)"
        case .exitedBeforeReady(let code):
            return "The speech engine exited before becoming ready (code \(code))."
        case .readinessTimedOut:
            return "The speech model took too long to load."
        }
    }
}

@MainActor
final class SpeechServerManager {
    typealias StateHandler = @MainActor (AppState) -> Void

    private let logger = Logger(subsystem: "org.localdictation.app", category: "SpeechServer")
    private let session: URLSession
    private var process: Process?
    private var launchPlan: SpeechServerLaunchPlan?
    private var intentionalStop = false
    private var automaticRestartUsed = false

    var onStateChange: StateHandler?

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    var processIdentifier: Int32? {
        process?.isRunning == true ? process?.processIdentifier : nil
    }

    var playgroundURL: URL? {
        launchPlan?.playgroundURL
    }

    var realtimeURL: URL? {
        launchPlan?.realtimeURL
    }

    func start(configuration: AppConfiguration, port: Int? = nil) async throws {
        guard !isRunning else { throw SpeechServerError.alreadyRunning }

        intentionalStop = false
        onStateChange?(.loadingModel)
        let selectedPort = port ?? Self.availablePort(in: 17_866...17_885)
        let plan = SpeechServerLaunchPlan(
            executableURL: configuration.engineURL,
            modelURL: configuration.modelURL,
            host: "127.0.0.1",
            port: selectedPort
        )

        let child = Process()
        child.executableURL = plan.executableURL
        child.arguments = plan.arguments
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.environment = ProcessInfo.processInfo.environment.merging([
            "LOCAL_DICTATION_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier)
        ]) { _, appValue in appValue }

        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                self?.handleTermination(status: terminated.terminationStatus)
            }
        }

        do {
            try child.run()
        } catch {
            onStateChange?(.serverUnavailable(error.localizedDescription))
            throw SpeechServerError.launchFailed(error.localizedDescription)
        }

        process = child
        launchPlan = plan
        logger.info("SPEECH_SERVER_STARTED pid=\(child.processIdentifier, privacy: .public) port=\(selectedPort, privacy: .public)")

        do {
            try await waitUntilReady(plan: plan, child: child)
            automaticRestartUsed = false
            onStateChange?(.ready)
            logger.info("SPEECH_SERVER_READY pid=\(child.processIdentifier, privacy: .public)")
        } catch {
            await stop()
            onStateChange?(.serverUnavailable(error.localizedDescription))
            throw error
        }
    }

    func restart(configuration: AppConfiguration) async throws {
        await stop()
        try await start(configuration: configuration)
    }

    func stop(graceNanoseconds: UInt64 = 2_000_000_000) async {
        guard let child = process else { return }
        intentionalStop = true
        if child.isRunning {
            child.terminate()
            let deadline = ContinuousClock.now + .nanoseconds(Int64(graceNanoseconds))
            while child.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if child.isRunning {
                logger.warning("SPEECH_SERVER_FORCE_TERMINATE pid=\(child.processIdentifier, privacy: .public)")
                Darwin.kill(child.processIdentifier, SIGKILL)
                for _ in 0..<20 where child.isRunning {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }
        logger.info("SPEECH_SERVER_STOPPED")
        process = nil
        launchPlan = nil
    }

    private func waitUntilReady(plan: SpeechServerLaunchPlan, child: Process) async throws {
        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard child.isRunning else {
                throw SpeechServerError.exitedBeforeReady(child.terminationStatus)
            }
            var request = URLRequest(url: plan.readyURL)
            request.timeoutInterval = 1
            if let (data, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["ready"] as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SpeechServerError.readinessTimedOut
    }

    private func handleTermination(status: Int32) {
        let wasIntentional = intentionalStop
        process = nil
        launchPlan = nil
        guard !wasIntentional else { return }
        logger.error("SPEECH_SERVER_UNEXPECTED_EXIT code=\(status, privacy: .public)")
        onStateChange?(.serverUnavailable("Speech engine stopped unexpectedly (code \(status))."))
    }

    static func availablePort(in range: ClosedRange<Int>) -> Int {
        for port in range where canBind(port: port) {
            return port
        }
        return range.lowerBound
    }

    private static func canBind(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
