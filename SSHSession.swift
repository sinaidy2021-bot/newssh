import Foundation
import Citadel
import Combine
import NIOCore
import NIOSSH

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
                // 1. 发起 SSH 连接
                let client = try await SSHClient.connect(
                    host: self.host,
                    port: self.port,
                    authentication: .passwordBased(username: self.username, password: self.password),
                    hostKeyValidator: .acceptAnything()
                )
                self.client = client
                self.isConnected = true
                self.history.append(HistoryItem(command: "连接成功", output: "已连接到 \(self.host)，正在打开终端..."))

                // 2. 建立 stdin 异步流，用于向远程输入内容
                let (stdinStream, continuation) = AsyncStream<ByteBuffer>.makeStream()
                self.stdinPipe = continuation

                self.history.append(HistoryItem(command: "终端就绪", output: ""))

                // 3. 申请 PTY 并启动 Shell 会话
                // Citadel 会自动执行与远端的 PTY 协商
                let stdoutStream = try await client.executeCommandStream(
                    "", // 空命令在很多 SSH 实现中代表启动默认 Shell；若服务器要求显式命令，可传 "/bin/sh" 或 "/bin/bash"
                    environment: [:],
                    in: stdinStream
                )

                // 4. 读取远端输出
                for try await chunk in stdoutStream {
                    let str = String(buffer: chunk)
                    let clean = str.replacingOccurrences(of: "\r", with: "")
                    
                    if !clean.isEmpty {
                        if self.history.isEmpty {
                            self.history.append(HistoryItem(command: "", output: clean))
                        } else {
                            let lastIdx = self.history.count - 1
                            self.history[lastIdx].output += clean
                            
                            // 限制历史长度，防止卡死
                            if self.history[lastIdx].output.count > 20000 {
                                self.history[lastIdx].output = String(self.history[lastIdx].output.suffix(15000))
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
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty { return }
        
        var buffer = ByteBufferAllocator().buffer(capacity: c.utf8.count + 1)
        buffer.writeString(c + "\n")
        self.stdinPipe?.yield(buffer)

        self.history.append(HistoryItem(command: c, output: ""))
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
            await MainActor.run {
                self.isConnected = false
            }
        }
    }
}
