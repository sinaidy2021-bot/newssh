import Foundation
import UIKit
import Combine
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

@MainActor
final class SSHSession: ObservableObject {
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

    // MARK: - 输出批处理
    // 大量输出时不要每个 SSH chunk 都触发 SwiftUI 重绘。
    private var pendingOutput = ""
    private var flushTask: Task<Void, Never>?

    // MARK: - 多命令队列
    // 每条命令单独保存，输出严格按发送顺序归属。
    private struct PendingCommand {
        let id: UUID
        let command: String
    }

    private var pendingCommands: [PendingCommand] = []

    // 终端中用 shell marker 判断一条命令何时结束。
    private let commandEndMarker = "__MYSSH_DONE_7F3A9C__"

    // 防止单条命令超大输出拖垮 iPhone。
    private let maxOutputCharactersPerCommand = 300_000

    // 防止长期使用后历史无限增长。
    private let maxHistoryItems = 120

    // MARK: - ANSI 清理
    private func cleanANSI(_ raw: String) -> String {
        var text = raw

        // OSC：ESC ] ... BEL / ESC \
        text = text.replacingOccurrences(
            of: #"\x1B\][^\x07\x1B]*(\x07|\x1B\\)?"#,
            with: "",
            options: .regularExpression
        )

        // CSI：ESC [ 参数/中间字节 最终字节
        text = text.replacingOccurrences(
            of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )

        // 其他常见 ESC 双字符序列
        text = text.replacingOccurrences(
            of: #"\x1B[@-Z\\-_]"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(of: "\u{001B}", with: "")
        text = text.replacingOccurrences(of: "\u{009B}", with: "")

        // PTY 常见 CRLF -> LF；裸 CR 不显示，避免产生大量覆盖式垃圾。
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "")

        return text
    }

    // MARK: - 连接
    func connect() {
        guard !isConnected else { return }

        flushTask?.cancel()
        flushTask = nil
        pendingOutput = ""
        pendingCommands.removeAll()

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

                self.client = client
                self.isConnected = true
                self.startKeepAlive()

                let ptyReq = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: 100,
                    terminalRowHeight: 40,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 0])
                )

                try await client.withPTY(ptyReq) { [weak self] stream, writer in
                    guard let self = self else { return }

                    self.activeWriter = writer

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
                            self.receiveOutput(text)
                        }
                    }
                }

                if self.isConnected {
                    self.finishConnection(message: nil)
                }
            } catch {
                self.finishConnection(
                    message: "连接断开或异常: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - 输出接收/批处理
    private func receiveOutput(_ rawText: String) {
        let cleaned = cleanANSI(rawText)
        guard !cleaned.isEmpty else { return }

        pendingOutput.append(cleaned)

        // 约 80ms 合并一次 UI 更新。
        if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self?.flushOutput()
                }
            }
        }

        // 极端大输出时不要让待处理缓冲无限涨。
        if pendingOutput.count >= 500_000 {
            flushOutput()
        }
    }

    private func flushOutput() {
        flushTask?.cancel()
        flushTask = nil

        guard !pendingOutput.isEmpty else { return }

        let text = pendingOutput
        pendingOutput = ""

        processOutput(text)
    }

    private func processOutput(_ text: String) {
        var remaining = text

        while let markerRange = remaining.range(of: commandEndMarker) {
            let beforeMarker = String(remaining[..<markerRange.lowerBound])

            if !beforeMarker.isEmpty {
                appendOutputToCurrentCommand(beforeMarker)
            }

            completeCurrentCommand()
            remaining = String(remaining[markerRange.upperBound...])
        }

        if !remaining.isEmpty {
            appendOutputToCurrentCommand(remaining)
        }
    }

    private func appendOutputToCurrentCommand(_ text: String) {
        guard !text.isEmpty else { return }
        guard let pending = pendingCommands.first else {
            // 未发送命令前的 MOTD / 登录信息不塞进终端历史。
            return
        }

        guard let index = history.firstIndex(where: { $0.id == pending.id }) else {
            return
        }

        var item = history[index]
        var output = item.output

        if output.isEmpty {
            output = text
        } else {
            output += text
        }

        // PTY 若返回命令回显，去掉一次。
        if output.hasPrefix(pending.command + "\n") {
            output = String(output.dropFirst(pending.command.count + 1))
        } else if output.hasPrefix(pending.command) {
            output = String(output.dropFirst(pending.command.count))
        }

        if output.count > maxOutputCharactersPerCommand {
            output = String(output.prefix(maxOutputCharactersPerCommand))
            if !output.hasSuffix("\n") {
                output += "\n"
            }
            output += "[输出过长，已限制显示]"
        }

        item.output = output
        history[index] = item
    }

    private func completeCurrentCommand() {
        guard !pendingCommands.isEmpty else { return }
        pendingCommands.removeFirst()
    }

    private func appendHistory(_ item: CommandHistoryItem) {
        history.append(item)

        if history.count > maxHistoryItems {
            history.removeFirst(history.count - maxHistoryItems)
        }
    }

    // MARK: - 发送命令
    func sendCommand(_ command: String) {
        guard isConnected else { return }

        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        guard let writer = activeWriter else { return }

        let id = UUID()

        appendHistory(
            CommandHistoryItem(command: cmd, output: "")
        )

        if let actualID = history.last?.id {
            pendingCommands.append(
                PendingCommand(id: actualID, command: cmd)
            )
        } else {
            return
        }

        Task {
            do {
                var buffer = ByteBufferAllocator().buffer(
                    capacity: cmd.utf8.count + commandEndMarker.utf8.count + 64
                )

                // 每条命令结束后输出唯一 marker。
                // marker 本身不会进入历史显示，只用于给客户端做命令边界。
                buffer.writeString(
                    "\(cmd)\nprintf '\\n\(commandEndMarker)\\n'\n"
                )

                try await writer.write(buffer)
            } catch {
                self.handleWriteFailure(id: id, error: error)
            }
        }
    }

    private func handleWriteFailure(id: UUID, error: Error) {
        if let index = history.firstIndex(where: { $0.id == id }) {
            history[index].output = "写入失败: \(error.localizedDescription)"
        }

        pendingCommands.removeAll { $0.id == id }
    }

    // MARK: - 控制键
    // Ctrl+C / ESC / 空格 / 退格等直接写 PTY，不创建命令历史。
    func sendControl(_ value: String) {
        guard isConnected, let writer = activeWriter else { return }

        Task {
            var buffer = ByteBufferAllocator().buffer(
                capacity: value.utf8.count
            )
            buffer.writeString(value)
            try? await writer.write(buffer)
        }
    }

    func sendCtrlC() {
        sendControl("\u{03}")
    }

    func sendEscape() {
        sendControl("\u{1B}")
    }

    func sendSpace() {
        sendControl(" ")
    }

    func sendBackspace() {
        sendControl("\u{7F}")
    }

    // MARK: - Keep Alive
    private func startKeepAlive() {
        stopKeepAlive()

        keepAliveTimer = Timer.scheduledTimer(
            withTimeInterval: 25.0,
            repeats: true
        ) { [weak self] _ in
            guard let self = self,
                  self.isConnected,
                  let writer = self.activeWriter else { return }

            Task {
                var buffer = ByteBufferAllocator().buffer(capacity: 1)
                buffer.writeString("")
                try? await writer.write(buffer)
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    // MARK: - App 生命周期
    func appDidEnterBackground() {
        guard isConnected else { return }

        backgroundTask = UIApplication.shared.beginBackgroundTask(
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
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - 连接结束
    private func finishConnection(message: String?) {
        flushOutput()

        isConnected = false
        activeWriter = nil
        stopKeepAlive()
        pendingCommands.removeAll()

        if let message, !message.isEmpty {
            appendHistory(
                CommandHistoryItem(command: "system", output: message)
            )
        }
    }

    func disconnect() {
        flushOutput()
        stopKeepAlive()
        endBackgroundTask()

        let clientToClose = client
        client = nil
        activeWriter = nil
        isConnected = false
        pendingCommands.removeAll()
        pendingOutput = ""

        Task {
            try? await clientToClose?.close()
        }

        appendHistory(
            CommandHistoryItem(command: "system", output: "已主动断开连接")
        )
    }
}
