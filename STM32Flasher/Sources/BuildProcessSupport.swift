import Foundation
import Darwin

enum ProcessStopReason: Equatable, Sendable {
    case cancelled
    case timedOut
}

enum FirmwareFlashValidator {
    static let flashStart: UInt64 = 0x0800_0000
    static let flashEndExclusive: UInt64 = 0x0801_0000

    static func binaryRangeIsValid(startAddress: UInt64, byteCount: Int64) -> Bool {
        guard startAddress >= flashStart,
              startAddress < flashEndExclusive,
              let unsignedCount = UInt64(exactly: byteCount),
              unsignedCount > 0
        else { return false }

        let (endAddress, overflowed) = startAddress.addingReportingOverflow(unsignedCount)
        return !overflowed && endAddress <= flashEndExclusive
    }
}

enum STM32ProgrammerOutputValidator {
    static func containsFailureEvidence(_ output: String) -> Bool {
        if output.range(
            of: #"\b(error|failed|failure)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        let lower = output.lowercased()
        return lower.contains("cannot connect")
            || lower.contains("connection failed")
            || lower.contains("no device found")
            || lower.contains("no st-link detected")
    }

    static func confirmsDownloadAndVerification(_ output: String) -> Bool {
        guard !containsFailureEvidence(output) else { return false }
        let lower = output.lowercased()
        let hasDownload = [
            "file download complete",
            "download complete",
            "programming complete",
            "download verified successfully"
        ].contains { lower.contains($0) }
        let hasVerification = [
            "download verified successfully",
            "verification...ok",
            "verification successful",
            "verification succeeded",
            "verify successful"
        ].contains { lower.contains($0) }
        return hasDownload && hasVerification
    }
}

enum STM32TargetOutputValidator {
    static func confirmsF103MediumDensity(_ output: String) -> Bool {
        guard !STM32ProgrammerOutputValidator.containsFailureEvidence(output) else {
            return false
        }
        let lower = output.lowercased()
        let reportsDeviceID410 = lower.range(
            of: #"device\s+id\s*:\s*0x0*410\b"#,
            options: .regularExpression
        ) != nil
        let reportsF103MediumDensity = lower.contains("stm32f103")
            && (lower.contains("medium-density") || lower.contains("medium density"))
        return reportsDeviceID410 || reportsF103MediumDensity
    }
}

/// Stores compiler output without allowing a multi-file build to grow memory
/// usage in proportion to the number of source files.
struct BoundedTextAccumulator: Sendable {
    let maximumCharacters: Int
    let truncationMarker: String
    private(set) var text = ""

    init(
        maximumCharacters: Int,
        truncationMarker: String = "[较早编译输出已自动清理，防止内存持续增长]\n"
    ) {
        self.maximumCharacters = max(0, maximumCharacters)
        self.truncationMarker = truncationMarker
    }

    mutating func append(_ addition: String) {
        guard maximumCharacters > 0, !addition.isEmpty else { return }

        let combined = text + addition
        guard combined.count > maximumCharacters else {
            text = combined
            return
        }

        let marker = String(truncationMarker.prefix(maximumCharacters))
        let available = max(0, maximumCharacters - marker.count)
        text = marker + String(combined.suffix(available))
    }
}

/// Owns one subprocess at a time. Launch and cancellation are linearized so a
/// cancellation observed before `Process.run()` prevents the process from ever
/// starting. Timeouts terminate, then force-kill after a short grace period.
final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var storedStopReason: ProcessStopReason?
    private var interruptIO: (@Sendable () -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .cancelled = storedStopReason { return true }
        return false
    }

    var stopReason: ProcessStopReason? {
        lock.lock()
        defer { lock.unlock() }
        return storedStopReason
    }

    func launch(
        _ newProcess: Process,
        timeout: TimeInterval = 0,
        forceTerminationGrace: TimeInterval = 2,
        interruptIO: @escaping @Sendable () -> Void = {}
    ) throws -> Bool {
        lock.lock()
        guard storedStopReason == nil else {
            lock.unlock()
            return false
        }
        process = newProcess
        self.interruptIO = interruptIO

        do {
            // Keep the lock until run returns so cancel either wins before the
            // launch or observes an already-running process.
            try newProcess.run()
        } catch {
            process = nil
            self.interruptIO = nil
            lock.unlock()
            throw error
        }
        lock.unlock()

        if timeout > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.requestTimeout(for: newProcess, forceTerminationGrace: forceTerminationGrace)
            }
        }
        return true
    }

    func finish(_ finishedProcess: Process) {
        lock.lock()
        if process === finishedProcess {
            process = nil
            interruptIO = nil
        }
        lock.unlock()
    }

    func cancel(forceTerminationGrace: TimeInterval = 2) {
        requestStop(.cancelled, expectedProcess: nil, forceTerminationGrace: forceTerminationGrace)
    }

    private func requestTimeout(
        for expectedProcess: Process,
        forceTerminationGrace: TimeInterval
    ) {
        requestStop(
            .timedOut,
            expectedProcess: expectedProcess,
            forceTerminationGrace: forceTerminationGrace
        )
    }

    private func requestStop(
        _ reason: ProcessStopReason,
        expectedProcess: Process?,
        forceTerminationGrace: TimeInterval
    ) {
        lock.lock()
        if let expectedProcess, process !== expectedProcess {
            lock.unlock()
            return
        }
        guard storedStopReason == nil else {
            lock.unlock()
            return
        }
        storedStopReason = reason
        let runningProcess = process
        let interruptIO = interruptIO
        lock.unlock()

        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0, forceTerminationGrace)
            ) {
                guard runningProcess.isRunning else { return }
                Darwin.kill(runningProcess.processIdentifier, SIGKILL)
            }
        }
        // A terminated parent can leave a descendant holding the pipe open.
        // Closing our read side guarantees the bounded reader can finish even
        // in that case; cancellation/timeout output is intentionally partial.
        interruptIO?()
    }
}

/// Compatibility name retained for focused process-safety tests and callers
/// that still describe this controller by its original compiler-only role.
typealias BuildProcessController = ProcessController
