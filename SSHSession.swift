import Foundation
import Citadel

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
                    self.history.append(CommandHistoryItem(command: "system", output: "连接成功！"))
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

        let index = history.count
        DispatchQueue.main.async {
            self.history.append(CommandHistoryItem(command: cmdToSend, output: "执行中..."))
        }

        Task {
            do {
                let output = try await client.executeCommand("export TERM=xterm-256color; " + cmdToSend)
                let result = String(buffer: output)
                let cleaned = cleanANSI(result)
                let finalOutput = cleaned.isEmpty ? "(命令已执行，无输出)" : cleaned
                
                await MainActor.run {
                    if self.history.indices.contains(index) {
                        self.history[index] = CommandHistoryItem(command: cmdToSend, output: finalOutput)
                    }
                }
            } catch {
                await MainActor.run {
                    if self.history.indices.contains(index) {
                        self.history[index] = CommandHistoryItem(command: cmdToSend, output: "执行出错: \(error.localizedDescription)")
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
