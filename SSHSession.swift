import Foundation
import UIKit
import Citadel
import NIOCore
import NIOSSH

public struct CommandHistoryItem: Identifiable {
    public let id = UUID()
    public let command: String
    public var output: String

    public init(command: String, output: String) {
        self.command = command
        self.output = output
    }
}

class SSHSession: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var history: [CommandHistoryItem] = []

    private var client: SSHClient?
    private var activeWriter: TTYStdinWriter?

    var host: String = ""
    var port: Int = 22
    var username: String = "root"
    var password: String = ""

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var keepAliveTimer: Timer?

    // MARK: - ANSI 清理

    private func cleanANSI(_ raw: String) -> String {
        var text = raw

        // OSC 序列：
        // ESC ] ... BEL
        // ESC ] ... ESC \
        text = text.replacingOccurrences(
            of: #"\x1B\][^\x07\x1B]*(\x07|\x1B\\)?"#,
            with: "",
            options: .regularExpression
        )

        // CSI 序列：
        // ESC [ 参数 字母
        // 例如：
        // 颜色 m
        // 清屏 J
        // 清行 K
        // 光标移动 A/B/C/D
        // 光标定位 H
        // 备用屏幕 ?1049h/l
        text = text.replacingOccurrences(
            of: #"\x1B\[[0-9;?]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )

        // 其他双字符转义
        text = text.replacingOccurrences(
            of: #"\x1B[@-Z\\-_]"#,
            with: "",
            options: .regularExpression
        )

        // 清理裸 ESC / C1 控制字符
        text = text.replacingOccurrences(of: "\u{001B}", with: "")
        text = text.replacingOccurrences(of: "\u{009B}", with: "")

        // 统一换行
        text = text.replacingOccurrences(of: "\r\n", with: "\n")

        // 单独的 \r 通常是进度条覆盖，不保留
        text = text.replacingOccurrences(of: "\r", with: "")

        return text
    }

    // MARK: - 连接

    func connect() {
        guard !isConnected else { return }

        Task {
            do {
                let client = try await SSHClient.connect(
                    host: self.host,
                    port: .init(integerLiteral: self.port),
                    authenticationMethod: .passwordBased(
                        username: self.username,
                        password: self.password
                    ),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )

                await MainActor.run {
                    self.client = client
                    self.isConnected = true

                    if self.history.isEmpty {
                        self.history.append(
                            CommandHistoryItem(
                                command: "system",
                                output: "连接成功：\(self.host)"
                            )
                        )
                    }

                    self.startKeepAlive()
                }

                let ptyReq = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: 100,
                    terminalRowHeight: 40,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([
                        .ECHO: 0
                    ])
                )

                try await client.withPTY(ptyReq) { [weak self] stream, writer in

                    await MainActor.run {
                        self?.activeWriter = writer
                    }

                    // 关闭常见命令的自动分页
                    // 防止 systemctl / journalctl / git / man 等进入 less
                    do {
                        var buffer = ByteBufferAllocator().buffer(capacity: 256)

                        buffer.writeString(
                            "export PAGER=cat SYSTEMD_PAGER=cat GIT_PAGER=cat MANPAGER=cat 2>/dev/null\n"
                        )

                        try await writer.write(buffer)
                    } catch {
                        // 自动设置分页失败不影响 SSH 正常使用
                    }

                    for try await event in stream {
                        let buffer: ByteBuffer

                        switch event {
                        case .stdout(let b):
                            buffer = b

                        case .stderr(let b):
                            buffer = b
                        }

                        if let text = buffer.getString(
                            at: buffer.readerIndex,
                            length: buffer.readableBytes
                        ) {
                            guard let self = self else {
                                return
                            }

                            let cleaned = self.cleanANSI(text)

                            guard !cleaned.isEmpty else {
                                continue
                            }

                            await MainActor.run {
                                self.appendOutput(cleaned)
                            }
                        }
                    }
                }

            } catch {
                await MainActor.run {
                    self.history.append(
                        CommandHistoryItem(
                            command: "system",
                            output: "连接断开或异常: \(error.localizedDescription)"
                        )
                    )

                    self.isConnected = false
                    self.activeWriter = nil
                    self.stopKeepAlive()
                }
            }
        }
    }

    // MARK: - 输出处理

    private func appendOutput(_ text: String) {
        guard let lastIndex = self.history.indices.last else {
            self.history.append(
                CommandHistoryItem(
                    command: "system",
                    output: text
                )
            )
            return
        }

        if self.history[lastIndex].command == "system" {

            // 登录横幅 / MOTD 等信息统一追加到 system 块
            var cleanedText = text

            if cleanedText.contains("System information as of") {
                if let range = cleanedText.range(of: "root@") {
                    cleanedText = String(cleanedText[range.lowerBound...])
                } else if let range2 = cleanedText.range(of: "Last login:") {
                    cleanedText = String(cleanedText[range2.lowerBound...])
                }
            }

            let existing = self.history[lastIndex].output

            self.history[lastIndex].output =
                existing.isEmpty
                ? cleanedText
                : existing + "\n" + cleanedText

        } else {

            var currentOutput =
                self.history[lastIndex].output + text

            let lastCmd =
                self.history[lastIndex].command

            // 去掉服务器回显的命令
            if currentOutput.hasPrefix(lastCmd + "\n") {

                currentOutput = String(
                    currentOutput.dropFirst(lastCmd.count + 1)
                )

            } else if currentOutput.hasPrefix(lastCmd)
                        && currentOutput.contains("\n") {

                let lines =
                    currentOutput.components(
                        separatedBy: "\n"
                    )

                if lines.first?.trimmingCharacters(
                    in: .whitespaces
                ) == lastCmd {

                    currentOutput =
                        lines.dropFirst().joined(
                            separator: "\n"
                        )
                }
            }

            self.history[lastIndex].output =
                currentOutput
        }
    }

    // MARK: - 发送命令

    func sendCommand(_ command: String) {
        guard isConnected else {
            return
        }

        let cmdToSend =
            command.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !cmdToSend.isEmpty else {
            return
        }

        DispatchQueue.main.async {
            self.history.append(
                CommandHistoryItem(
                    command: cmdToSend,
                    output: ""
                )
            )
        }

        Task {
            do {
                if let writer = self.activeWriter {

                    var buffer =
                        ByteBufferAllocator().buffer(
                            capacity: cmdToSend.utf8.count + 1
                        )

                    buffer.writeString(
                        cmdToSend + "\n"
                    )

                    try await writer.write(buffer)
                }

            } catch {
                await MainActor.run {

                    if let lastIndex =
                        self.history.indices.last {

                        self.history[lastIndex].output =
                            "写入失败: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: - Keep Alive

    private func startKeepAlive() {
        stopKeepAlive()

        DispatchQueue.main.async {
            self.keepAliveTimer =
                Timer.scheduledTimer(
                    withTimeInterval: 25.0,
                    repeats: true
                ) { [weak self] _ in

                    guard
                        let self = self,
                        self.isConnected,
                        let writer = self.activeWriter
                    else {
                        return
                    }

                    Task {
                        var buffer =
                            ByteBufferAllocator().buffer(
                                capacity: 1
                            )

                        buffer.writeString("")

                        try? await writer.write(buffer)
                    }
                }
        }
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    // MARK: - App 后台

    func appDidEnterBackground() {
        guard isConnected else {
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

            backgroundTask =
                .invalid
        }
    }

    // MARK: - 断开连接

    func disconnect() {
        stopKeepAlive()
        endBackgroundTask()

        Task {
            try? await self.client?.close()

            await MainActor.run {
                self.client = nil
                self.activeWriter = nil
                self.isConnected = false

                self.history.append(
                    CommandHistoryItem(
                        command: "已主动断开连接",
                        output: ""
                    )
                )
            }
        }
    }
}
