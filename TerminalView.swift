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
        QuickCmd(name: "查看文件 (ls)", cmd: "ls -la"),
        QuickCmd(name: "磁盘空间 (df)", cmd: "df -h"),
        QuickCmd(name: "资源占用 (top)", cmd: "top -bn1 | head -n 20"),
        QuickCmd(name: "当前用户 (whoami)", cmd: "whoami"),
        QuickCmd(name: "当前目录 (pwd)", cmd: "pwd"),
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.terminalOutput.isEmpty ? "正在准备连接...\n" : session.terminalOutput)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        
                        Color.clear
                            .frame(height: 1)
                            .id("BOTTOM_ID")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: 450, alignment: .topLeading)
                }
                .background(Color.black)
                .onTapGesture {
                    isInputFocused = false
                }
                .onChange(of: session.terminalOutput, perform: { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation {
                            proxy.scrollTo("BOTTOM_ID", anchor: .bottom)
                        }
                    }
                })
            }

            HStack(spacing: 8) {
                TextField("输入 Linux 命令...", text: $inputCommand)
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
        if !session.terminalOutput.hasSuffix("\n") && !session.terminalOutput.isEmpty {
            session.terminalOutput += "\n"
        }
        session.terminalOutput += "$ \(cmd)\n"
        
        let finalCmd = cmd.hasSuffix("\n") ? cmd : "\(cmd)\n"
        session.sendCommand(finalCmd)
    }
}
