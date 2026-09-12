import Foundation
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

    // 缓冲区及性能节流队列
    private var pendingBuffer: String = ""
    private var updateWorkItem: DispatchWorkItem?
    private let updateQueue = DispatchQueue(label: "com.ssh.terminal.parser", qos: .userInteractive)

    private func cleanANSI(_ raw: String) -> String {
        var text = raw
        // 1. 彻底清除 OSC 终端控制码（包括 ]0;root@... 等窗口标题设置）
        text = text.replacingOccurrences(
            of: #"\x1B\][^\x07\x1B]*(\x07|\x1B\\)?"#,
            with: "",
            options: .regularExpression
        )
        // 2. 清除标准 ANSI/CSI 颜色与控制序列
        text = text.replacingOccurrences(
            of: #"(\x1B\[|\x9B|\u{001B}\[[0-?]*[ -/]*[@-~])"#,
            with: "",
            options: .regularExpression
        )
        // 3. 清除光标与模式切换符号
        text = text.replacingOccurrences(
            of: #"\x1B[=@>]"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\[[0-9;]*[a-zA-Z]"#,
            with: "",
            options: .regularExpression
        )
        // 4. 标准化换行符
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
                
                // 自动拉取系统内核信息
                let bannerOutput = try await client.executeCommand("uname -a")
                let bannerResult = String(buffer: bannerOutput)
                let cleanedBanner = self.cleanANSI(bannerResult).trimmingCharacters(in: .whitespacesAndNewlines)
                
                await MainActor.run {
                    self.client = client
                    self.isConnected = true
                    self.history.append(CommandHistoryItem(command: "system", output: cleanedBanner))
                }
                
                // 开启标准的交互式 PTY 管道
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
                        case .stdout(let b): buffer = b
                        case .stderr(let b): buffer = b
                        }
                        
                        if let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                            self?.enqueueOutput(text)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.history.append(CommandHistoryItem(command: "system", output: "连接断开: \(error.localizedDescription)"))
                    self.isConnected = false
                    self.activeWriter = nil
                }
            }
        }
    }

    // 后台节流聚合：消除卡顿与命令回显重复
    private func enqueueOutput(_ text: String) {
        updateQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingBuffer += text
            
            self.updateWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let chunk = self.pendingBuffer
                self.pendingBuffer = ""
                let cleaned = self.cleanANSI(chunk)
                guard !cleaned.isEmpty else { return }
                
                DispatchQueue.main.async {
                    if let lastIndex = self.history.indices.last {
                        if self.history[lastIndex].command == "system" {
                            self.history.append(CommandHistoryItem(command: "output", output: cleaned))
                        } else {
                            var currentOutput = self.history[lastIndex].output + cleaned
                            let lastCmd = self.history[lastIndex].command
                            
                            // 去重：消除远端终端在首行自动回显的命令字符
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
                    } else {
                        self.history.append(CommandHistoryItem(command: "output", output: cleaned))
                    }
                }
            }
            self.updateWorkItem = workItem
            // 35ms 聚合一次，兼顾流畅度与打字实时性
            self.updateQueue.asyncAfter(deadline: .now() + 0.035, execute: workItem)
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

    func disconnect() {
        Task {
            try? await self.client?.close()
            await MainActor.run {
                self.client = nil
                self.activeWriter = nil
                self.isConnected = false
                self.history.append(CommandHistoryItem(command: "system", output: "已断开连接"))
            }
        }
    }
}
