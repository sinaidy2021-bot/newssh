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
    private var shellWriter: NIOAsyncChannelWriter<ByteBuffer>?
    
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
                
                // 1. 获取欢迎内核信息 (单次命令)
                let bannerOutput = try await client.executeCommand("uname -a")
                let bannerResult = String(buffer: bannerOutput)
                let cleanedBanner = self.cleanANSI(bannerResult).trimmingCharacters(in: .whitespacesAndNewlines)
                
                // 2. 建立交互式 Shell (PTY流)
                let shell = try await client.executeShell(term: "xterm-256color")
                
                await MainActor.run {
                    self.client = client
                    self.shellWriter = shell.writer
                    self.isConnected = true
                    self.history.append(CommandHistoryItem(command: "system", output: cleanedBanner))
                }
                
                // 3. 持续监听交互输出（完美支持 k 菜单动态渲染）
                Task {
                    do {
                        for try await var buffer in shell.inbound {
                            if let str = buffer.readString(length: buffer.readableBytes) {
                                let cleaned = self.cleanANSI(str)
                                await MainActor.run {
                                    if let lastIndex = self.history.indices.last {
                                        self.history[lastIndex].output += cleaned
                                    } else {
                                        self.history.append(CommandHistoryItem(command: "output", output: cleaned))
                                    }
                                }
                            }
                        }
                    } catch {
                        // 忽略流关闭异常
                    }
                }
                
            } catch {
                await MainActor.run {
                    self.history.append(CommandHistoryItem(command: "system", output: "连接失败: \(error.localizedDescription)"))
                }
            }
        }
    }

    func sendCommand(_ command: String) {
        guard isConnected, let client = self.client else {
            self.history.append(CommandHistoryItem(command: command, output: "错误: 未建立连接"))
            return
        }

        let cmdToSend = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmdToSend.isEmpty else { return }

        DispatchQueue.main.async {
            self.history.append(CommandHistoryItem(command: cmdToSend, output: ""))
        }

        Task {
            do {
                if var writer = self.shellWriter {
                    // 彻底修复 allocator 报错问题，使用标准 ByteBufferAllocator
                    let allocator = ByteBufferAllocator()
                    var buffer = allocator.buffer(capacity: cmdToSend.utf8.count + 1)
                    buffer.writeString(cmdToSend + "\n")
                    try await writer.write(buffer)
                } else {
                    // 降级保护方案
                    let output = try await client.executeCommand("export TERM=xterm-256color; " + cmdToSend)
                    let result = String(buffer: output)
                    let cleaned = self.cleanANSI(result)
                    await MainActor.run {
                        if let lastIndex = self.history.indices.last {
                            self.history[lastIndex].output = cleaned.isEmpty ? "(已执行，无输出)" : cleaned
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
