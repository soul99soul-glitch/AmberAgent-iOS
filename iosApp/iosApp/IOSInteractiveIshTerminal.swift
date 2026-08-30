import Foundation
import Observation
#if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
import IshEmbed
#endif

struct IOSInteractiveIshTerminalSize: Equatable, Sendable {
    let rows: Int
    let columns: Int

    static let standard = IOSInteractiveIshTerminalSize(rows: 24, columns: 80)
}

enum IOSInteractiveIshTerminalState: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case stopped
    case exited(exitCode: Int32, signal: Int32)
    case failed(String)

    var acceptsInput: Bool {
        self == .running
    }

    var canStart: Bool {
        switch self {
        case .idle, .stopped, .exited, .failed:
            true
        case .starting, .running, .stopping:
            false
        }
    }

    var hasStopped: Bool {
        switch self {
        case .idle, .stopped, .exited, .failed:
            true
        case .starting, .running, .stopping:
            false
        }
    }
}

enum IOSInteractiveIshTerminalKey: Sendable {
    case enter
    case tab
    case backspace
    case escape
    case up
    case down
    case left
    case right
}

/// Foreground owner for one human-operated iSH PTY. This deliberately does
/// not implement the Agent executor contract: there is no tool approval,
/// structured stdout/stderr result, timeout, persistence, or recovery.
@MainActor
@Observable
final class IOSInteractiveIshTerminalModel {
    private(set) var state: IOSInteractiveIshTerminalState = .idle
    private(set) var screenText = ""
    private(set) var screenGeneration: UInt64 = 0
    private(set) var terminalSize = IOSInteractiveIshTerminalSize.standard
    private(set) var inputError: String?

    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var stopEscalationTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var sessionCleanupTask: Task<Void, Never>?
    #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
    @ObservationIgnored private var terminal: IshTerminal?
    #endif

    deinit {
        startTask?.cancel()
        stopEscalationTask?.cancel()
        snapshotRefreshTask?.cancel()
        sessionCleanupTask?.cancel()
        #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
        if let terminal {
            try? terminal.terminate()
            Task.detached { [terminal] in
                try? await Task.sleep(for: .milliseconds(2_200))
                try? terminal.signalDirect(9)
            }
        }
        #endif
    }

    func start() {
        guard state.canStart else { return }
        inputError = nil
        screenText = ""
        screenGeneration = 0
        stopEscalationTask?.cancel()
        snapshotRefreshTask?.cancel()
        sessionCleanupTask?.cancel()

        #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
        // A terminal in a restartable state has already delivered its final
        // pump event, so releasing it here cannot race the blocking read.
        terminal?.close()
        terminal = nil
        state = .starting
        let requestedSize = terminalSize
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let startedTerminal = try await IOSEmbeddedIshRuntime.shared.startInteractiveTerminal(
                    rows: requestedSize.rows,
                    columns: requestedSize.columns
                )
                self.attach(startedTerminal)
                if Task.isCancelled {
                    self.state = .stopping
                    self.terminate(startedTerminal)
                } else {
                    self.state = .running
                }
            } catch is CancellationError {
                self.state = .stopped
            } catch {
                self.state = .failed(error.localizedDescription)
            }
            self.startTask = nil
        }
        #else
        state = .failed(IOSEmbeddedIshRuntimeError.notLinked.localizedDescription)
        #endif
    }

    func stop() {
        inputError = nil
        switch state {
        case .starting:
            state = .stopping
            startTask?.cancel()
        case .running:
            state = .stopping
            #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
            if let terminal {
                terminate(terminal)
            }
            #endif
        case .idle:
            state = .stopped
        case .stopping, .stopped, .exited, .failed:
            break
        }
    }

    func resize(rows: Int, columns: Int) {
        let size = IOSInteractiveIshTerminalSize(
            rows: max(8, min(rows, 100)),
            columns: max(20, min(columns, 240))
        )
        guard size != terminalSize else { return }
        terminalSize = size
        #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
        if state == .running {
            terminal?.resize(IshTerminal.Size(rows: size.rows, cols: size.columns))
        }
        #endif
    }

    func sendText(_ text: String) {
        guard state.acceptsInput else { return }
        #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
        guard let terminal else { return }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var keys: [IshKey] = []
        var textBuffer = ""
        for character in normalized {
            if character == "\n" || character == "\r" {
                if !textBuffer.isEmpty {
                    keys.append(.text(textBuffer))
                    textBuffer = ""
                }
                keys.append(.enter)
            } else {
                textBuffer.append(character)
            }
        }
        if !textBuffer.isEmpty {
            keys.append(.text(textBuffer))
        }
        send(keys, through: terminal)
        #endif
    }

    func sendKey(_ key: IOSInteractiveIshTerminalKey) {
        guard state.acceptsInput else { return }
        #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
        guard let terminal else { return }
        let ishKey: IshKey = switch key {
        case .enter: .enter
        case .tab: .tab
        case .backspace: .backspace
        case .escape: .escape
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
        send([ishKey], through: terminal)
        #endif
    }

    func interrupt() {
        guard state.acceptsInput else { return }
        #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
        do {
            try terminal?.interrupt()
            inputError = nil
        } catch {
            inputError = "Ctrl-C 发送失败：\(error.localizedDescription)"
        }
        #endif
    }

    #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
    private func attach(_ startedTerminal: IshTerminal) {
        terminal = startedTerminal
        startedTerminal.setEventHandler(queue: .main) { [weak self, weak startedTerminal] event in
            guard let startedTerminal else { return }
            if case .streamData = event {
                return
            }
            MainActor.assumeIsolated { [weak self] in
                self?.handle(event, from: startedTerminal)
            }
        }
        if startedTerminal.size.rows != terminalSize.rows
            || startedTerminal.size.cols != terminalSize.columns {
            startedTerminal.resize(
                IshTerminal.Size(rows: terminalSize.rows, cols: terminalSize.columns)
            )
        }
        updateSnapshot(from: startedTerminal)
    }

    private func handle(_ event: IshTerminal.Event, from eventTerminal: IshTerminal) {
        guard terminal === eventTerminal else { return }
        switch event {
        case .screenUpdate:
            scheduleSnapshotRefresh(from: eventTerminal)
        case .streamData:
            break
        case .exited(let exitCode, let signal):
            finishSession(
                eventTerminal,
                finalState: .exited(exitCode: exitCode, signal: signal)
            )
        case .error(let error):
            inputError = error.localizedDescription
            finishSession(eventTerminal, finalState: .failed(error.localizedDescription))
        }
    }

    private func scheduleSnapshotRefresh(from eventTerminal: IshTerminal) {
        guard snapshotRefreshTask == nil else { return }
        snapshotRefreshTask = Task { @MainActor [weak self, weak eventTerminal] in
            await Task.yield()
            guard let self else { return }
            defer { self.snapshotRefreshTask = nil }
            guard let eventTerminal, self.terminal === eventTerminal else { return }
            self.updateSnapshot(from: eventTerminal)
        }
    }

    private func finishSession(
        _ eventTerminal: IshTerminal,
        finalState: IOSInteractiveIshTerminalState
    ) {
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = nil
        stopEscalationTask?.cancel()
        stopEscalationTask = nil
        updateSnapshot(from: eventTerminal)
        state = .stopping
        startTask = nil
        sessionCleanupTask?.cancel()
        sessionCleanupTask = Task { @MainActor [weak self, weak eventTerminal] in
            // IshTerminal dispatches the final event just before its pump
            // returns. Let that callback unwind before closing the host
            // session so close never races a blocking read.
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, let eventTerminal, self.terminal === eventTerminal else { return }
            await Task.detached(priority: .utility) {
                eventTerminal.close()
            }.value
            guard self.terminal === eventTerminal else { return }
            self.terminal = nil
            self.sessionCleanupTask = nil
            self.state = finalState
        }
    }

    private func updateSnapshot(from terminal: IshTerminal) {
        let snapshot = terminal.snapshot()
        screenText = Self.renderedText(from: snapshot)
        screenGeneration = snapshot.generation
    }

    private static func renderedText(from snapshot: IshTerminalSnapshot) -> String {
        var lines: [String] = []
        lines.reserveCapacity(snapshot.scrollback.count + snapshot.screen.count)

        func appendRow(_ cells: [VTCell], cursorColumn: Int?) {
            var line = ""
            line.reserveCapacity(cells.count)
            for (column, cell) in cells.enumerated() {
                if column == cursorColumn {
                    line.append("▌")
                } else if cell.scalar >= 0x20, let scalar = Unicode.Scalar(cell.scalar) {
                    line.append(Character(scalar))
                } else {
                    line.append(" ")
                }
            }
            while line.last == " " {
                line.removeLast()
            }
            lines.append(line)
        }

        for row in snapshot.scrollback {
            appendRow(row, cursorColumn: nil)
        }
        for (rowIndex, row) in snapshot.screen.enumerated() {
            let cursorColumn = snapshot.cursorVisible && rowIndex == snapshot.cursorRow
                ? snapshot.cursorCol
                : nil
            appendRow(row, cursorColumn: cursorColumn)
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private func send(_ keys: [IshKey], through terminal: IshTerminal) {
        guard !keys.isEmpty else { return }
        do {
            try terminal.send(keys)
            inputError = nil
        } catch {
            inputError = "终端输入失败：\(error.localizedDescription)"
        }
    }

    private func terminate(_ terminal: IshTerminal) {
        do {
            try terminal.terminate()
            stopEscalationTask?.cancel()
            stopEscalationTask = Task { @MainActor [weak self, weak terminal] in
                // The package first kills the foreground process group. If a
                // child owned the TTY, the interactive shell can survive and
                // regain the foreground after that grace. Kill the now-
                // foreground shell so the session always reaches EXITED.
                try? await Task.sleep(for: .milliseconds(2_200))
                guard let self,
                      let terminal,
                      self.terminal === terminal,
                      self.state == .stopping,
                      !Task.isCancelled else { return }
                do {
                    try terminal.signalDirect(9)
                } catch {
                    self.inputError = "终端强制停止失败：\(error.localizedDescription)"
                }
            }
        } catch {
            // Keep the session owned and non-restartable until the pump emits
            // its terminal event; closing it here could race a blocking read.
            state = .running
            inputError = "终端停止失败：\(error.localizedDescription)"
        }
    }
    #endif
}
