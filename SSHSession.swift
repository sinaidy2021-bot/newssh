import Foundation
import Citadel
import NIOCore

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
    // 使用 Citadel 官方标准的交互式写入器
    private var shellWriter: TTYStdinWriter?
    
    var host: String = ""
    var port: Int = 22
    var username: String = "root"
    var password: String = ""

    private func cleanANSI(_ raw: String) -> String {
        var text = raw.replacingOccurrences(
            of: #"(\x1B\[|\x9B|\u001b\[)[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\[[0-9;]*[a-zA-Z]"#,
            with: "",
            options: .regularExpression
        )
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
                    self.history.append(CommandHistoryItem(command: "system", output: "连接成功，正在启动 PTY 交互终端..."))
                }
                
                // 配置交互式伪终端请求参数
                let ptyReq = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: 80,
                    terminalRowHeight: 24,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init()
                )
                
                // 开启 Citadel 官方支持的双向 PTY 会话管道
                try await client.withPTY(ptyReq) { ttyOutput, writer in
                    await MainActor.run {
                        self.shellWriter = writer
                        self.history.append(CommandHistoryItem(command: "system", output: "交互终端已完美就绪！(现在已支持 k 菜单等交互功能)"))
                    }
                    
                    // 持续监听服务器实时返回的数据流，逐字追加到 UI
                    for try await event in ttyOutput {
                        let buffer: ByteBuffer
                        switch event {
                        case .stdout(let b): buffer = b
                        case .stderr(let b): buffer = b
                        }
                        
                        if let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                            let cleaned = self.cleanANSI(string)
                            guard !cleaned.isEmpty else { continue }
                            
                            await MainActor.run {
                                if let lastIndex = self.history.indices.last {
                                    if self.history[lastIndex].command == "system" {
                                        // 过滤掉系统状态卡片，新建一条输出
                                        self.history.append(CommandHistoryItem(command: "output", output: cleaned))
                                    } else {
                                        // 追加入当前的命令块中
                                        self.history[lastIndex].output += cleaned
                                    }
                                } else {
                                    self.history.append(CommandHistoryItem(command: "output", output: cleaned))
                                }
                            }
                        }
                    }
                }
                
            } catch {
                await MainActor.run {
                    self.history.append(CommandHistoryItem(command: "system", output: "连接/会话异常: \(error.localizedDescription)"))
                    self.isConnected = false
                }
            }
        }
    }

    func sendCommand(_ command: String) {
        guard isConnected else { return }
        
        let cmdToSend = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmdToSend.isEmpty else { return }

        // 推入一条新命令块（带 root@ 前缀的 UI 卡片）
        DispatchQueue.main.async {
            self.history.append(CommandHistoryItem(command: cmdToSend, output: ""))
        }

        Task {
            do {
                if let writer = self.shellWriter {
                    // 【关键修复点】：完美写入交互命令，模拟真实键盘敲击并按下回车
                    var buffer = ByteBufferAllocator().buffer(capacity: cmdToSend.utf8.count + 1)
                    buffer.writeString(cmdToSend + "\n")
                    try await writer.write(buffer)
                } else if let client = self.client {
                    // 防御性降级：万一 PTY 通道没建起来，仍能单次执行
                    let output = try await client.executeCommand("export TERM=xterm-256color; " + cmdToSend)
                    let result = String(buffer: output)
                    let cleaned = self.cleanANSI(result)
                    
                    await MainActor.run {
                        if let lastIndex = self.history.indices.last {
                            self.history[lastIndex].output = cleaned.isEmpty ? "(已执行，无回显)" : cleaned
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    if let lastIndex = self.history.indices.last {
                        self.history[lastIndex].output = "发送出错: \(error.localizedDescription)"
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
                self.shellWriter = nil
                self.isConnected = false
                self.history.append(CommandHistoryItem(command: "system", output: "已断开连接"))
            }
        }
    }
}
