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
                        Button(action: { runCommand(item.cmd) }) {
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
                                        .textSelection(.enabled)
                                } else {
                                    Text("root@\(serverName)~# \(item.command)")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.cyan)
                                    
                                    Text(item.output)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.green)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal, 8)
                            .id(item.id)
                        }
                        // 底部锚点
                        Color.clear.frame(height: 20).id("BOTTOM_ANCHOR")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(Color.black)
                .onTapGesture { isInputFocused = false }
                // 监听历史记录条数变化与最后一条输出的动态刷新，双重保障自动滚到底部
                .onChange(of: session.history.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: session.history.last?.output) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            HStack(spacing: 8) {
                TextField("输入交互回复或命令...", text: $inputCommand)
                    .focused($isInputFocused)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                    .onSubmit { executeCurrentInput() }

                Button(action: { executeCurrentInput() }) {
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
                    if session.isConnected { session.disconnect() }
                    else { connectToServer() }
                }
            }
        }
        .onAppear { connectToServer() }
        .onDisappear { session.disconnect() }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
            }
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
