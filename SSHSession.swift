import Foundation
import Combine
import NIOCore
import NIOSSH
import Citadel

// MARK: - Command History

struct CommandHistoryItem: Identifiable {
    let id: UUID
    let command: String

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

final class SSHSession: ObservableObject {

    // MARK: Published

    @Published private(set) var isConnected = false

    @Published private(set) var history: [CommandHistoryItem] = []

    @Published private(set) var currentPrompt = ""

    /*
     true:

     当前远程程序还没有返回 shell prompt。

     这意味着：

     read
     passwd
     apt
     sudo
     x-ui
     bash 菜单
     python
     等程序

     都可以继续接收输入。
     */
    @Published private(set) var commandIsRunning = false

    // MARK: Connection

    private var client: SSHClient?

    private var activeWriter: NIOAsyncWriter<ByteBuffer>?

    private var terminalTask: Task<Void, Never>?

    private var keepAliveTask: Task<Void, Never>?

    // MARK: Credentials

    private var host = ""

    private var port = 22

    private var username = ""

    private var password = ""

    // MARK: Command Queue

    private var pendingCommandIDs: [UUID] = []

    private var pendingCommands: [UUID: String] = [:]

    private var commandIsStarting = false

    // 当前正在运行的历史块
    private var activeCommandID: UUID?

    // shell 回显的第一条 command 是否需要过滤
    private var waitingForInitialCommandEcho = false

    // 保存可能被 TCP/PTY 分割开的数据
    private var receiveBuffer = ""

    // MARK: Prompt

    private let promptRegex =
        #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^\r\n]*[#$]$"#

    // MARK: Init

    init() {}

    deinit {
        terminalTask?.cancel()
        keepAliveTask?.cancel()
    }

    // MARK: Connect

    func connect(
        host: String,
        port: Int,
        username: String,
        password: String
    ) {

        disconnect()

        self.host = host
        self.port = port
        self.username = username
        self.password = password

        Task { [weak self] in

            guard let self else {
                return
            }

            await self.performConnect()
        }
    }

    private func performConnect() async {

        do {

            let client = try await SSHClient.connect(
                host: host,
                port: .init(integerLiteral: port),
                authenticationMethod:
                    .passwordBased(
                        username: username,
                        password: password
                    ),
                hostKeyValidator:
                    .acceptAnything(),
                reconnect: .never
            )

            await MainActor.run {

                self.client = client
                self.isConnected = true

                self.history.removeAll()

                self.pendingCommandIDs.removeAll()

                self.pendingCommands.removeAll()

                self.activeCommandID = nil

                self.commandIsRunning = false

                self.currentPrompt = ""
            }

            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                term: "xterm-256color",
                terminalModes: .init([
                    .ECHO: 1
                ]),
                width: 120,
                height: 40,
                pixelWidth: 0,
                pixelHeight: 0
            )

            terminalTask = Task { [weak self] in

                guard let self else {
                    return
                }

                do {

                    try await client.withPTY(
                        ptyRequest
                    ) { stream, writer in

                        await MainActor.run {
                            self.activeWriter = writer
                        }

                        do {

                            for try await byteBuffer in stream {

                                if Task.isCancelled {
                                    break
                                }

                                let text =
                                    Self.decode(
                                        byteBuffer
                                    )

                                guard !text.isEmpty else {
                                    continue
                                }

                                await MainActor.run {

                                    self.receiveOutput(
                                        text
                                    )
                                }
                            }

                        } catch {

                            await MainActor.run {

                                self.handleTerminalError(
                                    error
                                )
                            }
                        }

                        await MainActor.run {
                            self.activeWriter = nil
                        }
                    }

                } catch {

                    await MainActor.run {

                        self.handleTerminalError(
                            error
                        )
                    }
                }
            }

            startKeepAlive()

        } catch {

            await MainActor.run {

                self.isConnected = false

                self.activeWriter = nil

                self.commandIsRunning = false

                self.history.append(
                    CommandHistoryItem(
                        command: "[SSH]",
                        prompt: "",
                        output:
                            "连接失败：\(error.localizedDescription)"
                    )
                )
            }
        }
    }

    // MARK: Disconnect

    func disconnect() {

        terminalTask?.cancel()
        terminalTask = nil

        keepAliveTask?.cancel()
        keepAliveTask = nil

        activeWriter = nil

        let oldClient = client
        client = nil

        pendingCommandIDs.removeAll()
        pendingCommands.removeAll()

        activeCommandID = nil

        commandIsStarting = false
        waitingForInitialCommandEcho = false

        commandIsRunning = false

        isConnected = false

        Task {

            try? await oldClient?.close()
        }
    }

    // MARK: Keep Alive

    private func startKeepAlive() {

        keepAliveTask?.cancel()

        keepAliveTask = Task { [weak self] in

            while !Task.isCancelled {

                try? await Task.sleep(
                    nanoseconds: 30_000_000_000
                )

                guard !Task.isCancelled else {
                    break
                }

                guard let self else {
                    break
                }

                await MainActor.run {

                    self.sendRaw("")
                }
            }
        }
    }

    // MARK: Submit Input

    /*
     这是整个修复的核心。

     TerminalView 不再区分：

         普通命令
         交互回答

     而是统一调用：

         submitInput()

     如果当前没有命令运行：

         "ls"
             ↓
         新建历史块
             ↓
         执行 ls

     如果当前已经有命令运行：

         apt install xxx
             ↓
         Continue? [Y/n]

         输入 y
             ↓
         submitInput("y")
             ↓
         直接写入当前 PTY

     不会创建：

         $ y

     这样的错误新命令。
     */

    func submitInput(
        _ text: String
    ) {

        guard isConnected else {
            return
        }

        let value = text

        if commandIsRunning {

            sendInteractiveInput(
                value
            )

        } else {

            sendCommand(
                value
            )
        }
    }

    // MARK: Interactive Input

    func sendInteractiveInput(
        _ text: String
    ) {

        guard isConnected else {
            return
        }

        guard let writer = activeWriter else {
            return
        }

        let input = text + "\n"

        Task {

            var buffer = ByteBuffer(
                allocator: ByteBufferAllocator()
            )

            buffer.writeString(input)

            do {

                try await writer.write(
                    buffer
                )

            } catch {

                await MainActor.run {

                    self.appendErrorToActiveCommand(
                        error
                    )
                }
            }
        }
    }

    // MARK: Send Command

    func sendCommand(
        _ command: String
    ) {

        guard isConnected else {
            return
        }

        let commands =
            splitCommands(
                command
            )

        guard !commands.isEmpty else {
            return
        }

        for command in commands {

            let id = UUID()

            let item =
                CommandHistoryItem(
                    id: id,
                    command: command,
                    prompt: currentPrompt,
                    output: ""
                )

            history.append(item)

            pendingCommandIDs.append(id)

            pendingCommands[id] = command
        }

        startNextQueuedCommand()
    }

    // MARK: Start Queue

    private func startNextQueuedCommand() {

        guard isConnected else {
            return
        }

        guard !commandIsRunning else {
            return
        }

        guard !commandIsStarting else {
            return
        }

        guard !pendingCommandIDs.isEmpty else {
            return
        }

        guard let writer = activeWriter else {
            return
        }

        let id =
            pendingCommandIDs.removeFirst()

        guard let command =
                pendingCommands.removeValue(
                    forKey: id
                )
        else {

            startNextQueuedCommand()

            return
        }

        activeCommandID = id

        commandIsRunning = true

        commandIsStarting = true

        waitingForInitialCommandEcho = true

        receiveBuffer = ""

        Task {

            var buffer = ByteBuffer(
                allocator: ByteBufferAllocator()
            )

            buffer.writeString(
                command + "\n"
            )

            do {

                try await writer.write(
                    buffer
                )

                await MainActor.run {

                    self.commandIsStarting = false
                }

            } catch {

                await MainActor.run {

                    self.commandIsStarting = false

                    self.commandIsRunning = false

                    self.activeCommandID = nil

                    self.waitingForInitialCommandEcho =
                        false

                    self.appendError(
                        to: id,
                        error: error
                    )

                    self.startNextQueuedCommand()
                }
            }
        }
    }

    // MARK: Raw Input

    func sendRaw(
        _ text: String
    ) {

        guard isConnected else {
            return
        }

        guard let writer = activeWriter else {
            return
        }

        guard !text.isEmpty else {
            return
        }

        Task {

            var buffer = ByteBuffer(
                allocator: ByteBufferAllocator()
            )

            buffer.writeString(text)

            do {

                try await writer.write(
                    buffer
                )

            } catch {

                await MainActor.run {

                    self.appendErrorToActiveCommand(
                        error
                    )
                }
            }
        }
    }

    // MARK: Receive Output

    private func receiveOutput(
        _ text: String
    ) {

        guard !text.isEmpty else {
            return
        }

        let cleaned =
            cleanANSI(
                text
            )

        guard !cleaned.isEmpty else {
            return
        }

        receiveBuffer += cleaned

        /*
         不要立刻处理最后一小段。

         因为 PTY 数据可能被分成：

             "root@ser"
             "ver:~# "

         两次到达。

         这里按换行处理，同时保留最后一段。
         */

        let normalized =
            receiveBuffer.replacingOccurrences(
                of: "\r",
                with: ""
            )

        let parts =
            normalized.components(
                separatedBy: "\n"
            )

        if parts.count <= 1 {

            processOutputChunk(
                normalized
            )

            receiveBuffer = ""

            return
        }

        let completeLines =
            parts.dropLast()

        receiveBuffer =
            parts.last ?? ""

        let completeText =
            completeLines.joined(
                separator: "\n"
            )

        if !completeText.isEmpty {

            processOutputChunk(
                completeText + "\n"
            )
        }

        if !receiveBuffer.isEmpty {

            if let prompt =
                extractTrailingPrompt(
                    from: receiveBuffer
                ) {

                receiveBuffer = ""

                processOutputChunk(
                    prompt
                )
            }
        }
    }

    // MARK: Process Output

    private func processOutputChunk(
        _ text: String
    ) {

        guard !text.isEmpty else {
            return
        }

        var value = text

        /*
         第一次收到输出时：

             shell ECHO=1

         会把：

             ls

         回显回来。

         历史块已经有：

             $ ls

         所以过滤掉第一次 command echo。

         后续：

             y
             n
             username
             etc.

         不会被过滤。
         */

        if waitingForInitialCommandEcho,
           let activeID = activeCommandID,
           let command =
                commandForHistory(
                    activeID
                ) {

            let stripped =
                removeInitialCommandEcho(
                    value,
                    command: command
                )

            if stripped.didFindEcho {

                value =
                    stripped.text

                waitingForInitialCommandEcho =
                    false
            }
        }

        guard !value.isEmpty else {
            return
        }

        /*
         检查最后是否出现 shell prompt。

         例如：

             root@server:~#

         或：

             user@host:/home/user$

         如果发现：

             当前命令结束
             ↓
             当前历史块完成
             ↓
             commandIsRunning = false
             ↓
             启动下一个排队命令
         */

        if let prompt =
            extractTrailingPrompt(
                from: value
            ) {

            let outputWithoutPrompt =
                removeTrailingPrompt(
                    from: value
                )

            if !outputWithoutPrompt.isEmpty {

                appendOutput(
                    outputWithoutPrompt
                )
            }

            currentPrompt = prompt

            finishActiveCommand()

            return
        }

        appendOutput(
            value
        )
    }

    // MARK: Append Output

    private func appendOutput(
        _ output: String
    ) {

        guard let id =
                activeCommandID else {

            /*
             连接刚建立时收到的欢迎信息、
             shell prompt 等，没有对应 command。

             放进一个系统历史块。
             */

            if !output.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {

                let item =
                    CommandHistoryItem(
                        command: "[SSH]",
                        prompt: currentPrompt,
                        output: output
                    )

                history.append(item)
            }

            return
        }

        guard let index =
                history.firstIndex(
                    where: {
                        $0.id == id
                    }
                )
        else {
            return
        }

        history[index].output += output
    }

    // MARK: Finish Command

    private func finishActiveCommand() {

        commandIsRunning = false

        commandIsStarting = false

        waitingForInitialCommandEcho = false

        activeCommandID = nil

        receiveBuffer = ""

        /*
         给 SwiftUI 一个事件循环机会。

         避免 prompt 到达时立刻递归启动
         很长的 command queue。
         */

        DispatchQueue.main.async { [weak self] in

            guard let self else {
                return
            }

            self.startNextQueuedCommand()
        }
    }

    // MARK: Error

    private func appendError(
        to id: UUID,
        error: Error
    ) {

        guard let index =
                history.firstIndex(
                    where: {
                        $0.id == id
                    }
                )
        else {
            return
        }

        history[index].output +=
            "\n[错误] \(error.localizedDescription)\n"
    }

    private func appendErrorToActiveCommand(
        _ error: Error
    ) {

        guard let id =
                activeCommandID else {
            return
        }

        appendError(
            to: id,
            error: error
        )
    }

    private func handleTerminalError(
        _ error: Error
    ) {

        isConnected = false

        activeWriter = nil

        commandIsRunning = false

        commandIsStarting = false

        activeCommandID = nil

        waitingForInitialCommandEcho = false

        history.append(
            CommandHistoryItem(
                command: "[SSH]",
                prompt: "",
                output:
                    "\n连接已断开：\(error.localizedDescription)\n"
            )
        )
    }

    // MARK: Command Lookup

    private func commandForHistory(
        _ id: UUID
    ) -> String? {

        history.first(
            where: {
                $0.id == id
            }
        )?.command
    }

    // MARK: Initial Echo

    private func removeInitialCommandEcho(
        _ text: String,
        command: String
    ) -> (
        text: String,
        didFindEcho: Bool
    ) {

        let expected =
            command
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

        guard !expected.isEmpty else {
            return (
                text,
                false
            )
        }

        let lines =
            text.components(
                separatedBy: .newlines
            )

        var mutable =
            lines

        for index in mutable.indices {

            let line =
                mutable[index]
                    .trimmingCharacters(
                        in: .whitespaces
                    )

            if line == expected {

                mutable.remove(
                    at: index
                )

                let result =
                    mutable.joined(
                        separator: "\n"
                    )

                return (
                    result,
                    true
                )
            }
        }

        return (
            text,
            false
        )
    }

    // MARK: Prompt Detection

    private func extractTrailingPrompt(
        from text: String
    ) -> String? {

        let normalized =
            text
                .replacingOccurrences(
                    of: "\r",
                    with: ""
                )
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

        guard !normalized.isEmpty else {
            return nil
        }

        let lines =
            normalized.components(
                separatedBy: "\n"
            )

        guard let last =
                lines.last else {
            return nil
        }

        let candidate =
            last.trimmingCharacters(
                in: .whitespaces
            )

        guard !candidate.isEmpty else {
            return nil
        }

        guard candidate.range(
            of: promptRegex,
            options: .regularExpression
        ) != nil else {
            return nil
        }

        return candidate
    }

    // MARK: Remove Prompt

    private func removeTrailingPrompt(
        from text: String
    ) -> String {

        let normalized =
            text
                .replacingOccurrences(
                    of: "\r",
                    with: ""
                )

        let lines =
            normalized.components(
                separatedBy: "\n"
            )

        guard let last =
                lines.last else {
            return normalized
        }

        let candidate =
            last.trimmingCharacters(
                in: .whitespaces
            )

        guard candidate.range(
            of: promptRegex,
            options: .regularExpression
        ) != nil else {
            return normalized
        }

        var result = lines

        result.removeLast()

        return result.joined(
            separator: "\n"
        )
    }

    // MARK: ANSI Cleaning

    private static func decode(
        _ buffer: ByteBuffer
    ) -> String {

        var buffer = buffer

        return buffer.readString(
            length: buffer.readableBytes
        ) ?? ""
    }

    private func cleanANSI(
        _ text: String
    ) -> String {

        var result = text

        /*
         CSI sequences
         */
        result = result.replacingOccurrences(
            of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )

        /*
         OSC sequences
         */
        result = result.replacingOccurrences(
            of: #"\u{001B}\][^\u{0007}]*\u{0007}"#,
            with: "",
            options: .regularExpression
        )

        /*
         其他 ESC
         */
        result = result.replacingOccurrences(
            of: #"\u{001B}[()][0-9A-Za-z]"#,
            with: "",
            options: .regularExpression
        )

        /*
         Backspace。
         不直接删除，因为某些程序可能使用
         backspace 重绘。

         这里仅清理明显的终端控制字符。
         */
        result = result.replacingOccurrences(
            of: "\u{0000}",
            with: ""
        )

        return result
    }

    // MARK: Split Commands

    private func splitCommands(
        _ command: String
    ) -> [String] {

        var result: [String] = []

        var current = ""

        var singleQuote = false
        var doubleQuote = false
        var backslash = false

        for character in command {

            if backslash {

                current.append(character)

                backslash = false

                continue
            }

            if character == "\\" {

                current.append(character)

                backslash = true

                continue
            }

            if character == "'",
               !doubleQuote {

                singleQuote.toggle()

                current.append(character)

                continue
            }

            if character == "\"",
               !singleQuote {

                doubleQuote.toggle()

                current.append(character)

                continue
            }

            if character == ";",
               !singleQuote,
               !doubleQuote {

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

        let final =
            current.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        if !final.isEmpty {
            result.append(final)
        }

        return result
    }
}
