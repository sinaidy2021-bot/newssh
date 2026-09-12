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

    // Shell 是串行执行的。
    // 队列第一个命令收到 Prompt 后，就代表该命令结束。
    private var pendingCommandIDs: [UUID] = []

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
                }
            }
        }
    }

    // MARK: - Receive Output

    private func appendOutput(
        _ text: String
    ) {

        var incomingText = text

        // 收到真实 Prompt
        if let promptResult =
            extractTrailingPrompt(
                from: incomingText
            ) {

            currentPrompt =
                promptResult.prompt

            incomingText =
                promptResult.output

            // 当前命令执行完成
            if !pendingCommandIDs.isEmpty {

                let finishedID =
                    pendingCommandIDs.removeFirst()

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

                return
            }
        }

        guard !incomingText.isEmpty else {
            return
        }

        // 有命令正在执行，
        // 输出只归属于队列第一个命令。
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

        // 没有等待命令：
        // 欢迎信息 / 系统信息
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
         这里只把真正的命令分隔符拆开。

         不会拆：
         && 
         ||
         因为这两个属于 Shell 条件执行，
         如果强行拆开会改变原来的执行逻辑。
        */

        var result: [String] = []

        let newlineParts =
            command.components(
                separatedBy: .newlines
            )

        for line in newlineParts {

            let parts =
                line.components(
                    separatedBy: ";"
                )

            for part in parts {

                let value =
                    part.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )

                if !value.isEmpty {
                    result.append(value)
                }
            }
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

        /*
         先在主线程建立完整历史队列，
         再开始发送。

         这样不会出现：
         “命令已经发出，但 pendingCommandIDs
          还没加入”的竞态问题。
        */

        let items =
            commands.map { cmd in

                CommandHistoryItem(
                    command: cmd,
                    output: "",
                    prompt:
                        currentPrompt.isEmpty
                        ? fallbackPrompt()
                        : currentPrompt
                )
            }

        for item in items {

            history.append(item)

            pendingCommandIDs.append(
                item.id
            )
        }

        Task {

            do {

                guard let writer =
                    self.activeWriter else {
                    return
                }

                /*
                 每个命令单独写入。

                 例如：

                 uname -a; df -h; free -h

                 实际发送：

                 uname -a\n
                 df -h\n
                 free -h\n

                 Shell 会分别返回 Prompt，
                 因此每个输出可以准确归属到
                 对应的历史块。
                */

                for cmd in commands {

                    var buffer =
                        ByteBufferAllocator()
                            .buffer(
                                capacity:
                                    cmd.utf8.count + 1
                            )

                    buffer.writeString(
                        cmd + "\n"
                    )

                    try await writer.write(
                        buffer
                    )
                }

            } catch {

                await MainActor.run {

                    if let firstPendingID =
                        self.pendingCommandIDs.first,
                       let index =
                        self.history.firstIndex(
                            where: {
                                $0.id == firstPendingID
                            }
                        ) {

                        self.history[index].output =
                            "写入失败: \(error.localizedDescription)"

                        self.pendingCommandIDs.removeFirst()
                    }
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
