import Foundation

struct ProcessResult: Sendable {
    let stdout: Data
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }

    /// First non-empty line of stderr — ffmpeg/ffprobe put the real reason there.
    var firstErrorLine: String {
        stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

enum ProcessError: LocalizedError {
    case launchFailed(tool: String, reason: String)
    case timedOut(tool: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let tool, let reason): return "Could not run \(tool): \(reason)"
        case .timedOut(let tool): return "\(tool) did not finish in time and was stopped."
        }
    }
}

/// Runs a command-line helper and collects both output streams.
///
/// Both pipes are drained on their own queues on purpose: ffmpeg writes image bytes
/// to stdout and diagnostics to stderr, and letting either pipe buffer fill would
/// deadlock the child process.
enum ProcessRunner {

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 120
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let state = ProcessState(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        guard try state.launch() else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                    } catch {
                        continuation.resume(throwing: ProcessError.launchFailed(
                            tool: executable.lastPathComponent,
                            reason: error.localizedDescription
                        ))
                        return
                    }

                    let watchdog = DispatchWorkItem { state.stop(reason: .timedOut) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                    let output = OutputBuffer()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        output.setStandardOutput(outPipe.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        output.setStandardError(errPipe.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }
                    group.wait()
                    process.waitUntilExit()
                    watchdog.cancel()

                    switch state.stopReason {
                    case .timedOut:
                        continuation.resume(throwing: ProcessError.timedOut(tool: executable.lastPathComponent))
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .none:
                        continuation.resume(returning: ProcessResult(
                            stdout: output.standardOutput,
                            stderr: String(decoding: output.standardError, as: UTF8.self),
                            exitCode: process.terminationStatus
                        ))
                    }
                }
            }
        } onCancel: {
            state.stop(reason: .cancelled)
        }
    }
}

/// Guards the launch/terminate race: `onCancel` can fire before, during or after
/// `Process.run()`, and terminating a process that was never launched traps.
private final class ProcessState: @unchecked Sendable {
    enum StopReason { case none, cancelled, timedOut }

    private let lock = NSLock()
    private let process: Process
    private var isLaunched = false
    private var reason: StopReason = .none

    init(process: Process) {
        self.process = process
    }

    var stopReason: StopReason {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }

    /// Returns false when the task was cancelled before the process started.
    func launch() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard reason == .none else { return false }
        try process.run()
        isLaunched = true
        return true
    }

    func stop(reason newReason: StopReason) {
        lock.lock()
        defer { lock.unlock() }
        if reason == .none { reason = newReason }
        if isLaunched && process.isRunning { process.terminate() }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    var standardOutput: Data {
        lock.lock()
        defer { lock.unlock() }
        return out
    }

    var standardError: Data {
        lock.lock()
        defer { lock.unlock() }
        return err
    }

    func setStandardOutput(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        out = data
    }

    func setStandardError(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        err = data
    }
}
