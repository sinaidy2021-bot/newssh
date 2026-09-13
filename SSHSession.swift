import Foundation
import Citadel
import Combine

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
    private var shell: SSHChannel?

    func connect() {
        Task {
            do {
                let client = try await SSHClient.connect(host: host, username: username, authMethod: SSHAuthMethod.password(password), hostValidator:.acceptAnything())
                DispatchQueue.main.async { self.isConnected = true }
                self.client = client
                let shell = try await client.openShell()
                self.shell = shell
                for try await data in shell.outputs {
                    if let text = String(data: data, encoding:.utf8) {
                        DispatchQueue.main.async {
                            let clean = text.trimmingCharacters(in:.whitespacesAndNewlines)
                            if!clean.isEmpty {
                                if self.history.isEmpty {
                                    self.history.append(HistoryItem(command: "连接成功", output: clean))
                                } else {
                                    self.history[self.history.count - 1].output += clean + "\n"
                                }
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.history.append(HistoryItem(command: "连接失败", output: "\(error)"))
                }
            }
        }
    }

    func sendCommand(_ cmd: String) {
        DispatchQueue.main.async {
            self.history.append(HistoryItem(command: cmd, output: ""))
        }
        Task {
            try? await shell?.write(cmd + "\n")
        }
    }

    func sendCtrlC() { Task { try? await shell?.write(Data([0x03])) } }
    func sendTab() { Task { try? await shell?.write(Data([0x09])) } }
    func disconnect() {
        Task { try? await shell?.close(); try? await client?.close() }
        DispatchQueue.main.async { self.isConnected = false }
    }
}
