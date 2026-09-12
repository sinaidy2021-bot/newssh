import Foundation
import Citadel
import NIOCore
import NIOSSH

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
    private var activeWriter: TTYStdinWriter?
    
    var host: String = ""
    var port: Int = 22
    var username: String = "root"
    var password: String = ""

    private func cleanANSI(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: #"\x1B\[\?[0-9]+[hl]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\x1B\][^\x07\x1B]*(\x07|\x1B\\)?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\x1B\[[0-9;]*[mKHz]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\x1B[@-Z\\-_]|[\u001B\u009B][#()#?]*([\x20-\x7E]*)([@-~])"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\u{001B}", with: "")
        text = text.replacingOccurrences(of: "\u{009B}", with: "")
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
                
                let bannerOutput = try await client.executeCommand("uname -a")
                let bannerResult = String(buffer: bannerOutput)
                let cleanedBanner = self.cleanANSI(bannerResult).trimmingCharacters(in: .whitespacesAndNewlines)
                
                await MainActor.run {
                    self.client = client
                    self.isConnected = true
                    self.history.append(CommandHistoryItem(command: "system", output: cleanedBanner))
                }
                
                let ptyReq = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: 100,
                    terminalRowHeight: 40,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 0])
                )
                
                try await client.withPTY(ptyReq) { [weak self] stream, writer in
                    await MainActor.run {
                        self?.activeWriter = writer
                    }
                    
                    for try await event in stream {
                        let buffer: ByteBuffer
                        switch event {
                        case .stdout(let b): buffer = b
                        case .stderr(let b): buffer = b
                        }
                        
                        if let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                            // 【修复点】：在这里安全解包 self
                            guard let self = self else { return }
                            
                            let cleaned = self.cleanANSI(text)
                            guard !cleaned.isEmpty else { continue }
                            
                            await MainActor.run {
                                self.appendOutput(cleaned)
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.history.append(CommandHistoryItem(command: "system", output: "连接断开: \(error.localizedDescription)"))
                    self.isConnected = false
                    self.activeWriter = nil
                }
            }
        }
    }

    private func appendOutput(_ text: String) {
        if let lastIndex = self.history.indices.last {
            if self.history[lastIndex].command == "system" {
                self.history.append(CommandHistoryItem(command: "output", output: text))
            } else {
                var currentOutput = self.history[lastIndex].output + text
                let lastCmd = self.history[lastIndex].command
                
                if currentOutput.hasPrefix(lastCmd + "\n") {
                    currentOutput = String(currentOutput.dropFirst(lastCmd.count + 1))
                } else if currentOutput.hasPrefix(lastCmd) && currentOutput.contains("\n") {
                    let lines = currentOutput.components(separatedBy: "\n")
                    if lines.first?.trimmingCharacters(in: .whitespaces) == lastCmd {
                        currentOutput = lines.dropFirst().joined(separator: "\n")
                    }
                }
                self.history[lastIndex].output = currentOutput
            }
        } else {
            self.history.append(CommandHistoryItem(command: "output", output: text))
        }
    }

    func sendCommand(_ command: String) {
        guard isConnected else { return }

        let cmdToSend = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmdToSend.isEmpty else { return }

        DispatchQueue.main.async {
            self.history.append(CommandHistoryItem(command: cmdToSend, output: ""))
        }

        Task {
            do {
                if let writer = self.activeWriter {
                    var buffer = ByteBufferAllocator().buffer(capacity: cmdToSend.utf8.count + 1)
                    buffer.writeString(cmdToSend + "\n")
                    try await writer.write(buffer)
                }
            } catch {
                await MainActor.run {
                    if let lastIndex = self.history.indices.last {
                        self.history[lastIndex].output = "写入失败: \(error.localizedDescription)"
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
                self.activeWriter = nil
                self.isConnected = false
                self.history.append(CommandHistoryItem(command: "system", output: "已断开连接"))
            }
        }
    }
}
