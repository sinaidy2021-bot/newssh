import SwiftUI

// 快捷命令结构体（带中文说明）
struct QuickCmd: Identifiable {
    let id = UUID()
    let name: String   // 中文标签
    let cmd: String    // 实际命令
}

struct TerminalView: View {
    let serverName: String
    @StateObject private var session = SSHSession()
    @State private var inputCommand: String = ""
    @FocusState private var isInputFocused: Bool
    
    // 带中文说明的常用快捷键列表
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
            // 顶部带中文说明的横向滚动快捷栏
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

            // 终端黑色输出窗口
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.terminalOutput.isEmpty ? "Connecting to \(serverName)...\n" : session.terminalOutput)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("BOTTOM")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: 450, alignment: .topLeading)
                }
                .background(Color.black)
                // 1. 点空白区域收起键盘
                .onTapGesture {
                    isInputFocused = false
                }
                // 2. 屏幕滑动时交互收起键盘
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: session.terminalOutput) { _ in
                    withAnimation {
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                }
            }

            // 底部命令行输入框
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
        .onAppear {
            session.connect()
        }
        .onDisappear {
            session.disconnect()
        }
    }

    private func executeCurrentInput() {
        let cmd = inputCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        runCommand(cmd)
        inputCommand = ""
    }

    private func runCommand(_ cmd: String) {
        // 执行命令时自动隐藏键盘，避免遮挡输出
        isInputFocused = false
        session.sendCommand(cmd)
    }
}
