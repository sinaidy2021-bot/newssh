import Foundation
import UIKit
import Citadel
import NIOCore
import NIOSSH

public struct CommandHistoryItem: Identifiable {
    public let id = UUID()
    public let command: String
    public let prompt: String
    public var output: String

    public init(command: String, output: String, prompt: String = "") {
        self.command = command
        self.output = output
        self.prompt = prompt
    }
}

class SSHSession: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var history: [CommandHistoryItem] = []

    // 当前真实 Shell Prompt
    @Published var currentPrompt: String = ""

    private var client: SSHClient?
    private var activeWriter: TTYStdinWriter?

    var host: String = ""
    var port: Int = 22
    var username: String = "root"
    var password: String = ""

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var keepAliveTimer: Timer?

    // 等待服务器返回的命令。
    // Shell 是串行执行的，所以收到一个 Prompt 就代表前一个命令结束。
    private var pendingCommandIDs: [UUID] = []

    private func cleanANSI(_ raw: String) -> String {
        var text = raw

        text = text.replacingOccurrences(
            of: #"\x1B\[\?[0-9]+[hl]"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"\x1B\][^\x07\x1B]*(\x07|\x1B\\)?"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"\x1B\[[0-9;]*[mKHz]"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"\x1B[@-Z\\-_]|[\u001B\u009B][#()#?]*([\x20-\x7E]*)([@-~])"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(of: "\u{001B}", with: "")
        text = text.replacingOccurrences(of: "\u{009B}", with: "")
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "")

        return text
    }

    // MARK: - Prompt

    private func fallbackPrompt() -> String {
        let symbol = username == "root" ? "#" : "$"
        return "\(username)@\(host):~\(symbol)"
    }

    private func extractTrailingPrompt(from text: String) -> (prompt: String, output: String)? {
        let lines = text.components(separatedBy: "\n")

        guard let lastNonEmptyIndex = lines.lastIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return nil
        }

        let possiblePrompt = lines[lastNonEmptyIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        /*
         常见 Linux Prompt：

         root@server:~#
         root@server:/etc/x-ui#
         ubuntu@server:~$
         admin@server:/var/log$
        */

        let pattern = #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^\r\n]*[#$]$"#

        guard possiblePrompt.range(
            of: pattern,
            options: .regularExpression
        ) != nil else {
            return nil
        }

        var outputLines = lines

        // 删除 Prompt 所在行
        outputLines.remove(at: lastNonEmptyIndex)

        var output = outputLines.joined(separator: "\n")

        // 不让输出末尾因为 Prompt 留下一堆空行
        while output.hasSuffix("\n") {
            output.removeLast()
        }

        return (possiblePrompt, output)
    }

    // MARK: - Connect

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
                    self.currentPrompt = self.fallbackPrompt()

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
                    terminalModes: .init([.ECHO: 0])
                )

                try await client.withPTY(ptyReq) { [weak self] stream, writer in
                    await MainActor.run {
                        self?.activeWriter = writer
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
                            guard let self = self else { return }

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
                    self.pendingCommandIDs.removeAll()
                }
            }
        }
    }

    // MARK: - Receive Output

    private func appendOutput(_ text: String) {

        var incomingText = text

        // 先检查是否收到真实 Prompt
        if let promptResult = extractTrailingPrompt(from: incomingText) {

            currentPrompt = promptResult.prompt

            incomingText = promptResult.output

            // 有命令正在等待完成
            if !pendingCommandIDs.isEmpty {

                let finishedID = pendingCommandIDs.removeFirst()

                if let index = history.firstIndex(where: {
                    $0.id == finishedID
                }) {
                    if !incomingText.isEmpty {
                        history[index].output += incomingText
                    }
                }

                return
            }
        }

        guard !incomingText.isEmpty else {
            return
        }

        // 如果有正在等待输出的命令，
        // 永远写入队列最前面的那个命令。
        if let firstPendingID = pendingCommandIDs.first,
           let index = history.firstIndex(where: {
               $0.id == firstPendingID
           }) {

            history[index].output += incomingText
            return
        }

        // 没有正在等待的命令：
        // 这是连接后的欢迎信息 / 系统信息。
        if let lastIndex = history.indices.last,
           history[lastIndex].command == "system" {

            var cleanedText = incomingText

            if cleanedText.contains("System information as of") {
                if let range = cleanedText.range(of: "root@") {
                    cleanedText = String(cleanedText[range.lowerBound...])
                } else if let range2 = cleanedText.range(of: "Last login:") {
                    cleanedText = String(cleanedText[range2.lowerBound...])
                }
            }

            history[lastIndex].output += cleanedText

        } else {
            history.append(
                CommandHistoryItem(
                    command: "system",
                    output: incomingText
                )
            )
        }
    }

    // MARK: - Send Command

    func sendCommand(_ command: String) {
        guard isConnected else { return }

        /*
         支持一次粘贴多条命令：

         apt update
         apt upgrade
         ls -la

         会拆成三个独立的历史块。
        */

        let commands = command
            .components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter {
                !$0.isEmpty
            }

        guard !commands.isEmpty else {
            return
        }

        let items = commands.map {
            CommandHistoryItem(
                command: $0,
                output: "",
                prompt: currentPrompt.isEmpty
                    ? fallbackPrompt()
                    : currentPrompt
            )
        }

        DispatchQueue.main.async {
            for item in items {
                self.history.append(item)
                self.pendingCommandIDs.append(item.id)
            }
        }

        Task {
            do {
                guard let writer = self.activeWriter else {
                    return
                }

                for cmd in commands {
                    var buffer = ByteBufferAllocator().buffer(
                        capacity: cmd.utf8.count + 1
                    )

                    buffer.writeString(cmd + "\n")

                    try await writer.write(buffer)
                }

            } catch {
                await MainActor.run {
                    if let firstPendingID = self.pendingCommandIDs.first,
                       let index = self.history.firstIndex(where: {
                           $0.id == firstPendingID
                       }) {

                        self.history[index].output =
                            "写入失败: \(error.localizedDescription)"

                        self.pendingCommandIDs.removeFirst()
                    }
                }
            }
        }
    }

    // MARK: - Raw SSH Key

    func sendRaw(_ value: String) {
        guard isConnected else { return }

        Task {
            do {
                guard let writer = self.activeWriter else {
                    return
                }

                var buffer = ByteBufferAllocator().buffer(
                    capacity: value.utf8.count
                )

                buffer.writeString(value)

                try await writer.write(buffer)

            } catch {
                // Ctrl / Tab / Esc / Arrow 等控制键失败时，
                // 不创建命令历史块。
            }
        }
    }

    // MARK: - Keep Alive

    private func startKeepAlive() {
        stopKeepAlive()

        DispatchQueue.main.async {
            self.keepAliveTimer = Timer.scheduledTimer(
                withTimeInterval: 25.0,
                repeats: true
            ) { [weak self] _ in

                guard let self = self,
                      self.isConnected,
                      let writer = self.activeWriter else {
                    return
                }

                Task {
                    var buffer = ByteBufferAllocator().buffer(capacity: 1)
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

    // MARK: - Background

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

    // MARK: - Disconnect

    func disconnect() {
        stopKeepAlive()
        endBackgroundTask()

        Task {
            try? await self.client?.close()

            await MainActor.run {
                self.client = nil
                self.activeWriter = nil
                self.isConnected = false
                self.pendingCommandIDs.removeAll()

                self.history.append(
                    CommandHistoryItem(
                        command: "system",
                        output: "已主动断开连接"
                    )
                )
            }
        }
    }
}
