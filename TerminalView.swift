import SwiftUI

// 中文快捷命令结构
struct QuickCmd: Identifiable {
    let id = UUID()
    let name: String
    let cmd: String
}

struct TerminalView: View {
    let serverName: String
    @ObservedObject var session: SSHSession
    @State private var inputCommand: String = ""
    @FocusState private var isInputFocused: Bool

    // 中文快捷指令栏
    let quickCommands: [QuickCmd] = [
        QuickCmd(name: "查看文件 (ls)", cmd: "ls -la"),
        QuickCmd(name: "磁盘空间 (df)", cmd: "df -h"),
        QuickCmd(name: "资源占用 (top)", cmd: "top -bn1 | head -n 20"),
        QuickCmd(name: "当前用户 (whoami)", cmd: "whoami"),
        QuickCmd(name: "当前目录 (pwd)", cmd: "pwd"),
        QuickCmd(name: "系统信息 (uname)", cmd: "uname -a"),
        QuickCmd(name: "内存使用 (free)", cmd: "free -h"),
        QuickCmd(name: "监听端口 (port)", cmd: "ss -tulpn | head -n 15")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部快捷命令栏
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

            // 黑色终端显示区域
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.terminalOutput.isEmpty ? "正在连接到服务器...\n" : session.terminalOutput)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        
                        // 底部锚点：确保永远滚到最底下
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
                .scrollDismissesKeyboard(.interactively)
                // 收到新输出时立即强制滚到最底端
                .onChange(of: session.terminalOutput) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation {
                            proxy.scrollTo("BOTTOM_ID", anchor: .bottom)
                        }
                    }
                }
            }

            // 底部输入栏
            HStack(spacing: 8) {
                TextField("输入 Linux 命令...", text: $inputCommand)
                    .focused($isInputFocused)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
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
                        session.connect()
                    }
                }
            }
        }
    }

    private func executeCurrentInput() {
        let cmd = inputCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        runCommand(cmd)
        inputCommand = ""
    }

    private func runCommand(_ cmd: String) {
        isInputFocused = false
        
        // 1. 本地立即回显输入的命令提示符
        if !session.terminalOutput.hasSuffix("\n") && !session.terminalOutput.isEmpty {
            session.terminalOutput += "\n"
        }
        session.terminalOutput += "$ \(cmd)\n"
        
        // 2. 确保命令末尾带回车换行符，否则 Linux 不会执行
        let finalCmd = cmd.hasSuffix("\n") ? cmd : "\(cmd)\n"
        session.sendCommand(finalCmd)
    }
}
