import Foundation
import Combine
import NIO
import NIOCore
import NIOSSH
import Citadel

// MARK: - Command History

struct CommandHistoryItem: Identifiable {
    let id: UUID
    var command: String
    var prompt: String
    var output: String

    init(
        id: UUID = UUID(),
        command: String,
        prompt: String = "",
        output: String = ""
    ) {
        self.id = id
        self.command = command
        self.prompt = prompt
        self.output = output
    }
}

// MARK: - SSH Session

@MainActor
final class SSHSession: ObservableObject {

    // MARK: Published

    @Published private(set) var isConnected = false
    @Published private(set) var history: [CommandHistoryItem] = []
    @Published private(set) var currentPrompt = ""
    @Published private(set) var commandIsRunning = false

    // MARK: SSH

    private var client: SSHClient?

    private var terminalTask: Task<Void, Never>?

    private var host = ""
    private var port = 22
    private var username = ""
    private var password = ""

    // MARK: PTY input

    /*
     当前版本 Citadel 的 PTY 输入类型是 TTYStdinWriter。
     不再使用 NIOAsyncWriter，避免 SwiftNIO 泛型版本冲突。
     */
    private var activeWriter: TTYStdinWriter?

    // MARK: Command Queue

    private var pendingCommands: [String] = []
    private var pendingCommandIDs: [UUID] = []

    private var activeCommandID: UUID?

    private var isStartingCommand = false
    private var waitingForCommandEcho = false

    // MARK: Output Buffer

    private var receiveBuffer = ""

    // MARK: Prompt

    private let shellPromptRegex = try? NSRegularExpression(
        pattern: #"(?m)^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^\r\n]*[#$]\s*$"#
    )

    // MARK: - Connect

    func connect(
        host: String,
        port: Int,
        username: String,
        password: String
    ) {
        disconnect()

        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password

        terminalTask = Task { [weak self] in
            guard let self else { return }
            await self.performConnect()
        }
    }

    private func performConnect() async {

        do {
            let connectedClient = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: .passwordBased(
                    username: username,
                    password: password
                ),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )

            client = connectedClient
            isConnected = true

            let ptyRequest =
                SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: 120,
                    terminalRowHeight: 40,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([
                        .ECHO: 1
                    ])
                )

            try await connectedClient.withPTY(ptyRequest) {
                [weak self] inbound, outbound in

                guard let self else {
                    return
                }

                await self.terminalStarted(outbound)

                do {
                    for try await event in inbound {

                        guard !Task.isCancelled else {
                            break
                        }

                        switch event {

                        case .stdout(let buffer):
                            let text = String(buffer: buffer)

                            await self.receiveOutput(text)

                        case .stderr(let buffer):
                            let text = String(buffer: buffer)

                            await self.receiveOutput(text)
                        }
                    }
                } catch {
                    await self.handleTerminalError(error)
                }

                await self.terminalStopped()
            }

        } catch {
            isConnected = false
            commandIsRunning = false
            activeWriter = nil

            appendSystemOutput(
                "SSH 连接失败：\(error.localizedDescription)"
            )
        }
    }

    private func terminalStarted(
        _ writer: TTYStdinWriter
    ) {
        activeWriter = writer
    }

    private func terminalStopped() {
        activeWriter = nil
        isConnected = false
        commandIsRunning = false
        activeCommandID = nil
        isStartingCommand = false
        waitingForCommandEcho = false
    }

    private func handleTerminalError(
        _ error: Error
    ) {
        activeWriter = nil
        isConnected = false
        commandIsRunning = false

        appendSystemOutput(
            "SSH 会话错误：\(error.localizedDescription)"
        )
    }

    // MARK: - Disconnect

    func disconnect() {

        terminalTask?.cancel()
        terminalTask = nil

        activeWriter = nil
        client = nil

        pendingCommands.removeAll()
        pendingCommandIDs.removeAll()

        activeCommandID = nil

        commandIsRunning = false
        isStartingCommand = false
        waitingForCommandEcho = false

        receiveBuffer = ""
        currentPrompt = ""

        isConnected = false
    }

    // MARK: - Public Input

    /*
     核心入口：

     没有正在运行的命令：
         输入 = 新命令

     有正在运行的命令：
         输入 = 直接发送给当前 PTY

     这样 passwd / apt / x-ui / read / Y/n / 菜单数字
     就不会错误地进入命令队列。
     */
    func submitInput(_ text: String) {

        guard isConnected else {
            return
        }

        let value = text.trimmingCharacters(
            in: .newlines
        )

        if commandIsRunning {
            sendInteractiveInput(value)
        } else {
            sendCommand(value)
        }
    }

    // MARK: - Interactive Input

    private func sendInteractiveInput(
        _ text: String
    ) {

        guard let writer = activeWriter else {
            return
        }

        Task { [weak self] in

            guard let self else {
                return
            }

            do {
                var buffer = ByteBufferAllocator()
                    .buffer(
                        capacity: text.utf8.count + 1
                    )

                buffer.writeString(text)
                buffer.writeString("\n")

                try await writer.write(buffer)

            } catch {

                await MainActor.run {
                    self.appendSystemOutput(
                        "发送输入失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    // MARK: - Raw Input

    func sendRaw(_ text: String) {

        guard let writer = activeWriter else {
            return
        }

        Task {

            do {

                var buffer = ByteBufferAllocator()
                    .buffer(
                        capacity: text.utf8.count
                    )

                buffer.writeString(text)

                try await writer.write(buffer)

            } catch {

                appendSystemOutput(
                    "发送控制字符失败：\(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Command

    func sendCommand(
        _ command: String
    ) {

        let commands = splitCommands(command)

        guard !commands.isEmpty else {
            return
        }

        for command in commands {

            let cleaned = command.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            guard !cleaned.isEmpty else {
                continue
            }

            let item = CommandHistoryItem(
                command: cleaned,
                prompt: currentPrompt,
                output: ""
            )

            history.append(item)

            pendingCommandIDs.append(item.id)
            pendingCommands.append(cleaned)
        }

        startNextQueuedCommand()
    }

    // MARK: - Queue

    private func startNextQueuedCommand() {

        guard isConnected else {
            return
        }

        guard !commandIsRunning else {
            return
        }

        guard !isStartingCommand else {
            return
        }

        guard !pendingCommands.isEmpty else {
            return
        }

        guard let writer = activeWriter else {
            return
        }

        guard let commandID = pendingCommandIDs.first else {
            return
        }

        let command = pendingCommands.first ?? ""

        pendingCommands.removeFirst()
        pendingCommandIDs.removeFirst()

        activeCommandID = commandID

        commandIsRunning = true
        isStartingCommand = true
        waitingForCommandEcho = true

        receiveBuffer = ""

        Task {

            do {

                var buffer = ByteBufferAllocator()
                    .buffer(
                        capacity: command.utf8.count + 1
                    )

                buffer.writeString(command)
                buffer.writeString("\n")

                try await writer.write(buffer)

                isStartingCommand = false

            } catch {

                isStartingCommand = false
                commandIsRunning = false

                appendOutputToActiveCommand(
                    "\n发送命令失败：\(error.localizedDescription)"
                )

                finishActiveCommand()
            }
        }
    }

    // MARK: - Output

    private func receiveOutput(
        _ text: String
    ) {

        guard !text.isEmpty else {
            return
        }

        let cleaned = cleanANSI(text)

        guard !cleaned.isEmpty else {
            return
        }

        receiveBuffer += cleaned

        processReceiveBuffer()
    }

    private func processReceiveBuffer() {

        let normalized = receiveBuffer
            .replacingOccurrences(
                of: "\r\n",
                with: "\n"
            )
            .replacingOccurrences(
                of: "\r",
                with: "\n"
            )

        let lines = normalized.components(
            separatedBy: "\n"
        )

        guard !lines.isEmpty else {
            return
        }

        /*
         保留最后一个未完成的 fragment。
         */
        var completeLines = lines

        let last = completeLines.last ?? ""

        if !receiveBuffer.hasSuffix("\n")
            && !receiveBuffer.hasSuffix("\r") {

            completeLines.removeLast()

            receiveBuffer = last
        } else {
            receiveBuffer = ""
        }

        for line in completeLines {
            processOutputLine(line)
        }

        /*
         某些 shell 的 prompt 不一定以换行结束，
         所以额外检查当前 fragment。
         */
        if !receiveBuffer.isEmpty {

            if let prompt = extractTrailingPrompt(
                from: receiveBuffer
            ) {

                appendOutputToActiveCommand(
                    removeTrailingPrompt(
                        from: receiveBuffer,
                        prompt: prompt
                    )
                )

                currentPrompt = prompt

                receiveBuffer = ""

                finishActiveCommand()
            }
        }
    }

    private func processOutputLine(
        _ line: String
    ) {

        var value = line

        /*
         第一次输出通常是：

             command
             command output
             user@host:~$

         把 shell 自己回显的 command 去掉，
         因为历史块顶部已经显示 command。
         */
        if waitingForCommandEcho {

            waitingForCommandEcho = false

            let normalizedLine = normalizeTerminalLine(
                line
            )

            let activeCommand = activeCommandText()

            if normalizedLine == activeCommand {
                return
            }
        }

        /*
         Shell prompt = 当前命令完成。

         注意：

         Select [1-3]:
         Password:
         Continue? [Y/n]

         都不会匹配 shell prompt，
         所以 interactive command 会继续保持 running。
         */
        if let prompt = extractTrailingPrompt(
            from: value
        ) {

            value = removeTrailingPrompt(
                from: value,
                prompt: prompt
            )

            if !value.isEmpty {
                appendOutputToActiveCommand(value)
            }

            currentPrompt = prompt

            finishActiveCommand()

            return
        }

        appendOutputToActiveCommand(value)
    }

    // MARK: - Command Completion

    private func finishActiveCommand() {

        guard commandIsRunning else {
            return
        }

        commandIsRunning = false

        activeCommandID = nil
        waitingForCommandEcho = false
        isStartingCommand = false

        /*
         下一条命令异步启动，
         避免在 SwiftUI 发布状态过程中递归修改状态。
         */
        Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            try? await Task.sleep(
                nanoseconds: 20_000_000
            )

            self.startNextQueuedCommand()
        }
    }

    // MARK: - History Output

    private func appendOutputToActiveCommand(
        _ text: String
    ) {

        guard !text.isEmpty else {
            return
        }

        guard let id = activeCommandID else {
            appendSystemOutput(text)
            return
        }

        guard let index = history.firstIndex(
            where: { $0.id == id }
        ) else {
            return
        }

        if history[index].output.isEmpty {
            history[index].output = text
        } else {
            history[index].output += "\n" + text
        }
    }

    private func appendSystemOutput(
        _ text: String
    ) {

        let item = CommandHistoryItem(
            command: "[SSH]",
            prompt: currentPrompt,
            output: text
        )

        history.append(item)
    }

    private func activeCommandText() -> String {

        guard let id = activeCommandID else {
            return ""
        }

        return history.first(
            where: { $0.id == id }
        )?.command ?? ""
    }

    // MARK: - Prompt

    private func extractTrailingPrompt(
        from text: String
    ) -> String? {

        let value = text
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !value.isEmpty else {
            return nil
        }

        guard let regex = shellPromptRegex else {
            return nil
        }

        let range = NSRange(
            value.startIndex..<value.endIndex,
            in: value
        )

        guard let match = regex.firstMatch(
            in: value,
            options: [],
            range: range
        ) else {
            return nil
        }

        guard let promptRange = Range(
            match.range,
            in: value
        ) else {
            return nil
        }

        return String(
            value[promptRange]
        )
        .trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    private func removeTrailingPrompt(
        from text: String,
        prompt: String
    ) -> String {

        guard let range = text.range(
            of: prompt,
            options: [
                .backwards
            ]
        ) else {
            return text
        }

        return String(
            text[..<range.lowerBound]
        )
        .trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    // MARK: - ANSI

    private func cleanANSI(
        _ text: String
    ) -> String {

        var result = text

        let patterns = [
            #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
            #"\u{001B}\][^\u{0007}]*\u{0007}"#,
            #"\u{001B}[()][0-2A-Z]"#,
            #"\u{001B}[=>]"#
        ]

        for pattern in patterns {

            if let regex = try? NSRegularExpression(
                pattern: pattern
            ) {

                let range = NSRange(
                    result.startIndex..<result.endIndex,
                    in: result
                )

                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: ""
                )
            }
        }

        /*
         删除退格造成的残留。
         */
        while result.contains("\u{08}") {

            var chars = Array(result)

            if let index = chars.firstIndex(
                of: "\u{08}"
            ) {

                if index > 0 {
                    chars.remove(
                        at: index - 1
                    )
                }

                chars.remove(
                    at: index
                )

                result = String(chars)

            } else {
                break
            }
        }

        return result
    }

    // MARK: - Terminal Line

    private func normalizeTerminalLine(
        _ text: String
    ) -> String {

        text
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .replacingOccurrences(
                of: "\u{08}",
                with: ""
            )
    }

    // MARK: - Command Split

    private func splitCommands(
        _ input: String
    ) -> [String] {

        var result: [String] = []

        var current = ""

        var singleQuote = false
        var doubleQuote = false
        var escaped = false

        for character in input {

            if escaped {

                current.append(character)
                escaped = false
                continue
            }

            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }

            if character == "'"
                && !doubleQuote {

                singleQuote.toggle()
                current.append(character)
                continue
            }

            if character == "\""
                && !singleQuote {

                doubleQuote.toggle()
                current.append(character)
                continue
            }

            if !singleQuote
                && !doubleQuote
                && (
                    character == ";"
                    || character == "\n"
                ) {

                let command = current
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )

                if !command.isEmpty {
                    result.append(command)
                }

                current = ""

                continue
            }

            current.append(character)
        }

        let finalCommand = current
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        if !finalCommand.isEmpty {
            result.append(finalCommand)
        }

        return result
    }
}
