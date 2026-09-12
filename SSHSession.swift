import Foundation
import Citadel

class SSHSession: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var terminalOutput: String = ""
    
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
        self.terminalOutput = "正在连接到服务器...\n"
        
        Task {
            do {
                // 彻底去掉不兼容的 reconnect 参数，使用标准安全的参数重载
                let client = try await SSHClient.connect(
                    host: self.host,
                    port: .init(integerLiteral: self.port),
                    authenticationMethod: .passwordBased(username: self.username, password: self.password),
                    hostKeyValidator: .acceptAnything()
                )
                
                await MainActor.run {
                    self.client = client
                    self.isConnected = true
                    self.terminalOutput += "连接成功！\n$ "
                }
            } catch {
                await MainActor.run {
                    self.terminalOutput += "连接失败: \(error.localizedDescription)\n"
                }
            }
        }
    }

    func sendCommand(_ command: String) {
        guard isConnected, let client = self.client else {
            self.terminalOutput += "错误: 未建立连接\n"
            return
        }

        let cmdToSend = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmdToSend.isEmpty else { return }

        Task {
            do {
                let output = try await client.executeCommand("export TERM=xterm-256color; " + cmdToSend)
                let result = String(buffer: output)
                
                let cleaned = cleanANSI(result)
                await MainActor.run {
                    self.terminalOutput += cleaned
                    if !cleaned.hasSuffix("\n") {
                        self.terminalOutput += "\n"
                    }
                    self.terminalOutput += "$ "
                }
            } catch {
                await MainActor.run {
                    self.terminalOutput += "执行失败: \(error.localizedDescription)\n$ "
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
                self.terminalOutput += "\n已断开连接\n"
            }
        }
    }
}
