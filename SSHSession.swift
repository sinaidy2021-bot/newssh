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
    
    var host = ""
    var port = 22
    var username = ""
    var password = ""
    
    private var client: SSHClient?
    // 直接持有 ExecCommandStream 用于写入标准输入
    private var execStream: ExecCommandStream?

    func connect() {
        Task {
            do {
                // 1. 握手认证
                let client = try await SSHClient.connect(
                    host: self.host,
                    port: self.port,
                    authenticationMethod: .passwordBased(username: self.username, password: self.password),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )
                self.client = client
                self.isConnected = true
                self.history.append(HistoryItem(command: "连接成功", output: "已连接到 \(self.host)，交互通道已就绪..."))

                // 2. 开启执行流，启动交互 Shell
                let stream = try await client.executeCommandStream("/bin/sh -i")
                self.execStream = stream

                // 3. 异步循环读取远端回显和执行结果
                for try await chunk in stream {
                    let str = String(buffer: chunk)
                    let clean = str.replacingOccurrences(of: "\r", with: "")
                    
                    if !clean.isEmpty {
                        if self.history.isEmpty {
                            self.history.append(HistoryItem(command: "", output: clean))
                        } else {
                            let lastIndex = self.history.count - 1
                            self.history[lastIndex].output += clean
                            
                            if self.history[lastIndex].output.count > 20000 {
                                self.history[lastIndex].output = String(self.history[lastIndex].output.suffix(15000))
                            }
                        }
                    }
                }
            } catch {
                self.history.append(HistoryItem(command: "连接失败", output: "\(error.localizedDescription)"))
                self.isConnected = false
            }
        }
    }

    func sendCommand(_ cmd: String) {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        
        var buffer = ByteBufferAllocator().buffer(capacity: trimmed.utf8.count + 1)
        buffer.writeString(trimmed + "\n")
        
        Task {
            try? await self.execStream?.write(buffer)
        }

        self.history.append(HistoryItem(command: trimmed, output: ""))
    }

    func sendCtrlC() {
        var buffer = ByteBufferAllocator().buffer(capacity: 1)
        buffer.writeBytes([0x03])
        Task {
            try? await self.execStream?.write(buffer)
        }
    }

    func sendTab() {
        var buffer = ByteBufferAllocator().buffer(capacity: 1)
        buffer.writeBytes([0x09])
        Task {
            try? await self.execStream?.write(buffer)
        }
    }

    func disconnect() {
        Task {
            self.execStream = nil
            try? await self.client?.close()
            self.client = nil
            self.isConnected = false
        }
    }
}
