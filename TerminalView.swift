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

    // MARK: - 输出过长保护
    // 数据量大时黑屏的主因之一：单条输出被一次性、非懒加载地全部渲染成大量子视图。
    // 这里做两件事：1) 用 LazyVStack 代替普通 VStack；2) 超长输出只渲染尾部一部分。
    private let maxRenderedLinesPerBlock = 400

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

                                        // 输出可能很长，顶部的"复制整段"要往上滑才够得到，
                                        // 这里在输出末尾再放一个一样的按钮，看完就能直接点。
                                        if !item.output.isEmpty {
                                            HStack {
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
                                            .padding(.top, 4)
                                        }
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

                // 隐式原生输入框（用于唤起系统键盘，本身不可见）
                TextField("", text: $inputCommand)
                    .focused($isSystemKeyboardFocused)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onSubmit { executeCurrentInput() }
                    .onChange(of: isSystemKeyboardFocused) { focused in
                        // 系统键盘弹出时强制收起微型键盘，避免两个键盘同时占用底部空间、互相遮挡
                        if focused { showMiniKeyboard = false }
                    }

                // 纯黑不透明微型键盘（集成一键粘贴功能）
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Button(action: { toggleMiniKeyboard() }) {
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

                        Button(action: { toggleSystemKeyboard() }) {
                            HStack(spacing: 4) {
                                Image(systemName: isSystemKeyboardFocused ? "chevron.down" : "character.cursor.ibeam")
                                Text(isSystemKeyboardFocused ? "收起" : "系统键盘")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(white: 0.18))
                            .cornerRadius(5)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                    HStack(spacing: 8) {
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
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)

                    // MARK: - 重新设计的微型键盘
                    // 左侧：数字/控制键区（多行）。右侧：一列纵向按钮，
                    // 「粘贴」在上，「回车」在下且明显更大更好按，符合单手右下角操作习惯。
                    if showMiniKeyboard {
                        HStack(alignment: .top, spacing: 6) {
                            VStack(spacing: 6) {
                                HStack(spacing: 5) {
                                    miniKey("1")
                                    miniKey("2")
                                    miniKey("3")
                                    miniKey("4")
                                    miniKey("5")
                                    miniKey("k")
                                }
                                HStack(spacing: 5) {
                                    miniKey("6")
                                    miniKey("7")
                                    miniKey("8")
                                    miniKey("9")
                                    miniKey("0")
                                    miniKey("-")
                                }
                                HStack(spacing: 5) {
                                    miniKey("Ctrl+C", color: .red) {
                                        session.sendCommand("\u{03}")
                                    }
                                    miniKey("ESC", color: .orange) {
                                        session.sendCommand("\u{1B}")
                                    }
                                    miniKey("空格") { inputCommand.append(" ") }
                                    miniKey("退格", icon: "delete.left") {
                                        if !inputCommand.isEmpty { inputCommand.removeLast() }
                                    }
                                }
                                HStack(spacing: 5) {
                                    miniKey("x-ui") { runCommand("x-ui") }
                                    miniKey("88") { runCommand("88") }
                                    miniKey("q退出", color: .purple) {
                                        // 专治卡在 less/more/man/vim 等交互程序里出不来的情况
                                        session.sendCommand("q")
                                    }
                                }
                            }

                            // 右侧纵向列：粘贴（上）+ 回车（下，放大）
                            VStack(spacing: 6) {
                                Button(action: {
                                    if let pasteString = UIPasteboard.general.string {
                                        inputCommand.append(pasteString)
                                        showToast("已粘贴剪贴板内容")
                                    } else {
                                        showToast("剪贴板为空")
                                    }
                                }) {
                                    VStack(spacing: 2) {
                                        Image(systemName: "doc.on.clipboard")
                                            .font(.system(size: 15))
                                        Text("粘贴")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 56)
                                    .background(Color.blue.opacity(0.35))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                }

                                Button(action: { executeCurrentInput() }) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "return")
                                            .font(.system(size: 20, weight: .bold))
                                        Text("回车")
                                            .font(.system(size: 14, weight: .bold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(maxHeight: .infinity)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                }
                            }
                            .frame(width: 78)
                        }
                        .frame(height: 176)
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

    // MARK: - ANSI 转义序列过滤
    // vim / less / top / 各种菜单程序（k 菜单、x-ui 等）在全屏模式下会输出
    // 光标定位、清屏、颜色等 ANSI 控制序列。这些序列原样塞进 output 字符串后，
    // 既会在界面上显示成乱码，又会在数据量大时显著增加渲染开销，是黑屏的重要成因之一。
    // 这里统一过滤掉，只保留纯文本内容。
    private func stripANSIEscapeCodes(_ text: String) -> String {
        // 匹配 CSI 序列 (ESC [ ... 字母)、OSC 序列 (ESC ] ... BEL) 以及其他单字符转义
        let pattern = "\u{1B}(\\[[0-9;?]*[a-zA-Z]|\\][^\u{07}]*\u{07}|[()][A-Za-z0-9]|[@-Z\\\\^_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    @ViewBuilder
    private func renderOutputLines(_ fullText: String, defaultColor: Color) -> some View {
        let cleaned = stripANSIEscapeCodes(fullText)
        let allLines = cleaned.components(separatedBy: "\n")

        let isTruncated = allLines.count > maxRenderedLinesPerBlock
        let lines = isTruncated ? Array(allLines.suffix(maxRenderedLinesPerBlock)) : allLines

        // 用 LazyVStack 代替普通 VStack：单条输出行数很多时（比如几百上千行的
        // find/ls 结果），只渲染屏幕附近可见的行，避免一次性生成大量子视图卡死主线程。
        LazyVStack(alignment: .leading, spacing: 2) {
            if isTruncated {
                Text("⚠️ 输出过长（共 \(allLines.count) 行），仅显示最后 \(maxRenderedLinesPerBlock) 行。点击"复制整段"可获取完整内容。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(.bottom, 2)
            }

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isPromptLine =
                    trimmed.hasPrefix("root@") ||
                    trimmed.hasPrefix("user@") ||
                    trimmed.contains("~#")

                // 对返回结果中真正的"字段: 值"行提供一键复制。
                // URL 本身（http:// / https://）仍然整行复制。
                let copyValue = copyValueForOutputLine(line)
                let isCopyableLine = !isPromptLine && !trimmed.isEmpty && copyValue != nil

                if isCopyableLine {
                    HStack(alignment: .center, spacing: 6) {
                        Text(line)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(defaultColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            if let value = copyValue {
                                UIPasteboard.general.string = value
                                showToast("已复制: \(value)")
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(.cyan)
                                .padding(4)
                                .background(Color(white: 0.2))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
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

    private func copyValueForOutputLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // URL 作为独立输出时，保持原来的整 URL 复制行为。
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }

        guard let colon = trimmed.firstIndex(of: ":") else {
            return nil
        }

        let prefix = trimmed[..<colon]

        // 避免把普通 URL/协议行里的 ":" 当成字段分隔符。
        if prefix == "http" || prefix == "https" {
            return trimmed
        }

        let valueStart = trimmed.index(after: colon)
        return String(trimmed[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractURL(from string: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: string, options: [], range: NSRange(location: 0, length: string.utf16.count))
        if let match = matches?.first, let range = Range(match.range, in: string) {
            return String(string[range])
        }
        return nil
    }

    // 两个键盘互斥：打开一个之前，先收起另一个，避免同时出现互相遮挡、按不到按钮
    private func toggleMiniKeyboard() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if showMiniKeyboard {
                showMiniKeyboard = false
            } else {
                isSystemKeyboardFocused = false
                showMiniKeyboard = true
            }
        }
    }

    private func toggleSystemKeyboard() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if isSystemKeyboardFocused {
                isSystemKeyboardFocused = false
            } else {
                showMiniKeyboard = false
                isSystemKeyboardFocused = true
            }
        }
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
