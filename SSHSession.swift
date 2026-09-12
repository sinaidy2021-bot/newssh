import Foundation
import Citadel
import NIOCore

class SSHSession: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var history: [CommandHistoryItem] = []
    
    private var client: SSHClient?
    private var shellStream: SSHChannel?
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
                
                // 开启交互式 Shell 终端通道
                let shell = try await client.executeShell(term: "xterm-256color")
                
                await MainActor.run {
                    self.client = client
                    self.isConnected = true
                    self.history.append(CommandHistoryItem(command: "system", output: "连接成功！交互式终端已就绪。"))
                }
                
                // 持续监听服务器返回的数据流
                for try await var buffer in shell.inbound {
                    if let string = buffer.readString(length: buffer.readableBytes) {
                        let cleaned = self.cleanANSI(string)
                        await MainActor.run {
                            if !self.history.isEmpty {
                                self.history[self.history.count - 1].output += cleaned
                            } else {
                                self.history.append(CommandHistoryItem(command: "output", output: cleaned))
                            }
                        }
                    }
                }
                
            } catch {
                await MainActor.run {
                    self.history.append(CommandHistoryItem(command: "system", output: "连接或会话出错: \(error.localizedDescription)"))
                    self.isConnected = false
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

        // 在历史记录中新增一条命令卡片
        DispatchQueue.main.async {
            self.history.append(CommandHistoryItem(command: cmdToSend, output: ""))
        }

        Task {
            do {
                // 通过标准输入向远程 Shell 发送命令
                // 注意：交互式脚本需要带上回车 \n
                var buffer = client.allocator.buffer(capacity: cmdToSend.utf8.count + 1)
                buffer.writeString(cmdToSend + "\n")
                
                // 这里利用 client 执行单次或通过 shell 写入
                let output = try await client.executeCommand("export TERM=xterm-256color; " + cmdToSend)
                let result = String(buffer: output)
                let cleaned = cleanANSI(result)
                let finalOutput = cleaned.isEmpty ? "(命令已执行，无输出)" : cleaned
                
                await MainActor.run {
                    if let lastIndex = self.history.indices.last {
                        self.history[lastIndex].output = finalOutput
                    }
                }
            } catch {
                await MainActor.run {
                    if let lastIndex = self.history.indices.last {
                        self.history[lastIndex].output = "执行出错: \(error.localizedDescription)"
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
                self.isConnected = false
                self.history.append(CommandHistoryItem(command: "system", output: "已断开连接"))
            }
        }
    }
}
