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

    public init(
        command: String,
        output: String,
        prompt: String = ""
    ) {
        self.command = command
        self.output = output
        self.prompt = prompt
    }
}

class SSHSession: ObservableObject {

    @Published var isConnected: Bool = false
    @Published var history: [CommandHistoryItem] = []
    @Published var currentPrompt: String = ""

    private var client: SSHClient?
    private var activeWriter: TTYStdinWriter?

    var host: String = ""
    var port: Int = 22
    var username: String = "root"
    var password: String = ""

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var keepAliveTimer: Timer?

    // MARK: - 串行命令队列

    // 已经建立历史块、等待执行/正在执行的命令 ID
    private var pendingCommandIDs: [UUID] = []

    // 与 pendingCommandIDs 一一对应
    private var pendingCommands: [String] = []

    // 当前是否已经有一个命令正在等待 Prompt
    private var commandIsRunning = false

    // MARK: - ANSI

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
            with: ""
        )

        return text
    }

    // MARK: - Prompt

    private func fallbackPrompt() -> String {
        let symbol = username == "root" ? "#" : "$"
        return "\(username)@\(host):~\(symbol)"
    }

    private func extractTrailingPrompt(
        from text: String
    ) -> (prompt: String, output: String)? {

        let lines = text.components(
            separatedBy: "\n"
        )

        guard let lastNonEmptyIndex = lines.lastIndex(
            where: {
                !$0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }
        ) else {
            return nil
        }

        let possiblePrompt = lines[lastNonEmptyIndex]
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        let pattern =
            #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^\r\n]*[#$]$"#

        guard possiblePrompt.range(
            of: pattern,
            options: .regularExpression
        ) != nil else {
            return nil
        }

        var outputLines = lines

        outputLines.remove(
            at: lastNonEmptyIndex
        )

        var output = outputLines.joined(
            separator: "\n"
        )

        while output.hasSuffix("\n") {
            output.removeLast()
        }

        return (
            possiblePrompt,
            output
        )
    }

    // MARK: - Connect

    func connect() {

        guard !isConnected else {
            return
        }

        Task {

            do {

                let client = try await SSHClient.connect(
                    host: self.host,
                    port: .init(
                        integerLiteral: self.port
                    ),
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
                    self.currentPrompt =
                        self.fallbackPrompt()

                    self.pendingCommandIDs.removeAll()
                    self.pendingCommands.removeAll()
                    self.commandIsRunning = false

                    if self.history.isEmpty {

                        self.history.append(
                            CommandHistoryItem(
                                command: "system",
                                output:
                                    "连接成功：\(self.host)"
                            )
                        )
                    }

                    self.startKeepAlive()
                }

                let ptyReq =
                    SSHChannelRequestEvent
                    .PseudoTerminalRequest(
                        wantReply: true,
                        term: "xterm-256color",
                        terminalCharacterWidth: 100,
                        terminalRowHeight: 40,
                        terminalPixelWidth: 0,
                        terminalPixelHeight: 0,
                        terminalModes: .init(
                            [.ECHO: 0]
                        )
                    )

                try await client.withPTY(
                    ptyReq
                ) { [weak self] stream, writer in

                    await MainActor.run {

                        guard let self = self else {
                            return
                        }

                        self.activeWriter = writer

                        // 如果连接建立之前已经排队了命令，
                        // Writer 出现后立即开始第一个。
                        self.startNextQueuedCommand()
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

                            let cleaned =
                                self.cleanANSI(text)

                            guard !cleaned.isEmpty else {
                                continue
                            }

                            await MainActor.run {

                                self.appendOutput(
                                    cleaned
                                )
                            }
                        }
                    }
                }

            } catch {

                await MainActor.run {

                    self.history.append(
                        CommandHistoryItem(
                            command: "system",
                            output:
                                "连接断开或异常: \(error.localizedDescription)"
                        )
                    )

                    self.isConnected = false
                    self.activeWriter = nil

                    self.stopKeepAlive()

                    self.pendingCommandIDs.removeAll()
                    self.pendingCommands.removeAll()

                    self.commandIsRunning = false
                }
            }
        }
    }

    // MARK: - Receive Output

    private func appendOutput(
        _ text: String
    ) {

        var incomingText = text

        // ------------------------------------------------
        // 先检查是不是 Shell Prompt。
        //
        // 收到 Prompt = 当前命令已经真正结束。
        // 只有到了这里，才允许发送下一个命令。
        // ------------------------------------------------

        if let promptResult =
            extractTrailingPrompt(
                from: incomingText
            ) {

            currentPrompt =
                promptResult.prompt

            incomingText =
                promptResult.output

            if !pendingCommandIDs.isEmpty {

                let finishedID =
                    pendingCommandIDs.removeFirst()

                if !pendingCommands.isEmpty {
                    pendingCommands.removeFirst()
                }

                if let index =
                    history.firstIndex(
                        where: {
                            $0.id == finishedID
                        }
                    ) {

                    if !incomingText.isEmpty {

                        history[index].output +=
                            incomingText
                    }
                }

                // 当前命令彻底结束。
                commandIsRunning = false

                // 现在才开始下一个。
                startNextQueuedCommand()

                return
            }
        }

        guard !incomingText.isEmpty else {
            return
        }

        // ------------------------------------------------
        // 有命令正在执行：
        // 所有输出只允许进入队列第一个命令。
        // ------------------------------------------------

        if let firstPendingID =
            pendingCommandIDs.first,
           let index =
            history.firstIndex(
                where: {
                    $0.id == firstPendingID
                }
            ) {

            history[index].output +=
                incomingText

            return
        }

        // ------------------------------------------------
        // 没有命令等待：
        // 欢迎信息 / 系统信息。
        // ------------------------------------------------

        if let lastIndex =
            history.indices.last,
           history[lastIndex].command == "system" {

            var cleanedText =
                incomingText

            if cleanedText.contains(
                "System information as of"
            ) {

                if let range =
                    cleanedText.range(
                        of: "root@"
                    ) {

                    cleanedText =
                        String(
                            cleanedText[
                                range.lowerBound...
                            ]
                        )

                } else if let range2 =
                    cleanedText.range(
                        of: "Last login:"
                    ) {

                    cleanedText =
                        String(
                            cleanedText[
                                range2.lowerBound...
                            ]
                        )
                }
            }

            history[lastIndex].output +=
                cleanedText

        } else {

            history.append(
                CommandHistoryItem(
                    command: "system",
                    output: incomingText
                )
            )
        }
    }

    // MARK: - 拆分组合命令

    private func splitCommands(
        _ command: String
    ) -> [String] {

        /*
         支持：

         uname -a
         df -h

         以及：

         uname -a; df -h; free -h

         注意：
         ; 只在引号之外作为分隔符。

         && / || 不拆。
         因为强行拆成多个独立 SSH 命令会改变 Shell
         原本的条件执行逻辑。
        */

        var result: [String] = []
        var current = ""

        var singleQuote = false
        var doubleQuote = false
        var escaped = false

        for character in command {

            if escaped {

                current.append(character)
                escaped = false
                continue
            }

            if character == "\\" && !singleQuote {

                current.append(character)
                escaped = true
                continue
            }

            if character == "'" && !doubleQuote {

                singleQuote.toggle()
                current.append(character)
                continue
            }

            if character == "\"" && !singleQuote {

                doubleQuote.toggle()
                current.append(character)
                continue
            }

            if character == ";" && !singleQuote && !doubleQuote {

                let value =
                    current.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )

                if !value.isEmpty {
                    result.append(value)
                }

                current = ""
                continue
            }

            if character == "\n" && !singleQuote && !doubleQuote {

                let value =
                    current.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )

                if !value.isEmpty {
                    result.append(value)
                }

                current = ""
                continue
            }

            current.append(character)
        }

        let finalValue =
            current.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        if !finalValue.isEmpty {
            result.append(finalValue)
        }

        return result
    }

    // MARK: - Send Command

    func sendCommand(
        _ command: String
    ) {

        guard isConnected else {
            return
        }

        let commands =
            splitCommands(command)

        guard !commands.isEmpty else {
            return
        }

        // ------------------------------------------------
        // 先建立所有历史块。
        //
        // 例如：
        //
        // uname -a; df -h; free -h
        //
        // 会立即建立：
        //
        // [uname -a]
        // [df -h]
        // [free -h]
        //
        // 但只发送第一个。
        // ------------------------------------------------

        for cmd in commands {

            let item =
                CommandHistoryItem(
                    command: cmd,
                    output: "",
                    prompt:
                        currentPrompt.isEmpty
                        ? fallbackPrompt()
                        : currentPrompt
                )

            history.append(item)

            pendingCommandIDs.append(
                item.id
            )

            pendingCommands.append(
                cmd
            )
        }

        // 只有这里启动。
        // 后面的命令由收到 Prompt 后自动启动。
        startNextQueuedCommand()
    }

    // MARK: - 开始队列中的下一个命令

    private func startNextQueuedCommand() {

        guard !commandIsRunning else {
            return
        }

        guard !pendingCommandIDs.isEmpty,
              !pendingCommands.isEmpty else {
            return
        }

        guard isConnected else {
            return
        }

        guard let writer = activeWriter else {
            // Writer 还没准备好。
            // 等 withPTY 设置 activeWriter 后再次调用。
            return
        }

        let command =
            pendingCommands[0]

        commandIsRunning = true

        Task {

            do {

                var buffer =
                    ByteBufferAllocator()
                        .buffer(
                            capacity:
                                command.utf8.count + 1
                        )

                buffer.writeString(
                    command + "\n"
                )

                try await writer.write(
                    buffer
                )

            } catch {

                await MainActor.run {

                    guard
                        let failedID =
                            self.pendingCommandIDs.first,
                        let index =
                            self.history.firstIndex(
                                where: {
                                    $0.id == failedID
                                }
                            )
                    else {
                        self.commandIsRunning = false
                        return
                    }

                    self.history[index].output =
                        "写入失败: \(error.localizedDescription)"

                    self.pendingCommandIDs.removeFirst()

                    if !self.pendingCommands.isEmpty {
                        self.pendingCommands.removeFirst()
                    }

                    self.commandIsRunning = false

                    // 当前失败后继续处理后面的队列。
                    self.startNextQueuedCommand()
                }
            }
        }
    }

    // MARK: - Raw SSH Key

    func sendRaw(
        _ value: String
    ) {

        guard isConnected else {
            return
        }

        Task {

            do {

                guard let writer =
                    self.activeWriter else {
                    return
                }

                var buffer =
                    ByteBufferAllocator()
                        .buffer(
                            capacity:
                                value.utf8.count
                        )

                buffer.writeString(value)

                try await writer.write(
                    buffer
                )

            } catch {
                // 控制键失败时不创建历史记录
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

                    guard let self = self,
                          self.isConnected,
                          let writer =
                            self.activeWriter else {
                        return
                    }

                    Task {

                        var buffer =
                            ByteBufferAllocator()
                                .buffer(
                                    capacity: 1
                                )

                        buffer.writeString("")

                        try? await writer.write(
                            buffer
                        )
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
                self.pendingCommands.removeAll()

                self.commandIsRunning = false

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
