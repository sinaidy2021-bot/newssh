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
    private var stdinPipe: AsyncStream<ByteBuffer>.Continuation?

    func connect() {
        Task {
            do {
                // 1. 建立基础 SSH 连接（适配 Citadel 0.7+ 签名）
                let client = try await SSHClient.connect(
                    host: self.host,
                    port: self.port,
                    authenticationMethod: {
                        .passwordBased(username: self.username, password: self.password)
                    },
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )
                self.client = client
                self.isConnected = true
                self.history.append(HistoryItem(command: "连接成功", output: "已连接到 \(self.host)，交互通道已就绪..."))

                // 2. 创建用于持续输入的流
                let (stdinStream, continuation) = AsyncStream<ByteBuffer>.makeStream()
                self.stdinPipe = continuation

                // 3. 启动交互式终端流
                let stdoutStream = try await client.executeCommandStream(
                    "/bin/sh -i",
                    environment: [:],
                    in: stdinStream
                )

                // 4. 实时监听远端输出（支持回显、命令结果流）
                for try await chunk in stdoutStream {
                    let str = String(buffer: chunk)
                    let clean = str.replacingOccurrences(of: "\r", with: "")
                    
                    if !clean.isEmpty {
                        if self.history.isEmpty {
                            self.history.append(HistoryItem(command: "", output: clean))
                        } else {
                            let lastIndex = self.history.count - 1
                            self.history[lastIndex].output += clean
                            
                            // 防止过长文本导致 SwiftUI 卡顿
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
        self.stdinPipe?.yield(buffer)

        self.history.append(HistoryItem(command: trimmed, output: ""))
    }

    func sendCtrlC() {
        var buffer = ByteBufferAllocator().buffer(capacity: 1)
        buffer.writeBytes([0x03])
        self.stdinPipe?.yield(buffer)
    }

    func sendTab() {
        var buffer = ByteBufferAllocator().buffer(capacity: 1)
        buffer.writeBytes([0x09])
        self.stdinPipe?.yield(buffer)
    }

    func disconnect() {
        self.stdinPipe?.finish()
        self.stdinPipe = nil
        Task {
            try? await self.client?.close()
            self.client = nil
            self.isConnected = false
        }
    }
}
