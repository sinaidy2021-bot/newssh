import Foundation
import Citadel
import NIOCore

class SSHSession: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var terminalOutput: String = ""
    
    private var client: SSHClient?
    // 隐藏底层类型，直接使用 Data 传递闭包
    private var stdinWriter: ((Data) -> Void)?
    
    // 服务器配置信息
    var host: String = ""
    var port: Int = 22
    var username: String = "root"
    var password: String = ""

    // 过滤 ANSI 颜色码与乱码
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
        self.terminalOutput += "正在建立交互式会话...\n"
        
        Task {
            do {
                let client = try await SSHClient.connect(
                    host: self.host,
                    authenticationMethod: .passwordBased(username: self.username, password: self.password),
                    hostKeyValidator: .acceptAnything()
                )
                self.client = client
                
                // 开启真正的交互式终端 (PTY)
                let (inbound, outbound) = try await client.openInteractiveTerminal(
                    environment: ["TERM": "xterm-256color"]
                )

                await MainActor.run {
                    self.isConnected = true
                    self.terminalOutput += "连接成功！已启动交互终端\n"
                }

                // 保存输入流闭包
                self.stdinWriter = { data in
                    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    Task {
                        try? await outbound.write(buffer)
                    }
                }

                // 持续监听服务器屏幕输出
                for try await chunk in inbound {
                    if let str = String(buffer: chunk) {
                        let cleaned = self.cleanANSI(str)
                        await MainActor.run {
                            self.terminalOutput += cleaned
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.terminalOutput += "连接中断: \(error.localizedDescription)\n"
                    self.isConnected = false
                }
            }
        }
    }

    func sendCommand(_ command: String) {
        guard isConnected else {
            self.terminalOutput += "\n未连接\n"
            return
        }

        // 发送给服务器必须带回车
        let payload = command.hasSuffix("\n") ? command : "\(command)\n"
        
        if let data = payload.data(using: .utf8) {
            stdinWriter?(data)
        }
    }

    func disconnect() {
        Task {
            try? await self.client?.close()
            await MainActor.run {
                self.client = nil
                self.stdinWriter = nil
                self.isConnected = false
                self.terminalOutput += "\n已断开连接\n"
            }
        }
    }
}
