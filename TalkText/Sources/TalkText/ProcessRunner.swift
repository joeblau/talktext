import Darwin
import Foundation

struct ProcessCommand: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]?
    let currentDirectoryURL: URL?

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }
}

enum CapturedProcessTerminationReason: String, Equatable, Sendable {
    case exit
    case uncaughtSignal
}

struct ProcessDiagnostic: Equatable, Sendable {
    let terminationStatus: Int32?
    let terminationReason: CapturedProcessTerminationReason?
    let standardOutput: Data
    let standardError: Data
    let launchErrorDomain: String?
    let launchErrorCode: Int?
    let launchErrorDescription: String?

    init(
        terminationStatus: Int32? = nil,
        terminationReason: CapturedProcessTerminationReason? = nil,
        standardOutput: Data = Data(),
        standardError: Data = Data(),
        launchErrorDomain: String? = nil,
        launchErrorCode: Int? = nil,
        launchErrorDescription: String? = nil
    ) {
        self.terminationStatus = terminationStatus
        self.terminationReason = terminationReason
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.launchErrorDomain = launchErrorDomain
        self.launchErrorCode = launchErrorCode
        self.launchErrorDescription = launchErrorDescription
    }

    var exitedSuccessfully: Bool {
        terminationReason == .exit && terminationStatus == 0
    }

    var standardOutputString: String? {
        String(data: standardOutput, encoding: .utf8)
    }

    var standardErrorString: String? {
        String(data: standardError, encoding: .utf8)
    }
}

enum ProcessRunResult: Equatable, Sendable {
    case completed(ProcessDiagnostic)
    case launchFailed(ProcessDiagnostic)
    case timedOut(ProcessDiagnostic)
    case cancelled(ProcessDiagnostic)

    var diagnostic: ProcessDiagnostic {
        switch self {
        case let .completed(diagnostic),
             let .launchFailed(diagnostic),
             let .timedOut(diagnostic),
             let .cancelled(diagnostic):
            diagnostic
        }
    }
}

protocol AsyncProcessRunning: Sendable {
    func run(_ command: ProcessCommand, timeout: TimeInterval) async -> ProcessRunResult
}

/// Runs one subprocess while continuously consuming both output pipes.
///
/// Cancellation and timeout first send SIGTERM. A still-running process is sent
/// SIGKILL after `terminationGracePeriod`, ensuring callers cannot wait forever
/// on a child that ignores polite termination.
final class FoundationProcessRunner: AsyncProcessRunning, @unchecked Sendable {
    private let terminationGracePeriod: TimeInterval

    init(terminationGracePeriod: TimeInterval = 0.5) {
        self.terminationGracePeriod = max(0, terminationGracePeriod)
    }

    func run(_ command: ProcessCommand, timeout: TimeInterval) async -> ProcessRunResult {
        let emptyDiagnostic = ProcessDiagnostic()

        guard !Task.isCancelled else {
            return .cancelled(emptyDiagnostic)
        }

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.currentDirectoryURL

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        let controller = ManagedProcess(
            process: process,
            terminationGracePeriod: terminationGracePeriod
        )
        process.terminationHandler = { terminatedProcess in
            controller.processDidTerminate(terminatedProcess)
        }

        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                controller.requestStop(.cancelled)
                return .cancelled(emptyDiagnostic)
            }

            do {
                try process.run()
                controller.processDidLaunch()
            } catch {
                let nsError = error as NSError
                let diagnostic = ProcessDiagnostic(
                    launchErrorDomain: nsError.domain,
                    launchErrorCode: nsError.code,
                    launchErrorDescription: String(describing: error)
                )
                return .launchFailed(diagnostic)
            }

            let outputTask = Task.detached(priority: .utility) {
                standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let errorTask = Task.detached(priority: .utility) {
                standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
            }

            let boundedTimeout = max(0.001, timeout)
            let timeoutTask = Task.detached(priority: .utility) {
                do {
                    try await Task.sleep(for: .seconds(boundedTimeout))
                    controller.requestStop(.timedOut)
                } catch {
                    // The process finished before the timeout.
                }
            }

            if Task.isCancelled {
                controller.requestStop(.cancelled)
            }

            let termination = await controller.waitForTermination()
            timeoutTask.cancel()
            let standardOutput = await outputTask.value
            let standardError = await errorTask.value

            let diagnostic = ProcessDiagnostic(
                terminationStatus: termination.status,
                terminationReason: termination.reason,
                standardOutput: standardOutput,
                standardError: standardError
            )

            switch termination.stopCause {
            case .none:
                return .completed(diagnostic)
            case .timedOut:
                return .timedOut(diagnostic)
            case .cancelled:
                return .cancelled(diagnostic)
            }
        } onCancel: {
            controller.requestStop(.cancelled)
        }
    }
}

private final class ManagedProcess: @unchecked Sendable {
    enum StopCause: Sendable {
        case timedOut
        case cancelled
    }

    struct Termination: Sendable {
        let status: Int32
        let reason: CapturedProcessTerminationReason
        let stopCause: StopCause?
    }

    private let process: Process
    private let terminationGracePeriod: TimeInterval
    private let lock = NSLock()
    private var launched = false
    private var stopCause: StopCause?
    private var termination: Termination?
    private var terminationWaiters: [CheckedContinuation<Termination, Never>] = []

    init(process: Process, terminationGracePeriod: TimeInterval) {
        self.process = process
        self.terminationGracePeriod = terminationGracePeriod
    }

    func processDidLaunch() {
        let pendingStop: StopCause?
        lock.lock()
        launched = true
        pendingStop = stopCause
        lock.unlock()

        if pendingStop != nil {
            signalTermination()
        }
    }

    func requestStop(_ cause: StopCause) {
        let shouldSignal: Bool
        lock.lock()
        if termination == nil, stopCause == nil {
            stopCause = cause
        }
        shouldSignal = launched && termination == nil
        lock.unlock()

        if shouldSignal {
            signalTermination()
        }
    }

    func processDidTerminate(_ process: Process) {
        let reason: CapturedProcessTerminationReason = switch process.terminationReason {
        case .exit: .exit
        case .uncaughtSignal: .uncaughtSignal
        @unknown default: .uncaughtSignal
        }

        let waiters: [CheckedContinuation<Termination, Never>]
        let result: Termination
        lock.lock()
        if termination != nil {
            lock.unlock()
            return
        }
        result = Termination(
            status: process.terminationStatus,
            reason: reason,
            stopCause: stopCause
        )
        termination = result
        waiters = terminationWaiters
        terminationWaiters.removeAll()
        lock.unlock()

        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    func waitForTermination() async -> Termination {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let termination {
                lock.unlock()
                continuation.resume(returning: termination)
            } else {
                terminationWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func signalTermination() {
        let processIdentifier = process.processIdentifier
        guard processIdentifier > 0 else {
            return
        }

        _ = Darwin.kill(processIdentifier, SIGTERM)

        let deadline = DispatchTime.now() + terminationGracePeriod
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak self] in
            self?.forceKillIfNeeded(processIdentifier: processIdentifier)
        }
    }

    private func forceKillIfNeeded(processIdentifier: pid_t) {
        lock.lock()
        let stillRunning = termination == nil
        lock.unlock()

        if stillRunning {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}
