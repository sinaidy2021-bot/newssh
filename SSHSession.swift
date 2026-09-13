import Foundation
import UIKit
import Combine
import Citadel
import NIOCore
import NIOSSH

public struct CommandHistoryItem: Identifiable {
    public let id: UUID
    public let command: String
    public var output: String

    public init(command: String, output: String) {
        self.id = UUID()
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
    private var writeChain: Task<Void, Never>?

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
    private var activeInteractiveID: UUID?
    private var interactivePromptBuffer = ""
    private var markerBuffer = ""
    private var truncatedIDs = Set<UUID>()

    // 终端中用 shell marker 判断一条命令何时结束。
    private let commandEndMarker = "__MYSSH_DONE_7F3A9C__"

    // 防止单条命令超大输出拖垮 iPhone。
    private let maxOutputCharactersPerCommand = 300_000

    // 防止长期使用后历史无限增长。
    private let maxHistoryItems = 120

    // MARK: - ANSI 清理
    private enum ANSIState { case normal, escape, csi, osc, oscEscape }
    private var ansiState: ANSIState = .normal

    private func cleanANSI(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            switch ansiState {
            case .normal:
                if v == 0x1B { ansiState = .escape }
                else if v == 0x9B { ansiState = .csi }
                else if v == 0x9D { ansiState = .osc }
                else if v == 0x0D || v == 0x07 { }
                else if v < 0x20 && v != 0x09 && v != 0x0A { }
                else { result.unicodeScalars.append(scalar) }
            case .escape:
                if v == 0x5B { ansiState = .csi }
                else if v == 0x5D { ansiState = .osc }
                else if v == 0x1B { ansiState = .escape }
                else { ansiState = .normal }
            case .csi:
                if v >= 0x40 && v <= 0x7E { ansiState = .normal }
            case .osc:
                if v == 0x07 { ansiState = .normal }
                else if v == 0x1B { ansiState = .oscEscape }
            case .oscEscape:
                if v == 0x5C || v == 0x07 { ansiState = .normal }
                else if v == 0x1B { ansiState = .oscEscape }
                else { ansiState = .osc }
            }
        }
        return result
    }

    // MARK: - 连接
    func connect() {
        guard !isConnected else { return }

        flushTask?.cancel()
        flushTask = nil
        pendingOutput = ""
        pendingCommands.removeAll()
        activeInteractiveID = nil
        interactivePromptBuffer = ""
        markerBuffer = ""
        truncatedIDs.removeAll()
        ansiState = .normal

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
        if let interactiveID = activeInteractiveID {
            appendOutput(text, to: interactiveID)
            interactivePromptBuffer.append(text)
            if shellPromptAppeared(in: interactivePromptBuffer) {
                activeInteractiveID = nil
                interactivePromptBuffer = ""
            } else if interactivePromptBuffer.count > 2000 {
                interactivePromptBuffer = String(interactivePromptBuffer.suffix(1000))
            }
            return
        }

        markerBuffer.append(text)
        while let range = markerBuffer.range(of: commandEndMarker) {
            let before = String(markerBuffer[..<range.lowerBound])
            appendOutputToCurrentCommand(before)
            completeCurrentCommand()
            markerBuffer = String(markerBuffer[range.upperBound...])
        }

        let maxPrefix = min(commandEndMarker.count - 1, markerBuffer.count)
        var splitIndex = markerBuffer.endIndex
        if maxPrefix > 0 {
            for length in stride(from: maxPrefix, through: 1, by: -1) {
                let idx = markerBuffer.index(markerBuffer.endIndex, offsetBy: -length)
                if markerBuffer[idx...].hasPrefix(String(commandEndMarker.prefix(length))) {
                    splitIndex = idx
                    break
                }
            }
        }
        if splitIndex != markerBuffer.endIndex {
            appendOutputToCurrentCommand(String(markerBuffer[..<splitIndex]))
            markerBuffer = String(markerBuffer[splitIndex...])
        } else {
            appendOutputToCurrentCommand(markerBuffer)
            markerBuffer = ""
        }
    }

    private func appendOutputToCurrentCommand(_ text: String) {
        guard let pending = pendingCommands.first, !text.isEmpty else { return }
        appendOutput(text, to: pending.id, echoCommand: pending.command)
    }

    private func appendOutput(_ text: String, to id: UUID, echoCommand: String? = nil) {
        guard let index = history.firstIndex(where: { $0.id == id }), !truncatedIDs.contains(id) else { return }
        var output = history[index].output + text
        if let echoCommand {
            if output.hasPrefix(echoCommand + "\n") { output.removeFirst(echoCommand.count + 1) }
            else if output.hasPrefix(echoCommand) { output.removeFirst(echoCommand.count) }
        }
        if output.count >= maxOutputCharactersPerCommand {
            output = String(output.prefix(maxOutputCharactersPerCommand)) + "\n[输出过长，已限制显示]"
            truncatedIDs.insert(id)
        }
        history[index].output = output
    }

    private func shellPromptAppeared(in text: String) -> Bool {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? text
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: #"^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+:.*[#$] ?$"#, options: .regularExpression) != nil
    }

    private func appendHistory(_ item: CommandHistoryItem) {
        history.append(item)
        while history.count > maxHistoryItems {
            let protected = Set(pendingCommands.map { $0.id }).union(activeInteractiveID.map { [$0] } ?? [])
            guard let index = history.firstIndex(where: { !protected.contains($0.id) }) else { break }
            let removed = history.remove(at: index)
            truncatedIDs.remove(removed.id)
        }
    }

    // MARK: - 发送命令
    func sendCommand(_ command: String) {
        guard isConnected else { return }
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }

        let item = CommandHistoryItem(command: cmd, output: "")
        appendHistory(item)
        pendingCommands.append(PendingCommand(id: item.id, command: cmd))

        enqueueWrite("\(cmd)\nprintf '\\n\(commandEndMarker)\\n'\n") { [weak self] error in
            guard let self else { return }
            if let error { self.handleWriteFailure(id: item.id, error: error) }
        }
    }

    func sendInteractiveCommand(_ command: String) {
        guard isConnected else { return }
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        guard activeInteractiveID == nil else { return }

        let item = CommandHistoryItem(command: cmd, output: "")
        appendHistory(item)
        activeInteractiveID = item.id
        interactivePromptBuffer = ""

        enqueueWrite("\(cmd)\n") { [weak self] error in
            guard let self else { return }
            if let error {
                self.handleWriteFailure(id: item.id, error: error)
                if self.activeInteractiveID == item.id {
                    self.activeInteractiveID = nil
                    self.interactivePromptBuffer = ""
                }
            }
        }
    }

    private func handleWriteFailure(id: UUID, error: Error) {
        if let index = history.firstIndex(where: { $0.id == id }) {
            history[index].output = "写入失败：\(error.localizedDescription)"
        }
        pendingCommands.removeAll { $0.id == id }
        if activeInteractiveID == id {
            activeInteractiveID = nil
            interactivePromptBuffer = ""
        }
    }

    // MARK: - 控制键
    // 控制键直接进入同一个串行写入队列，不创建命令历史。
    func sendControl(_ value: String) {
        guard isConnected else { return }
        enqueueWrite(value)
    }

    func sendCtrlC() { sendControl("\u{03}") }
    func sendEscape() { sendControl("\u{1B}") }
    func sendSpace() { sendControl(" ") }
    func sendBackspace() { sendControl("\u{7F}") }

    // MARK: - 串行写入
    private func enqueueWrite(
        _ value: String,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard let writer = activeWriter else {
            completion?(NSError(
                domain: "MySSH",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "SSH 写入通道不存在"]
            ))
            return
        }

        let previous = writeChain
        let task = Task { [weak self] in
            if let previous { await previous.value }
            guard let self else { return }

            do {
                var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
                buffer.writeString(value)
                try await writer.write(buffer)
                completion?(nil)
            } catch {
                completion?(error)
                self.appendHistory(CommandHistoryItem(
                    command: "system",
                    output: "写入失败：\(error.localizedDescription)"
                ))
            }
        }
        writeChain = task
    }

    // MARK: - 断开
    func disconnect() {
        flushOutput()
        let clientToClose = client
        client = nil
        activeWriter = nil
        isConnected = false
        writeChain?.cancel()
        writeChain = nil
        pendingCommands.removeAll()
        activeInteractiveID = nil
        interactivePromptBuffer = ""
        markerBuffer = ""
        pendingOutput = ""

        appendHistory(CommandHistoryItem(
            command: "system",
            output: "已主动断开连接"
        ))

        Task { try? await clientToClose?.close() }
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
        activeInteractiveID = nil
        interactivePromptBuffer = ""
        markerBuffer = ""

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
        activeInteractiveID = nil
        interactivePromptBuffer = ""
        markerBuffer = ""
        pendingOutput = ""

        Task {
            try? await clientToClose?.close()
        }

        appendHistory(
            CommandHistoryItem(command: "system", output: "已主动断开连接")
        )
    }
}
