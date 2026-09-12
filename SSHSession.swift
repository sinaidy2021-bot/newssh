import Foundation
@preconcurrency import Citadel

@MainActor
final class SSHSession: ObservableObject {
    @Published var connected = false
    @Published var status = "未连接"
    @Published var blocks: [SSHBlock] = []

    private var client: SSHClient?

    func connect(profile: ServerProfile) async {
        status = "正在连接…"
        do {
            let c = try await SSHClient.connect(
                host: profile.host,
                port: profile.port,
                authenticationMethod: .passwordBased(username: profile.username, password: profile.password),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            client = c
            connected = true
            status = "已连接"
        } catch {
            status = "连接失败：\(error.localizedDescription)"
            connected = false
        }
    }

    func runCommand(_ command: String) {
        guard let client, connected else { return }
        let index = blocks.count
        blocks.append(SSHBlock(command: command, output: ""))

        Task {
            do {
                let stream = try await client.executeCommandStream(command)
                for try await event in stream {
                    switch event {
                    case .stdout(let buffer), .stderr(let buffer):
                        let text = String(buffer: buffer)
                        self.appendOutput(text, at: index)
                    }
                }
            } catch {
                self.appendOutput("执行失败：\(error.localizedDescription)\n", at: index)
            }
        }
    }

    private func appendOutput(_ text: String, at index: Int) {
        guard blocks.indices.contains(index) else { return }
        blocks[index].output += text
    }

    func disconnect() async {
        try? await client?.close()
        client = nil
        connected = false
        status = "未连接"
        blocks.removeAll()
    }
}
