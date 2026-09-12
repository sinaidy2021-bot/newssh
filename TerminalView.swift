import SwiftUI
import UniformTypeIdentifiers

struct QuickCmd: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var cmd: String
}

struct TerminalView: View {
    let serverName: String
    let host: String
    let port: Int
    let username: String
    let password: String

    @StateObject private var session = SSHSession()
    @State private var inputCommand: String = ""
    @FocusState private var isSystemKeyboardFocused: Bool

    @State private var showMiniKeyboard: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    @State private var quickCommands: [QuickCmd] = []
    @State private var showingAddSheet = false
    @State private var newCmdName = ""
    @State private var newCmdContent = ""
    @State private var copiedTip: String? = nil

    private let storageKey = "SavedQuickCommands"

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 顶部快捷键栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: { showingAddSheet = true }) {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                Text("添加")
                            }
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.blue.opacity(0.3))
                            .foregroundColor(.blue)
                            .cornerRadius(6)
                        }

                        ForEach(quickCommands) { item in
                            Button(action: { runCommand(item.cmd) }) {
                                Text(item.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Color(white: 0.18))
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteQuickCmd(item)
                                } label: {
                                    Label("删除快捷键", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .background(Color(white: 0.12))

                // 终端主体
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(session.history) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    if item.command == "system" {
                                        HStack {
                                            Text("[系统状态]")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundColor(.yellow.opacity(0.8))
                                            Spacer()
                                            Button(action: {
                                                copyBlock(item.output, tip: "已复制系统信息")
                                            }) {
                                                Image(systemName: "doc.on.doc")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.gray)
                                            }
                                        }
                                        renderOutputLines(item.output, defaultColor: .yellow)
                                    } else {
                                        HStack(alignment: .center) {
                                            Text("root@\(serverName)~# \(item.command)")
                                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                                .foregroundColor(.cyan)
                                                .textSelection(.enabled)
                                            
                                            Spacer()
                                            
                                            Button(action: {
                                                let fullBlock = "root@\(serverName)~# \(item.command)\n" + item.output
                                                copyBlock(fullBlock, tip: "已复制整段命令与输出")
                                            }) {
                                                HStack(spacing: 3) {
                                                    Image(systemName: "doc.on.doc")
                                                    Text("复制整段")
                                                }
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(.gray)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Color(white: 0.18))
                                                .cornerRadius(4)
                                            }
                                        }
                                        
                                        renderOutputLines(item.output, defaultColor: .green)
                                    }
                                }
                                .padding(8)
                                .background(Color(white: 0.05))
                                .cornerRadius(6)
                                .contextMenu {
                                    Button {
                                        copyBlock(item.output, tip: "已复制输出内容")
                                    } label: {
                                        Label("复制本段输出", systemImage: "doc.on.doc")
                                    }
                                    if item.command != "system" {
                                        Button {
                                            copyBlock(item.command, tip: "仅复制命令")
                                        } label: {
                                            Label("仅复制命令", systemImage: "terminal")
                                        }
                                    }
                                }
                                .id(item.id)
                            }
                            Color.clear.frame(height: 16).id("BOTTOM_ANCHOR")
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .background(Color.black)
                    .onTapGesture {
                        showMiniKeyboard = false
                        isSystemKeyboardFocused = false
                    }
                    .onChange(of: session.history.count) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: session.history.last?.output) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                }

                // 隐式原生输入框
                TextField("", text: $inputCommand)
                    .focused($isSystemKeyboardFocused)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onSubmit { executeCurrentInput() }

                // 纯黑不透明微型键盘
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showMiniKeyboard.toggle()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: showMiniKeyboard ? "chevron.down" : "keyboard")
                                Text(showMiniKeyboard ? "收起" : "微型键盘")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(white: 0.18))
                            .cornerRadius(5)
                        }

                        Text(inputCommand.isEmpty ? (session.isConnected ? "已在线" : "未连接") : inputCommand)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(inputCommand.isEmpty ? .gray : .green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)

                        if !inputCommand.isEmpty {
                            Button(action: { inputCommand = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                        }

                        Button(action: { executeCurrentInput() }) {
                            Text("回车")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Color.blue)
                                .cornerRadius(5)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                    if showMiniKeyboard {
                        VStack(spacing: 6) {
                            HStack(spacing: 5) {
                                miniKey("1")
                                miniKey("2")
                                miniKey("3")
                                miniKey("4")
                                miniKey("5")
                                miniKey("k")
                                miniKey("Ctrl+C", color: .red) {
                                    session.sendCommand("\u{03}")
                                }
                            }

                            HStack(spacing: 5) {
                                miniKey("6")
                                miniKey("7")
                                miniKey("8")
                                miniKey("9")
                                miniKey("0")
                                miniKey("-")
                                miniKey("ESC", color: .orange) {
                                    session.sendCommand("\u{1B}")
                                }
                            }

                            HStack(spacing: 5) {
                                miniKey("空格") { inputCommand.append(" ") }
                                miniKey("x-ui") { runCommand("x-ui") }
                                miniKey("88") { runCommand("88") }
                                miniKey("退格", icon: "delete.left") {
                                    if !inputCommand.isEmpty { inputCommand.removeLast() }
                                }
                                miniKey("Aa 全键盘", icon: "textformat") {
                                    isSystemKeyboardFocused = true
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                }
                .background(Color(white: 0.08))
            }

            if let tip = copiedTip {
                VStack {
                    Spacer()
                    Text(tip)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(20)
                        .padding(.bottom, 60)
                }
                .transition(.opacity)
            }
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
        .sheet(isPresented: $showingAddSheet) {
            NavigationView {
                Form {
                    Section(header: Text("快捷键属性")) {
                        TextField("按键名称 (例如: 3x-ui / x-ui)", text: $newCmdName)
                        TextField("执行命令 (例如: x-ui)", text: $newCmdContent)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                .navigationTitle("添加快捷键")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingAddSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            addQuickCmd()
                            showingAddSheet = false
                        }
                        .disabled(newCmdName.trimmingCharacters(in: .whitespaces).isEmpty || newCmdContent.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .onAppear {
            loadQuickCommands()
            if !session.isConnected {
                connectToServer()
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                session.appDidEnterBackground()
            case .active:
                session.appWillEnterForeground()
            default:
                break
            }
        }
    }

    private func copyBlock(_ text: String, tip: String) {
        UIPasteboard.general.string = text
        showToast(tip)
    }

    // 智能识别：无论是网址、密码、账号、端口还是带有冒号配置的行，均自动配备专属复制按钮
    @ViewBuilder
    private func renderOutputLines(_ fullText: String, defaultColor: Color) -> some View {
        let lines = fullText.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let shouldShowCopyButton = trimmed.contains("http://") || 
                                           trimmed.contains("https://") || 
                                           trimmed.contains("port:") || 
                                           trimmed.contains("username") || 
                                           trimmed.contains("password") || 
                                           trimmed.contains("path:") || 
                                           trimmed.contains("URL:") || 
                                           trimmed.contains("IP:") || 
                                           (trimmed.contains(":") && !trimmed.hasSuffix(":") && trimmed.count < 60)

                if shouldShowCopyButton {
                    HStack(alignment: .center, spacing: 6) {
                        Text(line)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(defaultColor)
                            .textSelection(.enabled)
                        
                        Button(action: {
                            // 如果行内包含 URL，优先截取复制 URL；否则复制整行核心内容
                            if let url = extractURL(from: line) {
                                UIPasteboard.general.string = url
                                showToast("已复制地址: \(url)")
                            } else {
                                let cleanLine = line.trimmingCharacters(in: .whitespaces)
                                UIPasteboard.general.string = cleanLine
                                showToast("已复制: \(cleanLine)")
                            }
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(.cyan)
                                .padding(4)
                                .background(Color(white: 0.2))
                                .cornerRadius(4)
                        }
                    }
                } else {
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(defaultColor)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func extractURL(from string: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: string, options: [], range: NSRange(location: 0, length: string.utf16.count))
        if let match = matches?.first, let range = Range(match.range, in: string) {
            return String(string[range])
        }
        return nil
    }

    private func showToast(_ msg: String) {
        withAnimation { copiedTip = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { copiedTip = nil }
        }
    }

    private func miniKey(_ label: String, icon: String? = nil, color: Color = Color(white: 0.22), action: (() -> Void)? = nil) -> some View {
        Button(action: {
            if let action = action { action() }
            else { inputCommand.append(label) }
        }) {
            HStack(spacing: 2) {
                if let icon = icon {
                    Image(systemName: icon).font(.system(size: 11))
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(6)
        }
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
        session.sendCommand(cmd)
    }

    private func loadQuickCommands() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([QuickCmd].self, from: data) {
            self.quickCommands = decoded
        } else {
            self.quickCommands = [
                QuickCmd(name: "输入 k 菜单", cmd: "k"),
                QuickCmd(name: "面板管理 (x-ui)", cmd: "x-ui"),
                QuickCmd(name: "查看文件 (ls)", cmd: "ls -la"),
                QuickCmd(name: "磁盘空间 (df)", cmd: "df -h"),
                QuickCmd(name: "系统信息 (uname)", cmd: "uname -a")
            ]
            saveQuickCommands()
        }
    }

    private func addQuickCmd() {
        let name = newCmdName.trimmingCharacters(in: .whitespaces)
        let cmd = newCmdContent.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !cmd.isEmpty else { return }
        quickCommands.append(QuickCmd(name: name, cmd: cmd))
        saveQuickCommands()
        newCmdName = ""
        newCmdContent = ""
    }

    private func deleteQuickCmd(_ item: QuickCmd) {
        quickCommands.removeAll { $0.id == item.id }
        saveQuickCommands()
    }

    private func saveQuickCommands() {
        if let encoded = try? JSONEncoder().encode(quickCommands) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}
