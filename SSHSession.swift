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

    func connect(
        host: String,
        port: Int,
        username: String,
        password: String
    ) async {

        status = "正在连接…"
        connected = false

        do {
            let settings = SSHClientSettings(
                host: host,
                port: port,
                authenticationMethod: {
                    .passwordBased(
                        username: username,
                        password: password
                    )
                },
                hostKeyValidator: .acceptAnything()
            )

            let sshClient = try await SSHClient.connect(to: settings)

            client = sshClient

            let request =
                SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: 120,
                    terminalRowHeight: 40,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([
                        .ECHO: 1
                    ])
                )

            connected = true
            status = "已连接"

            ttyTask = Task { [weak self, weak sshClient] in

                guard let self else {
                    return
                }

                do {
                    try await sshClient?.withPTY(request) {
                        inbound,
                        outbound in

                        await self.setWriter(outbound)

                        for try await output in inbound {

                            switch output {

                            case .stdout(let buffer):
                                let bytes =
                                    Array(buffer.readableBytesView)

                                await self.receive(bytes)

                            case .stderr(let buffer):
                                let bytes =
                                    Array(buffer.readableBytesView)

                                await self.receive(bytes)
                            }
                        }
                    }

                    await self.setDisconnected("连接已断开")

                } catch is CancellationError {

                    // 主动断开，不显示错误

                } catch {

                    await self.setDisconnected(
                        "连接已断开：\(error.localizedDescription)"
                    )
                }
            }

        } catch {

            connected = false
            status = "连接失败：\(error.localizedDescription)"
        }
    }

    private func setWriter(_ newWriter: TTYStdinWriter) {
        writer = newWriter
    }

    func write(_ text: String) {

        guard connected else {
            return
        }

        guard let writer else {
            return
        }

        let data = ByteBuffer(
            bytes: Array(text.utf8)
        )

        Task {
            do {
                try await writer.write(data)
            } catch {
                await setDisconnected(
                    "发送失败：\(error.localizedDescription)"
                )
            }
        }
    }

    func beginCommand(_ command: String) {

        guard connected else {
            return
        }

        blocks.append(
            SSHBlock(
                command: command,
                output: ""
            )
        )

        write(command + "\n")
    }

    func disconnect() {

        ttyTask?.cancel()
        ttyTask = nil

        writer = nil

        connected = false
        status = "未连接"

        let currentClient = client
        client = nil

        Task {
            try? await currentClient?.close()
        }
    }

    private func receive(_ bytes: [UInt8]) {

        terminalBytes.append(contentsOf: bytes)

        guard !blocks.isEmpty else {
            return
        }

        let text = String(
            decoding: bytes,
            as: UTF8.self
        )

        blocks[blocks.count - 1].output += text
    }

    private func setDisconnected(_ message: String) {

        connected = false
        status = message

        writer = nil
    }
}
