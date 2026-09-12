import SwiftUI

struct QuickCmd: Identifiable {
    let id = UUID()
    let name: String
    let cmd: String
}

struct TerminalView: View {
    let serverName: String
    let host: String
    let port: Int
    let username: String
    let password: String

    @StateObject private var session = SSHSession()
    @State private var inputCommand: String = ""
    @FocusState private var isInputFocused: Bool

    let quickCommands: [QuickCmd] = [
        QuickCmd(name: "输入 k 菜单", cmd: "k"),
        QuickCmd(name: "查看文件 (ls)", cmd: "ls -la"),
        QuickCmd(name: "磁盘空间 (df)", cmd: "df -h"),
        QuickCmd(name: "系统信息 (uname)", cmd: "uname -a")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickCommands) { item in
                        Button(action: {
                            runCommand(item.cmd)
                        }) {
                            Text(item.name)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray5))
                                .foregroundColor(.primary)
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Color(.systemBackground))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.history) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                if item.command == "system" {
                                    Text(item.output)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.yellow)
                                } else {
                                    // 经典的 root 提示符和命令样式
                                    Text("root@\(serverName):~# \(item.command)")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.cyan)
                                    
                                    // 结果支持独立复制
                                    Text(item.output.isEmpty ? "..." : item.output)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.green)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal, 8)
                            .id(item.id)
                        }
                        
                        Color.clear
                            .frame(height: 1)
                            .id("BOTTOM_ID")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(Color.black)
                .onTapGesture {
                    isInputFocused = false
                }
                .onChange(of: session.history.count, perform: { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation {
                            proxy.scrollTo("BOTTOM_ID", anchor: .bottom)
                        }
                    }
                })
            }

            HStack(spacing: 8) {
                TextField("输入命令 (如 k)...", text: $inputCommand)
                    .focused($isInputFocused)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                    .onSubmit {
                        executeCurrentInput()
                    }

                Button(action: {
                    executeCurrentInput()
                }) {
                    Text("发送")
                        .bold()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .foregroundColor(.white)
                        .background(Color.blue)
                        .cornerRadius(8)
                }
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .navigationTitle(serverName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(session.isConnected ? "断开" : "连接") {
                    if session.isConnected {
                        session.disconnect()
                    } else {
                        connectToServer()
                    }
                }
            }
        }
        .onAppear {
            connectToServer()
        }
        .onDisappear {
            session.disconnect()
        }
    }

    private func connectToServer() {
        session.host = host
        session.port = port
        session.username = username
        session.password = password
        session.connect()
    }

    private func executeCurrentInput() {
        let cmd = inputCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        runCommand(cmd)
        inputCommand = ""
    }

    private func runCommand(_ cmd: String) {
        isInputFocused = false
        session.sendCommand(cmd)
    }
}
