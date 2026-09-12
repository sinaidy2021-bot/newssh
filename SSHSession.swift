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
    private var ttyWriter: TTYStdinWriter?
    
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
                
                // 1. 抓取内核欢迎信息
                let bannerOutput = try await client.executeCommand("uname -a")
                let bannerResult = String(buffer: bannerOutput)
                let cleanedBanner = self.cleanANSI(bannerResult).trimmingCharacters(in: .whitespacesAndNewlines)
                
                await MainActor.run {
                    self.client = client
                    self.isConnected = true
                    self.history.append(CommandHistoryItem(command: "system", output: cleanedBanner))
                }
                
                // 2. 开启 PTY 交互会话
                try await client.withPTY { [weak self] events, writer in
                    await MainActor.run {
                        self?.ttyWriter = writer
                    }
                    
                    for try await event in events {
                        let buffer: ByteBuffer
                        switch event {
                        case .stdout(let b): buffer = b
                        case .stderr(let b): buffer = b
                        }
                        
                        if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                            guard let self = self else { return }
                            let cleaned = self.cleanANSI(str)
                            guard !cleaned.isEmpty else { continue }
                            
                            await MainActor.run {
                                if let lastIndex = self.history.indices.last, self.history[lastIndex].command != "system" {
                                    self.history[lastIndex].output += cleaned
                                } else {
                                    self.history.append(CommandHistoryItem(command: "output", output: cleaned))
                                }
                            }
                        }
                    }
                }
                
            } catch {
                await MainActor.run {
                    self.history.append(CommandHistoryItem(command: "system", output: "连接或通道关闭: \(error.localizedDescription)"))
                    self.isConnected = false
                    self.ttyWriter = nil
                }
            }
        }
    }

    func sendCommand(_ command: String) {
        guard isConnected else {
            self.history.append(CommandHistoryItem(command: command, output: "错误: 未连接到服务器"))
            return
        }

        let cmdToSend = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmdToSend.isEmpty else { return }

        // 追加一条新的命令展示卡片
        DispatchQueue.main.async {
            self.history.append(CommandHistoryItem(command: cmdToSend, output: ""))
        }

        Task {
            do {
                if let writer = self.ttyWriter {
                    // 通过交互通道把命令发给远端（带换行符模拟回车）
                    var buffer = ByteBufferAllocator().buffer(capacity: cmdToSend.utf8.count + 1)
                    buffer.writeString(cmdToSend + "\n")
                    try await writer.write(buffer)
                } else if let client = self.client {
                    // 后备单次执行
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
                self.ttyWriter = nil
                self.isConnected = false
                self.history.append(CommandHistoryItem(command: "system", output: "已断开连接"))
            }
        }
    }
}
