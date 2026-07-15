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
    func terminateActiveProcesses()
}

extension AsyncProcessRunning {
    /// Synchronously terminates subprocesses owned by this runner. Implementations
    /// without persistent subprocess state have nothing to terminate.
    func terminateActiveProcesses() {}
}

/// Runs one subprocess while continuously consuming both output pipes.
///
/// Cancellation and timeout first send SIGTERM. A still-running process is sent
/// SIGKILL after `terminationGracePeriod`, ensuring callers cannot wait forever
/// on a child that ignores polite termination.
final class FoundationProcessRunner: AsyncProcessRunning, @unchecked Sendable {
    private let terminationGracePeriod: TimeInterval
    private let activeProcesses = ManagedProcessRegistry()

    init(terminationGracePeriod: TimeInterval = 0.5) {
        self.terminationGracePeriod = max(0, terminationGracePeriod)
    }

    /// Permanently closes this runner to new launches, force-kills every process
    /// already being launched or running, and waits for confirmed termination.
    /// This is reserved for synchronous application shutdown.
    func terminateActiveProcesses() {
        activeProcesses.terminateAllSynchronously()
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

        guard activeProcesses.register(controller) else {
            return .cancelled(emptyDiagnostic)
        }
        defer {
            activeProcesses.unregister(controller)
        }

        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                controller.requestStop(.cancelled)
                controller.processWillNotLaunch()
                return .cancelled(emptyDiagnostic)
            }

            do {
                try process.run()
                controller.processDidLaunch()
            } catch {
                controller.processWillNotLaunch()
                let nsError = error as NSError
                let diagnostic = ProcessDiagnostic(
                    launchErrorDomain: nsError.domain,
                    launchErrorCode: nsError.code,
                    launchErrorDescription: String(describing: error)
                )
                return .launchFailed(diagnostic)
            }

            let outputDrain = ProcessPipeDrain(
                fileHandle: standardOutputPipe.fileHandleForReading
            )
            let errorDrain = ProcessPipeDrain(
                fileHandle: standardErrorPipe.fileHandleForReading
            )
            let outputTask = Task.detached(priority: .utility) {
                outputDrain.drain()
            }
            let errorTask = Task.detached(priority: .utility) {
                errorDrain.drain()
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
            outputDrain.stopAfterProcessTermination()
            errorDrain.stopAfterProcessTermination()
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

private final class ManagedProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptsLaunches = true
    private var processes: [ObjectIdentifier: ManagedProcess] = [:]

    func register(_ process: ManagedProcess) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsLaunches else {
            return false
        }
        processes[ObjectIdentifier(process)] = process
        return true
    }

    func unregister(_ process: ManagedProcess) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func terminateAllSynchronously() {
        let activeProcesses: [ManagedProcess]
        lock.lock()
        acceptsLaunches = false
        activeProcesses = Array(processes.values)
        lock.unlock()

        for process in activeProcesses {
            process.terminateSynchronously()
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
    private let condition = NSCondition()
    private var launched = false
    private var launchFinishedWithoutProcess = false
    private var stopCause: StopCause?
    private var terminationSignalSent = false
    private var forceKillRequested = false
    private var forceKillSignalSent = false
    private var termination: Termination?
    private var terminationWaiters: [CheckedContinuation<Termination, Never>] = []

    init(process: Process, terminationGracePeriod: TimeInterval) {
        self.process = process
        self.terminationGracePeriod = terminationGracePeriod
    }

    func processDidLaunch() {
        let signal: Int32?
        let processIdentifier: pid_t
        condition.lock()
        launched = true
        processIdentifier = process.processIdentifier
        if forceKillRequested, termination == nil, !forceKillSignalSent {
            forceKillSignalSent = true
            signal = SIGKILL
        } else if stopCause != nil, termination == nil, !terminationSignalSent {
            terminationSignalSent = true
            signal = SIGTERM
        } else {
            signal = nil
        }
        condition.broadcast()
        condition.unlock()

        if let signal {
            send(signal, to: processIdentifier)
        }
    }

    func processWillNotLaunch() {
        condition.lock()
        launchFinishedWithoutProcess = true
        condition.broadcast()
        condition.unlock()
    }

    func requestStop(_ cause: StopCause) {
        let processIdentifier: pid_t?
        condition.lock()
        if termination == nil, stopCause == nil {
            stopCause = cause
        }
        if launched, termination == nil, !terminationSignalSent, !forceKillRequested {
            terminationSignalSent = true
            processIdentifier = process.processIdentifier
        } else {
            processIdentifier = nil
        }
        condition.unlock()

        if let processIdentifier {
            send(SIGTERM, to: processIdentifier)
        }
    }

    /// Force-kills a process even when launch is concurrently in progress, then
    /// blocks until Foundation has reaped it and delivered termination metadata.
    func terminateSynchronously() {
        let processIdentifier: pid_t?
        condition.lock()
        if termination == nil, stopCause == nil {
            stopCause = .cancelled
        }
        forceKillRequested = true
        if launched, termination == nil {
            forceKillSignalSent = true
            processIdentifier = process.processIdentifier
        } else {
            processIdentifier = nil
        }
        condition.unlock()

        if let processIdentifier {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }

        condition.lock()
        while termination == nil, !launchFinishedWithoutProcess {
            condition.wait()
        }
        condition.unlock()
    }

    func processDidTerminate(_ process: Process) {
        let reason: CapturedProcessTerminationReason = switch process.terminationReason {
        case .exit: .exit
        case .uncaughtSignal: .uncaughtSignal
        @unknown default: .uncaughtSignal
        }

        let waiters: [CheckedContinuation<Termination, Never>]
        let result: Termination
        condition.lock()
        if termination != nil {
            condition.unlock()
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
        condition.broadcast()
        condition.unlock()

        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    func waitForTermination() async -> Termination {
        await withCheckedContinuation { continuation in
            condition.lock()
            if let termination {
                condition.unlock()
                continuation.resume(returning: termination)
            } else {
                terminationWaiters.append(continuation)
                condition.unlock()
            }
        }
    }

    private func send(_ signal: Int32, to processIdentifier: pid_t) {
        guard processIdentifier > 0 else {
            return
        }

        _ = Darwin.kill(processIdentifier, signal)

        if signal == SIGTERM {
            let deadline = DispatchTime.now() + terminationGracePeriod
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak self] in
                self?.forceKillIfNeeded(processIdentifier: processIdentifier)
            }
        }
    }

    private func forceKillIfNeeded(processIdentifier: pid_t) {
        let shouldForceKill: Bool
        condition.lock()
        if termination == nil, launched, !forceKillSignalSent {
            forceKillSignalSent = true
            shouldForceKill = true
        } else {
            shouldForceKill = false
        }
        condition.unlock()

        if shouldForceKill {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}

/// Drains a subprocess pipe without requiring EOF after the direct child exits.
/// A descendant may inherit the write descriptor, so the final drain is bounded
/// to data already available when termination is confirmed.
private final class ProcessPipeDrain: @unchecked Sendable {
    private enum ReadResult {
        case unavailable
        case ended
        case bounded
    }

    private static let bufferSize = 64 * 1024
    private static let maximumFinalReadCount = 256

    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var shouldStop = false

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        let descriptor = fileHandle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    func stopAfterProcessTermination() {
        lock.lock()
        shouldStop = true
        lock.unlock()
    }

    func drain() -> Data {
        var data = Data()
        let descriptor = fileHandle.fileDescriptor
        defer {
            try? fileHandle.close()
        }

        while true {
            if stopRequested {
                _ = readAvailable(
                    from: descriptor,
                    into: &data,
                    maximumReadCount: Self.maximumFinalReadCount
                )
                return data
            }

            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(&pollDescriptor, 1, 50)
            if pollResult > 0 {
                let result = readAvailable(
                    from: descriptor,
                    into: &data,
                    maximumReadCount: Self.maximumFinalReadCount
                )
                if case .ended = result {
                    return data
                }
            } else if pollResult < 0, errno != EINTR {
                return data
            }
        }
    }

    private var stopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldStop
    }

    private func readAvailable(
        from descriptor: Int32,
        into data: inout Data,
        maximumReadCount: Int
    ) -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
        var readCount = 0

        while readCount < maximumReadCount {
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if byteCount > 0 {
                data.append(contentsOf: buffer.prefix(Int(byteCount)))
                readCount += 1
                continue
            }
            if byteCount == 0 {
                return .ended
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return .unavailable
            }
            return .ended
        }

        return .bounded
    }
}
