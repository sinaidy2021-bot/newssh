import Foundation
import Combine
import NIOCore
import Citadel

struct SSHBlock: Identifiable, Sendable {
    let id = UUID()
    var command: String
    var output: String
}

@MainActor
final class SSHSession: ObservableObject {
    @Published var connected = false
    @Published var status = "未连接"
    @Published var blocks: [SSHBlock] = []
    @Published var terminalBytes: [UInt8] = []

    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var ttyTask: Task<Void, Never>?

    func connect(host: String, port: Int, username: String, password: String) async {
        status = "正在连接…"

        do {
            let settings = SSHClientSettings(
                host: host,
                port: port,
                authenticationMethod: {
                    .passwordBased(username: username, password: password)
                },
                hostKeyValidator: .acceptAnything()
            )

            let c = try await SSHClient.connect(to: settings)
            client = c

            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: 120,
                terminalRowHeight: 40,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: .init([.ECHO: 1])
            )

            let stream = try await c.withPTY(request)
            writer = TTYStdinWriter(stream.outbound)

            connected = true
            status = "已连接"

            ttyTask = Task { [weak self] in
                do {
                    for try await result in stream {
                        switch result {
                        case .stdout(let buffer), .stderr(let buffer):
                            let bytes = Array(buffer.readableBytesView)
                            await self?.receive(bytes)
                        }
                    }
                } catch {
                    await self?.setDisconnected("连接已断开：\(error.localizedDescription)")
                }
            }
        } catch {
            status = "连接失败：\(error.localizedDescription)"
            connected = false
        }
    }

    func write(_ text: String) {
        guard let writer else { return }
        writer.write(ByteBuffer(bytes: Array(text.utf8)))
    }

    func beginCommand(_ command: String) {
        guard connected else { return }
        blocks.append(SSHBlock(command: command, output: ""))
        write(command + "\n")
    }

    func disconnect() {
        ttyTask?.cancel()
        ttyTask = nil
        writer = nil
        client?.close()
        client = nil
        connected = false
        status = "未连接"
    }

    private func receive(_ bytes: [UInt8]) {
        terminalBytes.append(contentsOf: bytes)
        if !blocks.isEmpty {
            blocks[blocks.count - 1].output +=
                String(decoding: bytes, as: UTF8.self)
        }
    }

    private func setDisconnected(_ message: String) {
        status = message
        connected = false
    }
}
