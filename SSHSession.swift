import Foundation
import Citadel
import Combine
import NIOCore

struct HistoryItem: Identifiable {
    var id = UUID()
    var command: String
    var output: String
}

@MainActor
class SSHSession: ObservableObject {
    @Published var history: [HistoryItem] = []
    @Published var isConnected = false
    @Published var isExecuting = false
    
    var host = ""
    var port = 22
    var username = ""
    var password = ""
    
    private var client: SSHClient?

    func connect() {
        Task {
            do {
                // 1. 发起连接
                let client = try await SSHClient.connect(
                    host: self.host,
                    port: self.port,
                    authenticationMethod: .passwordBased(username: self.username, password: self.password),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )
                self.client = client
                self.isConnected = true
                self.history.append(HistoryItem(command: "连接成功", output: "已连接到 \(self.host)"))
            } catch {
                self.history.append(HistoryItem(command: "连接失败", output: "\(error.localizedDescription)"))
                self.isConnected = false
            }
        }
    }

    func sendCommand(_ cmd: String) {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        
        guard let client = self.client else {
            self.history.append(HistoryItem(command: trimmed, output: "未连接到服务器"))
            return
        }

        // 添加到本地历史
        let itemIndex = self.history.count
        self.history.append(HistoryItem(command: trimmed, output: "正在执行..."))
        self.isExecuting = true

        Task {
            do {
                // Citadel 0.7+ 单命令标准执行 API
                let outputBuffer = try await client.executeCommand(trimmed)
                let text = String(buffer: outputBuffer)
                
                self.history[itemIndex].output = text.isEmpty ? "(无输出)" : text
            } catch {
                self.history[itemIndex].output = "执行出错: \(error.localizedDescription)"
            }
            self.isExecuting = false
        }
    }

    func sendCtrlC() {
        // 单命令模式下无需发送控制字符
    }

    func sendTab() {
        // 单命令模式下无需补全控制
    }

    func disconnect() {
        Task {
            try? await self.client?.close()
            self.client = nil
            self.isConnected = false
            self.history.append(HistoryItem(command: "断开连接", output: "连接已关闭"))
        }
    }
}
