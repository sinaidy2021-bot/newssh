import Foundation
import UIKit
import Citadel
import NIOCore
import NIOSSH

struct CommandHistoryItem: Identifiable {
    let id = UUID()
    let command: String
    var output: String
}

@MainActor
final class SSHSession: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var history: [CommandHistoryItem] = []

    private var client: SSHClient?
    private var activeWriter: TTYStdinWriter?

    private var connectionTask: Task<Void, Never>?
    private var keepAliveTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    let host: String
    let port: Int
    let username: String
    let password: String

    init(
        host: String = "",
        port: Int = 22,
        username: String = "root",
        password: String = ""
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    deinit {
        connectionTask?.cancel()
        keepAliveTimer?.invalidate()

        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(
                backgroundTask
            )
        }
    }

    private func cleanANSI(_ raw: String) -> String {
        var text = raw

        text = text.replacingOccurrences(
            of: #"\x1B\][^\x07\x1B]*(\x07|\x1B\\)?"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"\x1B[@-Z\\-_]"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: "\u{001B}",
            with: ""
        )

        text = text.replacingOccurrences(
            of: "\u{009B}",
            with: ""
        )

        text = text.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )

        text = text.replacingOccurrences(
            of: "\r",
            with: "\n"
        )

        return text
    }

    func connect() {
        guard !isConnected else {
            return
        }

        guard connectionTask == nil else {
            return
        }

        appendSystem("正在连接 \(host):\(port)…")

        let host = self.host
        let port = self.port
        let username = self.username
        let password = self.password

        connectionTask = Task { [weak self] in
            guard let self else {
                return
            }

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

                await self.startPTY(client: client)
            } catch is CancellationError {
                await self.finishConnection(
                    message: "连接已取消"
                )
            } catch {
                await self.finishConnection(
                    message: "连接失败: \(error.localizedDescription)"
                )
            }
        }
    }

    private func startPTY(client: SSHClient) async {
        let ptyReq = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 100,
            terminalRowHeight: 40,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([
                .ECHO: 1
            ])
        )

        do {
            try await client.withPTY(
                ptyReq
            ) { [weak self] stream, writer in

                guard let self else {
                    return
                }

                self.client = client
                self.activeWriter = writer
                self.isConnected = true

                self.appendSystem(
                    "连接成功：\(self.host):\(self.port)"
                )

                do {
                    try await self.sendRawInternal(
                        "export PAGER=cat SYSTEMD_PAGER=cat GIT_PAGER=cat MANPAGER=cat TERM=xterm-256color\n"
                    )
                } catch {
                    // 环境变量设置失败不影响 SSH 连接
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

                        if let text = buffer.getString(
                            at: buffer.readerIndex,
                            length: buffer.readableBytes
                        ) {
                            let cleaned = self.cleanANSI(text)

                            guard !cleaned.isEmpty else {
                                continue
                            }

                            self.appendOutput(cleaned)
                        }
                    }
                } catch is CancellationError {
                    // 正常取消
                } catch {
                    self.appendSystem(
                        "SSH 数据流结束: \(error.localizedDescription)"
                    )
                }

                self.activeWriter = nil
                self.client = nil
                self.isConnected = false
            }
        } catch is CancellationError {
            // 正常取消
        } catch {
            self.appendSystem(
                "PTY 错误: \(error.localizedDescription)"
            )

            self.activeWriter = nil
            self.client = nil
            self.isConnected = false
        }

        connectionTask = nil
    }

    private func appendSystem(_ text: String) {
        history.append(
            CommandHistoryItem(
                command: "system",
                output: text
            )
        )
    }

    private func appendOutput(_ text: String) {
        guard !text.isEmpty else {
            return
        }

        guard let index = history.indices.last else {
            appendSystem(text)
            return
        }

        if history[index].command == "system" {
            history[index].output += text
            return
        }

        history[index].output += text
    }

    func sendCommand(_ command: String) {
        let value = command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !value.isEmpty else {
            return
        }

        guard isConnected else {
            appendSystem("未连接，无法执行：\(value)")
            return
        }

        history.append(
            CommandHistoryItem(
                command: value,
                output: ""
            )
        )

        sendRaw(value + "\n")
    }

    func sendKey(_ value: String) {
        guard isConnected else {
            return
        }

        sendRaw(value)
    }

    func sendCtrlC() {
        sendKey("\u{03}")
    }

    func sendEscape() {
        sendKey("\u{1B}")
    }

    func sendBackspace() {
        sendKey("\u{7F}")
    }

    func sendSpace() {
        sendKey(" ")
    }

    private func sendRaw(_ text: String) {
        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.sendRawInternal(text)
            } catch {
                self.appendSystem(
                    "写入失败: \(error.localizedDescription)"
                )
            }
        }
    }

    private func sendRawInternal(_ text: String) async throws {
        guard let writer = activeWriter else {
            throw NSError(
                domain: "SSHSession",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "SSH 写入通道不存在"
                ]
            )
        }

        var buffer = ByteBufferAllocator().buffer(
            capacity: text.utf8.count
        )

        buffer.writeString(text)

        try await writer.write(buffer)
    }

    private func startKeepAlive() {
        stopKeepAlive()

        // PTY 本身保持活动即可。
        // 不再每 25 秒向远端写空 ByteBuffer，
        // 避免 Timer / writer / disconnect 生命周期竞争。
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    func appDidEnterBackground() {
        guard isConnected else {
            return
        }

        guard backgroundTask == .invalid else {
            return
        }

        backgroundTask =
            UIApplication.shared.beginBackgroundTask(
                withName: "SSHKeepAlive"
            ) { [weak self] in
                self?.endBackgroundTask()
            }
    }

    func appWillEnterForeground() {
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(
                backgroundTask
            )

            backgroundTask = .invalid
        }
    }

    func disconnect() {
        stopKeepAlive()
        endBackgroundTask()

        connectionTask?.cancel()
        connectionTask = nil

        let client = self.client

        self.client = nil
        self.activeWriter = nil
        self.isConnected = false

        if client != nil {
            Task {
                try? await client?.close()
            }
        }

        history.append(
            CommandHistoryItem(
                command: "system",
                output: "已主动断开连接"
            )
        )
    }
}
