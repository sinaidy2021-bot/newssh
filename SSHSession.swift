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
                // 1. 认证与握手连接
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

                // 2. 双向交互流：新版本 executeCommandPair 返回的是 ExecCommandStream 对象
                // 👇 修复：不再使用元组解包 (stdinWriter, stdoutStream)，改为直接接收对象
                let execStream = try await client.executeCommandPair("/bin/sh -i")
                
                // 从对象中取出输入流和输出流
                let stdinWriter = execStream.stdin
                let stdoutStream = execStream.stdout

                // 创建输入流中继管道
                let (stdinStream, continuation) = AsyncStream<ByteBuffer>.makeStream()
                self.stdinPipe = continuation

                // 将内部管道的数据持续推送给 Citadel 的输入流
                Task {
                    for await chunk in stdinStream {
                        try? await stdinWriter.write(chunk)
                    }
                }

                // 3. 异步读取远程终端回显与输出
                for try await chunk in stdoutStream {
                    let str = String(buffer: chunk)
                    let clean = str.replacingOccurrences(of: "\r", with: "")
                    
                    if !clean.isEmpty {
                        if self.history.isEmpty {
                            self.history.append(HistoryItem(command: "", output: clean))
                        } else {
                            let lastIndex = self.history.count - 1
                            self.history[lastIndex].output += clean
                            
                            // 防止大量输出撑爆内存和卡死 UI
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
