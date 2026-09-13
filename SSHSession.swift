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
    // 之前的正则只覆盖了 [mKHz] 几种结束字母，清屏(J)、光标移动(A/B/C/D)等
    // 常见 CSI 序列没被过滤，会在输出里留下控制码碎片。这里改成通用匹配：
    // ESC [ 参数字节 任意字母结尾，覆盖所有标准 CSI 序列。
    private func cleanANSI(_ raw: String) -> String {
        var text = raw

        // OSC 序列：ESC ] ... 以 BEL 或 ESC \ 结束（例如设置窗口标题）
        text = text.replacingOccurrences(
            of: #"\x1B\][^\x07\x1B]*(\x07|\x1B\\)?"#,
            with: "", options: .regularExpression)

        // CSI 序列：ESC [ 参数(数字/;/?) 任意字母结尾
        // 覆盖颜色(m)、清屏(J)、清行(K)、光标定位/移动(H/A/B/C/D)、
        // 备用屏幕切换(?1049h/l)等全部标准控制序列
        text = text.replacingOccurrences(
            of: #"\x1B\[[0-9;?]*[A-Za-z]"#,
            with: "", options: .regularExpression)

        // 其他双字符转义，例如字符集切换 ESC(B / ESC)0
        text = text.replacingOccurrences(
            of: #"\x1B[@-Z\\-_]"#,
            with: "", options: .regularExpression)

        // 兜底：清掉残留的裸 ESC / C1 控制符
        text = text.replacingOccurrences(of: "\u{001B}", with: "")
        text = text.replacingOccurrences(of: "\u{009B}", with: "")

        // 统一换行；单独出现的 \r（进度条式覆盖）直接丢弃，避免拆成大量空行
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "")

        return text
    }

    func connect() {
        guard !isConnected else { return }
        
        Task {
            do {
                let client = try await SSHClient.connect(
                    host: self.host,
                    port: .init(integerLiteral: self.port),
                    authenticationMethod: .passwordBased(username: self.username, password: self.password),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )
                
                await MainActor.run {
                    self.client = client
                    self.isConnected = true
                    if self.history.isEmpty {
                        self.history.append(CommandHistoryItem(command: "system", output: "连接成功：\(self.host)"))
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

                    // 连接建立后立刻关闭常见命令的自动分页（systemctl / journalctl / git / man 等），
                    // 避免终端被 less 这类交互式分页器"吃掉"按键，导致后续命令全部失效。
                    do {
                        var buffer = ByteBufferAllocator().buffer(capacity: 128)
                        buffer.writeString("export PAGER=cat SYSTEMD_PAGER=cat GIT_PAGER=cat MANPAGER=cat 2>/dev/null\n")
                        try await writer.write(buffer)
                    } catch {
                        // 静默失败即可，不影响正常连接流程
                    }

                    for try await event in stream {
                        let buffer: ByteBuffer
                        switch event {
                        case .stdout(let b): buffer = b
                        case .stderr(let b): buffer = b
                        }
                        
                        if let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                            guard let self = self else { return }
                            let cleaned = self.cleanANSI(text)
                            guard !cleaned.isEmpty else { continue }
                            
                            await MainActor.run {
                                self.appendOutput(cleaned)
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.history.append(CommandHistoryItem(command: "system", output: "连接断开或异常: \(error.localizedDescription)"))
                    self.isConnected = false
                    self.activeWriter = nil
                    self.stopKeepAlive()
                }
            }
        }
    }

    private func appendOutput(_ text: String) {
        guard let lastIndex = self.history.indices.last else {
            self.history.append(CommandHistoryItem(command: "system", output: text))
            return
        }

        if self.history[lastIndex].command == "system" {
            // 修复点：用户还没发送第一条命令之前到达的数据（登录横幅 / MOTD 等），
            // 之前会被包成一条 command 字段写死为 "output" 的伪命令块，导致界面上
            // 显示出一条根本不存在的命令 "root@xxx# output"。
            // 现在统一追加进当前的系统状态块里，不再新建伪命令项。
            var cleanedText = text
            if cleanedText.contains("System information as of") {
                if let range = cleanedText.range(of: "root@") {
                    cleanedText = String(cleanedText[range.lowerBound...])
                } else if let range2 = cleanedText.range(of: "Last login:") {
                    cleanedText = String(cleanedText[range2.lowerBound...])
                }
            }
            let existing = self.history[lastIndex].output
            self.history[lastIndex].output = existing.isEmpty ? cleanedText : existing + "\n" + cleanedText
        } else {
            var currentOutput = self.history[lastIndex].output + text
            let lastCmd = self.history[lastIndex].command

            if currentOutput.hasPrefix(lastCmd + "\n") {
                currentOutput = String(currentOutput.dropFirst(lastCmd.count + 1))
            } else if currentOutput.hasPrefix(lastCmd) && currentOutput.contains("\n") {
                let lines = currentOutput.components(separatedBy: "\n")
                if lines.first?.trimmingCharacters(in: .whitespaces) == lastCmd {
                    currentOutput = lines.dropFirst().joined(separator: "\n")
                }
            }
            self.history[lastIndex].output = currentOutput
        }
    }

    func sendCommand(_ command: String) {
        guard isConnected else { return }

        let cmdToSend = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmdToSend.isEmpty else { return }

        DispatchQueue.main.async {
            self.history.append(CommandHistoryItem(command: cmdToSend, output: ""))
        }

        Task {
            do {
                if let writer = self.activeWriter {
                    var buffer = ByteBufferAllocator().buffer(capacity: cmdToSend.utf8.count + 1)
                    buffer.writeString(cmdToSend + "\n")
                    try await writer.write(buffer)
                }
            } catch {
                await MainActor.run {
                    if let lastIndex = self.history.indices.last {
                        self.history[lastIndex].output = "写入失败: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func startKeepAlive() {
        stopKeepAlive()
        DispatchQueue.main.async {
            self.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
                guard let self = self, self.isConnected, let writer = self.activeWriter else { return }
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

    func appDidEnterBackground() {
        guard isConnected else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SSHKeepAlive") { [weak self] in
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

    func disconnect() {
        stopKeepAlive()
        endBackgroundTask()
        Task {
            try? await self.client?.close()
            await MainActor.run {
                self.client = nil
                self.activeWriter = nil
                self.isConnected = false
                self.history.append(CommandHistoryItem(command: "已主动断开连接"))
            }
        }
    }
}
