import Foundation
import UIKit
import Combine
import Citadel
import NIOCore
import NIOSSH

// MARK: - Command History

public struct CommandHistoryItem: Identifiable {
    public let id = UUID()

    /// 命令本身
    public let command: String

    /// 执行命令时的 Prompt
    public let prompt: String

    /// 当前命令产生的全部输出
    public var output: String

    public init(
        command: String,
        output: String = "",
        prompt: String = ""
    ) {
        self.command = command
        self.output = output
        self.prompt = prompt
    }
}

// MARK: - SSH Session

@MainActor
final class SSHSession: ObservableObject {

    // MARK: Published

    @Published var isConnected = false

    @Published var history: [CommandHistoryItem] = []

    @Published var currentPrompt = ""

    /// 当前是否有命令/程序正在运行
    @Published private(set) var commandIsRunning = false

    // MARK: SSH

    private var client: SSHClient?

    private var activeWriter: TTYStdinWriter?

    var host = ""
    var port = 22
    var username = "root"
    var password = ""

    // MARK: Background

    private var backgroundTask:
        UIBackgroundTaskIdentifier = .invalid

    private var keepAliveTimer: Timer?

    // MARK: Command Queue

    /// 已经创建历史块的命令 ID
    private var pendingCommandIDs: [UUID] = []

    /// 与 pendingCommandIDs 一一对应
    private var pendingCommands: [String] = []

    // MARK: ANSI

    private func cleanANSI(
        _ raw: String
    ) -> String {

        var text = raw

        // CSI 私有模式
        text = text.replacingOccurrences(
            of: #"\x1B\[\?[0-9;]*[hl]"#,
            with: "",
            options: .regularExpression
        )

        // OSC
        text = text.replacingOccurrences(
            of: #"\x1B\][^\x07\x1B]*(\x07|\x1B\\)?"#,
            with: "",
            options: .regularExpression
        )

        // 常见 ANSI
        text = text.replacingOccurrences(
            of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )

        // 其他 ESC
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

        // CRLF
        text = text.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )

        // 单独 CR
        text = text.replacingOccurrences(
            of: "\r",
            with: ""
        )

        return text
    }

    // MARK: Prompt

    private func fallbackPrompt() -> String {

        let symbol =
            username == "root"
            ? "#"
            : "$"

        return "\(username)@\(host):~\(symbol)"
    }

    private func isShellPrompt(
        _ line: String
    ) -> Bool {

        let value =
            line.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !value.isEmpty else {
            return false
        }

        let pattern =
            #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^\r\n]*[#$]$"#

        return value.range(
            of: pattern,
            options: .regularExpression
        ) != nil
    }

    private func extractTrailingPrompt(
        from text: String
    ) -> (
        prompt: String,
        output: String
    )? {

        let lines =
            text.components(
                separatedBy: "\n"
            )

        guard let index =
                lines.lastIndex(
                    where: {
                        !$0.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    }
                )
        else {
            return nil
        }

        let possiblePrompt =
            lines[index]
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

        guard isShellPrompt(
            possiblePrompt
        ) else {
            return nil
        }

        var outputLines = lines

        outputLines.remove(
            at: index
        )

        var output =
            outputLines.joined(
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

    // MARK: Connect

    func connect() {

        guard !isConnected else {
            return
        }

        Task {

            do {

                let client =
                    try await SSHClient.connect(
                        host: self.host,
                        port: .init(
                            integerLiteral: self.port
                        ),
                        authenticationMethod:
                            .passwordBased(
                                username: self.username,
                                password: self.password
                            ),
                        hostKeyValidator:
                            .acceptAnything(),
                        reconnect: .never
                    )

                self.client = client

                self.isConnected = true

                self.currentPrompt =
                    self.fallbackPrompt()

                self.pendingCommandIDs.removeAll()
                self.pendingCommands.removeAll()
                self.commandIsRunning = false

                self.history.removeAll()

                self.history.append(
                    CommandHistoryItem(
                        command: "system",
                        output:
                            "连接成功：\(self.host)"
                    )
                )

                self.startKeepAlive()

                let ptyReq =
                    SSHChannelRequestEvent
                        .PseudoTerminalRequest(
                            wantReply: true,
                            term: "xterm-256color",
                            terminalCharacterWidth: 120,
                            terminalRowHeight: 40,
                            terminalPixelWidth: 0,
                            terminalPixelHeight: 0,
                            terminalModes:
                                .init(
                                    [
                                        // 打开 ECHO。
                                        //
                                        // 这样：
                                        //
                                        // apt -> y
                                        // passwd -> 输入
                                        // top -> q
                                        //
                                        // 等交互输入可以正常显示。
                                        //
                                        // 密码程序通常会自行关闭 ECHO。
                                        .ECHO: 1
                                    ]
                                )
                        )

                try await client.withPTY(
                    ptyReq
                ) { [weak self] stream, writer in

                    guard let self else {
                        return
                    }

                    await MainActor.run {

                        self.activeWriter =
                            writer

                        self.startNextQueuedCommand()
                    }

                    do {

                        for try await event in stream {

                            let buffer: ByteBuffer

                            switch event {

                            case .stdout(let value):
                                buffer = value

                            case .stderr(let value):
                                buffer = value
                            }

                            guard let text =
                                    buffer.getString(
                                        at:
                                            buffer.readerIndex,
                                        length:
                                            buffer.readableBytes
                                    )
                            else {
                                continue
                            }

                            let cleaned =
                                self.cleanANSI(text)

                            guard !cleaned.isEmpty else {
                                continue
                            }

                            await MainActor.run {

                                self.receiveOutput(
                                    cleaned
                                )
                            }
                        }

                    } catch {

                        await MainActor.run {

                            self.handleDisconnect(
                                reason:
                                    error.localizedDescription
                            )
                        }
                    }
                }

            } catch {

                self.handleDisconnect(
                    reason:
                        error.localizedDescription
                )
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

        var incoming = text

        // ------------------------------------------------
        // 如果收到 Shell Prompt：
        //
        // 说明当前命令结束。
        // ------------------------------------------------

        if let result =
            extractTrailingPrompt(
                from: incoming
            ) {

            currentPrompt =
                result.prompt

            incoming =
                result.output

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

                    if !incoming.isEmpty {

                        history[index].output +=
                            incoming
                    }
                }

                commandIsRunning = false

                // 当前命令完成。
                //
                // 现在才允许下一条。
                startNextQueuedCommand()

                return
            }
        }

        guard !incoming.isEmpty else {
            return
        }

        // ------------------------------------------------
        // 当前有命令正在运行。
        //
        // 所有输出都进入当前命令块。
        // ------------------------------------------------

        if let activeID =
            pendingCommandIDs.first,
           let index =
            history.firstIndex(
                where: {
                    $0.id == activeID
                }
            ) {

            history[index].output +=
                incoming

            return
        }

        // ------------------------------------------------
        // 没有命令运行：
        //
        // SSH 登录欢迎信息。
        // ------------------------------------------------

        if let last =
            history.indices.last,
           history[last].command == "system" {

            history[last].output +=
                incoming

        } else {

            history.append(
                CommandHistoryItem(
                    command: "system",
                    output: incoming
                )
            )
        }
    }

    // MARK: Split Commands

    private func splitCommands(
        _ command: String
    ) -> [String] {

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

            if character == "\\"
                && !singleQuote {

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

            if character == ";"
                && !singleQuote
                && !doubleQuote {

                let value =
                    current.trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )

                if !value.isEmpty {

                    result.append(
                        value
                    )
                }

                current = ""

                continue
            }

            if character == "\n"
                && !singleQuote
                && !doubleQuote {

                let value =
                    current.trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )

                if !value.isEmpty {

                    result.append(
                        value
                    )
                }

                current = ""

                continue
            }

            current.append(
                character
            )
        }

        let finalValue =
            current.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        if !finalValue.isEmpty {

            result.append(
                finalValue
            )
        }

        return result
    }

    // MARK: Send Command

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

        for command in commands {

            let item =
                CommandHistoryItem(
                    command: command,
                    output: "",
                    prompt:
                        currentPrompt.isEmpty
                        ? fallbackPrompt()
                        : currentPrompt
                )

            history.append(
                item
            )

            pendingCommandIDs.append(
                item.id
            )

            pendingCommands.append(
                command
            )
        }

        startNextQueuedCommand()
    }

    // MARK: Start Next Command

    private func startNextQueuedCommand() {

        guard !commandIsRunning else {
            return
        }

        guard !pendingCommandIDs.isEmpty,
              !pendingCommands.isEmpty
        else {
            return
        }

        guard isConnected else {
            return
        }

        guard let writer =
                activeWriter
        else {
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

                        self.commandIsRunning =
                            false

                        return
                    }

                    self.history[index].output =
                        "写入失败：\(error.localizedDescription)"

                    self.pendingCommandIDs.removeFirst()

                    if !self.pendingCommands.isEmpty {

                        self.pendingCommands.removeFirst()
                    }

                    self.commandIsRunning =
                        false

                    self.startNextQueuedCommand()
                }
            }
        }
    }

    // MARK: Interactive Input

    /// 给当前正在运行的程序发送输入。
    ///
    /// 例如：
    ///
    /// apt -> y
    /// apt -> n
    /// menu -> 1
    /// menu -> 2
    /// passwd -> password
    /// top -> q
    ///
    /// 这些都不能进入命令队列。
    func sendInteractiveInput(
        _ value: String
    ) {

        guard isConnected else {
            return
        }

        guard let writer =
                activeWriter
        else {
            return
        }

        Task {

            do {

                var buffer =
                    ByteBufferAllocator()
                        .buffer(
                            capacity:
                                value.utf8.count
                        )

                buffer.writeString(
                    value
                )

                try await writer.write(
                    buffer
                )

            } catch {

                await MainActor.run {

                    self.appendSystemMessage(
                        "交互输入失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    // MARK: Raw Input

    func sendRaw(
        _ value: String
    ) {

        sendInteractiveInput(
            value
        )
    }

    // MARK: System Message

    private func appendSystemMessage(
        _ text: String
    ) {

        history.append(
            CommandHistoryItem(
                command: "system",
                output: text
            )
        )
    }

    // MARK: Keep Alive

    private func startKeepAlive() {

        stopKeepAlive()

        DispatchQueue.main.async {

            self.keepAliveTimer =
                Timer.scheduledTimer(
                    withTimeInterval: 25,
                    repeats: true
                ) { [weak self] _ in

                    guard let self,
                          self.isConnected,
                          let writer =
                            self.activeWriter
                    else {
                        return
                    }

                    Task {

                        var buffer =
                            ByteBufferAllocator()
                                .buffer(
                                    capacity: 1
                                )

                        // SSH 层保持连接。
                        //
                        // 不发送换行。
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

    // MARK: Background

    func appDidEnterBackground() {

        guard isConnected else {
            return
        }

        backgroundTask =
            UIApplication.shared
                .beginBackgroundTask(
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

            UIApplication.shared
                .endBackgroundTask(
                    backgroundTask
                )

            backgroundTask =
                .invalid
        }
    }

    // MARK: Disconnect

    func disconnect() {

        stopKeepAlive()

        endBackgroundTask()

        Task {

            try? await client?.close()

            await MainActor.run {

                self.client = nil

                self.activeWriter = nil

                self.isConnected = false

                self.pendingCommandIDs.removeAll()

                self.pendingCommands.removeAll()

                self.commandIsRunning = false

                self.appendSystemMessage(
                    "已主动断开连接"
                )
            }
        }
    }

    // MARK: Disconnect Handler

    private func handleDisconnect(
        reason: String
    ) {

        self.history.append(
            CommandHistoryItem(
                command: "system",
                output:
                    "连接断开：\(reason)"
            )
        )

        self.client = nil

        self.activeWriter = nil

        self.isConnected = false

        self.pendingCommandIDs.removeAll()

        self.pendingCommands.removeAll()

        self.commandIsRunning = false

        self.stopKeepAlive()
    }
}
