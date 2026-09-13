import Foundation
import Citadel
import Combine
import NIO

struct HistoryItem: Identifiable {
    var id = UUID()
    var command: String
    var output: String
}

class SSHSession: ObservableObject {
    @Published var history: [HistoryItem] = []
    @Published var isConnected = false
    var host = ""
    var username = ""
    var password = ""
    private var client: SSHClient?
    private var stdinWriter: SSHChannelWriter?

    func connect() {
        Task {
            do {
                let settings = SSHClientSettings(
                    host: host,
                    authenticationMethod: {.passwordBased(username: self.username, password: self.password) },
                    hostKeyValidator:.acceptAnything(),
                    reconnect:.never
                )
                let client = try await SSHClient.connect(to: settings)
                self.client = client
                await MainActor.run {
                    self.isConnected = true
                    self.history.append(HistoryItem(command: "连接成功", output: "已连接到 \(self.host)，正在打开终端..."))
                }

                try await client.withPTY(
                    SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true,
                        term: "xterm-256color",
                        terminalCharacterWidth: 120,
                        terminalRowHeight: 40,
                        terminalPixelWidth: 0,
                        terminalPixelHeight: 0,
                        terminalModes:.init([.ECHO: 1])
                    )
                ) { output, writer in
                    self.stdinWriter = writer
                    await MainActor.run {
                        self.history.append(HistoryItem(command: "终端就绪", output: ""))
                    }
                    for try await chunk in output {
                        let str = String(buffer: chunk)
                        let clean = str.replacingOccurrences(of: "\r", with: "")
                        if!clean.isEmpty {
                            await MainActor.run {
                                if self.history.isEmpty {
                                    self.history.append(HistoryItem(command: "", output: clean))
                                } else {
                                    self.history[self.history.count - 1].output += clean
                                    // 限制历史长度，防止卡死
                                    if self.history[self.history.count - 1].output.count > 20000 {
                                        self.history[self.history.count - 1].output = String(self.history[self.history.count - 1].output.suffix(15000))
                                    }
                                }
                            }
                        }
                    }
                }

            } catch {
                await MainActor.run {
                    self.history.append(HistoryItem(command: "连接失败", output: "\(error)"))
                    self.isConnected = false
                }
            }
        }
    }

    func sendCommand(_ cmd: String) {
        let c = cmd.trimmingCharacters(in:.whitespacesAndNewlines)
        if c.isEmpty { return }
        Task {
            var buffer = ByteBufferAllocator().buffer(capacity: c.utf8.count + 1)
            buffer.writeString(c + "\n")
            try? await self.stdinWriter?.write(buffer)
        }
        // 本地也追加一条，方便复制整段
        DispatchQueue.main.async {
            self.history.append(HistoryItem(command: c, output: ""))
        }
    }

    func sendCtrlC() {
        Task {
            var buffer = ByteBufferAllocator().buffer(capacity: 1)
            buffer.writeBytes([0x03])
            try? await self.stdinWriter?.write(buffer)
        }
    }

    func sendTab() {
        Task {
            var buffer = ByteBufferAllocator().buffer(capacity: 1)
            buffer.writeBytes([0x09])
            try? await self.stdinWriter?.write(buffer)
        }
    }

    func disconnect() {
        Task {
            try? await self.client?.close()
        }
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
}
