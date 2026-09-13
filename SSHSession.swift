import Foundation
import UIKit
import Citadel
import NIOCore
import NIOSSH

@MainActor
final class SSHSession: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var terminalText = ""
    @Published private(set) var outputRevision = 0
    @Published private(set) var statusText = "未连接"

    private var client: SSHClient?
    private var activeWriter: TTYStdinWriter?
    private var connectionTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pendingOutput = ""
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var disconnectRequested = false

    let host: String
    let port: Int
    let username: String
    let password: String

    private let maxStoredLines = 12000

    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    deinit {
        connectionTask?.cancel()
        flushTask?.cancel()
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
        }
    }

    func connect() {
        guard !isConnected, connectionTask == nil else { return }
        disconnectRequested = false
        statusText = "正在连接…"
        appendLocalMessage("\n[正在连接 \(host):\(port)…]\n")

        let host = self.host
        let port = self.port
        let username = self.username
        let password = self.password

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await SSHClient.connect(
                    host: host,
                    port: port,
                    authenticationMethod: .passwordBased(
                        username: username,
                        password: password
                    ),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )

                try Task.checkCancellation()
                self.client = client
                try await self.runPTY(client: client)
            } catch is CancellationError {
                if !self.disconnectRequested {
                    self.finishConnection(message: "连接已取消")
                }
            } catch {
                self.finishConnection(message: "连接失败：\(error.localizedDescription)")
            }
            self.connectionTask = nil
        }
    }

    private func runPTY(client: SSHClient) async throws {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 100,
            terminalRowHeight: 40,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1])
        )

        try await client.withPTY(pty) { [weak self] stream, writer in
            guard let self else { return }

            self.activeWriter = writer
            self.isConnected = true
            self.statusText = "已连接"
            self.appendLocalMessage("[SSH 已连接]\n")

            do {
                try await self.writeRaw(
                    "export PAGER=cat SYSTEMD_PAGER=cat GIT_PAGER=cat MANPAGER=cat TERM=xterm-256color\n"
                )
            } catch {
                // 环境变量设置失败不影响交互终端。
            }

            do {
                for try await event in stream {
                    try Task.checkCancellation()

                    let buffer: ByteBuffer
                    switch event {
                    case .stdout(let value):
                        buffer = value
                    case .stderr(let value):
                        buffer = value
                    }

                    guard let text = buffer.getString(
                        at: buffer.readerIndex,
                        length: buffer.readableBytes
                    ), !text.isEmpty else {
                        continue
                    }

                    self.receive(text)
                }
            } catch is CancellationError {
                // 正常断开。
            } catch {
                if !self.disconnectRequested {
                    self.finishConnection(message: "SSH 数据流结束：\(error.localizedDescription)")
                }
            }

            self.activeWriter = nil
            self.client = nil
            self.isConnected = false

            if !self.disconnectRequested {
                self.statusText = "连接已断开"
                self.appendLocalMessage("\n[连接已断开]\n")
            }
        }
    }

    private func finishConnection(message: String) {
        activeWriter = nil
        client = nil
        isConnected = false
        statusText = message
        appendLocalMessage("\n[\(message)]\n")
    }

    private func cleanANSI(_ raw: String) -> String {
        var text = raw

        // OSC / window-title sequences
        text = text.replacingOccurrences(
            of: #"\u{1B}\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)?"#,
            with: "",
            options: .regularExpression
        )

        // CSI sequences, including cursor movement and screen clearing.
        text = text.replacingOccurrences(
            of: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )

        // Remaining two-byte ESC sequences.
        text = text.replacingOccurrences(
            of: #"\u{1B}[@-Z\\-_]"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(of: "\u{009B}", with: "")
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        // Remove other non-printing C0 controls, but keep tab/newline.
        text = String(text.unicodeScalars.filter { scalar in
            scalar.value == 9 || scalar.value == 10 || scalar.value >= 32
        })

        return text
    }

    private func receive(_ raw: String) {
        let cleaned = cleanANSI(raw)
        guard !cleaned.isEmpty else { return }

        pendingOutput += cleaned

        guard flushTask == nil else { return }

        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flushPendingOutput()
        }
    }

    private func flushPendingOutput() {
        flushTask = nil
        guard !pendingOutput.isEmpty else { return }

        terminalText += pendingOutput
        pendingOutput = ""
        trimTerminalIfNeeded()
        outputRevision &+= 1
    }

    private func appendLocalMessage(_ text: String) {
        terminalText += text
        trimTerminalIfNeeded()
        outputRevision &+= 1
    }

    private func trimTerminalIfNeeded() {
        let lines = terminalText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )

        guard lines.count > maxStoredLines else { return }

        terminalText = lines.suffix(maxStoredLines).joined(separator: "\n")
    }

    func sendCommand(_ command: String) {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard isConnected else {
            appendLocalMessage("\n[未连接，无法执行：\(value)]\n")
            return
        }
        sendRaw(value + "\n")
    }

    func sendKey(_ value: String) {
        guard isConnected else { return }
        sendRaw(value)
    }

    func sendCtrlC() { sendKey("\u{03}") }
    func sendEscape() { sendKey("\u{1B}") }
    func sendBackspace() { sendKey("\u{7F}") }
    func sendSpace() { sendKey(" ") }

    private func sendRaw(_ value: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.writeRaw(value)
            } catch {
                self.appendLocalMessage("\n[写入失败：\(error.localizedDescription)]\n")
            }
        }
    }

    private func writeRaw(_ value: String) async throws {
        guard let writer = activeWriter else {
            throw NSError(
                domain: "MySSH",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "SSH 写入通道不存在"]
            )
        }

        var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
        buffer.writeString(value)
        try await writer.write(buffer)
    }

    func disconnect() {
        guard isConnected || connectionTask != nil else { return }

        disconnectRequested = true
        endBackgroundTask()
        flushTask?.cancel()
        flushTask = nil
        pendingOutput = ""

        connectionTask?.cancel()
        connectionTask = nil

        let oldClient = client
        client = nil
        activeWriter = nil
        isConnected = false
        statusText = "已断开"
        appendLocalMessage("\n[已主动断开]\n")

        if let oldClient {
            Task {
                try? await oldClient.close()
            }
        }
    }

    func appDidEnterBackground() {
        guard isConnected, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "SSHSession"
        ) { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func appWillEnterForeground() {
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
