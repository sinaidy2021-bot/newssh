import SwiftUI
import UniformTypeIdentifiers
import UIKit

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

                // MARK: - 顶部快捷命令

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {

                        Button(action: {
                            showingAddSheet = true
                        }) {
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
                            Button(action: {
                                runCommand(item.cmd)
                            }) {
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
                                    Label(
                                        "删除快捷键",
                                        systemImage: "trash"
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .background(Color(white: 0.12))

                // MARK: - 终端

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(
                            alignment: .leading,
                            spacing: 10
                        ) {

                            ForEach(session.history) { item in

                                VStack(
                                    alignment: .leading,
                                    spacing: 6
                                ) {

                                    if item.command == "system" {

                                        HStack {
                                            Text("[系统状态]")
                                                .font(
                                                    .system(
                                                        size: 11,
                                                        weight: .bold,
                                                        design: .monospaced
                                                    )
                                                )
                                                .foregroundColor(
                                                    .yellow.opacity(0.8)
                                                )

                                            Spacer()

                                            Button(action: {
                                                copyBlock(
                                                    item.output,
                                                    tip: "已复制系统信息"
                                                )
                                            }) {
                                                Image(
                                                    systemName: "doc.on.doc"
                                                )
                                                .font(.system(size: 11))
                                                .foregroundColor(.gray)
                                            }
                                        }

                                        renderOutputLines(
                                            item.output,
                                            defaultColor: .yellow
                                        )

                                    } else {

                                        // 命令行
                                        HStack(
                                            alignment: .center,
                                            spacing: 4
                                        ) {

                                            Text(
                                                "\(item.prompt.isEmpty ? session.currentPrompt : item.prompt) "
                                            )
                                            .font(
                                                .system(
                                                    size: 13,
                                                    weight: .bold,
                                                    design: .monospaced
                                                )
                                            )
                                            .foregroundColor(.cyan)

                                            Text(item.command)
                                                .font(
                                                    .system(
                                                        size: 13,
                                                        weight: .bold,
                                                        design: .monospaced
                                                    )
                                                )
                                                .foregroundColor(.white)
                                                .textSelection(.enabled)

                                            Spacer(minLength: 4)

                                            Button(action: {
                                                let prompt = item.prompt.isEmpty
                                                    ? session.currentPrompt
                                                    : item.prompt

                                                let fullBlock =
                                                    "\(prompt) \(item.command)\n" +
                                                    item.output

                                                copyBlock(
                                                    fullBlock,
                                                    tip: "已复制整段命令与输出"
                                                )
                                            }) {
                                                HStack(spacing: 3) {
                                                    Image(
                                                        systemName: "doc.on.doc"
                                                    )
                                                    Text("复制整段")
                                                }
                                                .font(
                                                    .system(
                                                        size: 10,
                                                        weight: .medium
                                                    )
                                                )
                                                .foregroundColor(.gray)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(
                                                    Color(white: 0.18)
                                                )
                                                .cornerRadius(4)
                                            }
                                        }

                                        renderOutputLines(
                                            item.output,
                                            defaultColor: .green
                                        )

                                        // 每一个命令块都有：
                                        // 复制本段输出
                                        // 复制整段
                                        HStack(spacing: 6) {

                                            Button(action: {
                                                copyBlock(
                                                    item.output,
                                                    tip: "已复制本段输出"
                                                )
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(
                                                        systemName: "doc.on.doc"
                                                    )
                                                    Text("复制本段输出")
                                                }
                                                .font(
                                                    .system(
                                                        size: 10,
                                                        weight: .medium
                                                    )
                                                )
                                                .foregroundColor(.gray)
                                                .padding(
                                                    .horizontal,
                                                    7
                                                )
                                                .padding(
                                                    .vertical,
                                                    4
                                                )
                                                .background(
                                                    Color(white: 0.16)
                                                )
                                                .cornerRadius(4)
                                            }

                                            Button(action: {
                                                let prompt = item.prompt.isEmpty
                                                    ? session.currentPrompt
                                                    : item.prompt

                                                let fullBlock =
                                                    "\(prompt) \(item.command)\n" +
                                                    item.output

                                                copyBlock(
                                                    fullBlock,
                                                    tip: "已复制整段"
                                                )
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(
                                                        systemName: "doc.on.doc.fill"
                                                    )
                                                    Text("复制整段")
                                                }
                                                .font(
                                                    .system(
                                                        size: 10,
                                                        weight: .medium
                                                    )
                                                )
                                                .foregroundColor(.gray)
                                                .padding(
                                                    .horizontal,
                                                    7
                                                )
                                                .padding(
                                                    .vertical,
                                                    4
                                                )
                                                .background(
                                                    Color(white: 0.16)
                                                )
                                                .cornerRadius(4)
                                            }

                                            Spacer()
                                        }
                                    }
                                }
                                .padding(8)
                                .background(Color(white: 0.05))
                                .cornerRadius(6)
                                .id(item.id)
                            }

                            // MARK: - 当前最新 Prompt

                            if session.isConnected {
                                HStack(spacing: 4) {

                                    Text(session.currentPrompt)
                                        .font(
                                            .system(
                                                size: 13,
                                                weight: .bold,
                                                design: .monospaced
                                            )
                                        )
                                        .foregroundColor(.cyan)

                                    Text(inputCommand)
                                        .font(
                                            .system(
                                                size: 13,
                                                design: .monospaced
                                            )
                                        )
                                        .foregroundColor(.white)

                                    if inputCommand.isEmpty {
                                        Rectangle()
                                            .fill(Color.green)
                                            .frame(width: 7, height: 15)
                                            .opacity(0.8)
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.top, 2)
                                .id("CURRENT_PROMPT")
                            }

                            Color.clear
                                .frame(height: 8)
                                .id("BOTTOM_ANCHOR")
                        }
                        .padding(8)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .topLeading
                        )
                    }
                    .background(Color.black)
                    .onChange(of: session.history.count) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: session.history.last?.output) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: session.currentPrompt) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                }

                // MARK: - 输入区域

                VStack(spacing: 5) {

                    HStack(spacing: 6) {

                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showMiniKeyboard.toggle()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(
                                    systemName: showMiniKeyboard
                                        ? "chevron.down"
                                        : "keyboard"
                                )

                                Text(
                                    showMiniKeyboard
                                        ? "收起"
                                        : "键盘"
                                )
                            }
                            .font(
                                .system(
                                    size: 11,
                                    weight: .bold
                                )
                            )
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.18))
                            .cornerRadius(6)
                        }

                        TextField(
                            "输入 SSH 命令…",
                            text: $inputCommand
                        )
                        .focused($isSystemKeyboardFocused)
                        .font(
                            .system(
                                size: 14,
                                design: .monospaced
                            )
                        )
                        .foregroundColor(.white)
                        .tint(.green)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .submitLabel(.return)
                        .onSubmit {
                            executeCurrentInput()
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 36)
                        .background(Color.black)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    Color(white: 0.25),
                                    lineWidth: 1
                                )
                        )

                        if !inputCommand.isEmpty {
                            Button(action: {
                                inputCommand = ""
                            }) {
                                Image(
                                    systemName: "xmark.circle.fill"
                                )
                                .foregroundColor(.gray)
                            }
                        }

                        // 一键粘贴
                        Button(action: {
                            pasteClipboard()
                        }) {
                            Text("粘贴")
                                .font(
                                    .system(
                                        size: 11,
                                        weight: .semibold
                                    )
                                )
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .background(Color(white: 0.2))
                                .cornerRadius(6)
                        }

                        // 回车
                        Button(action: {
                            executeCurrentInput()
                        }) {
                            Text("回车")
                                .font(
                                    .system(
                                        size: 12,
                                        weight: .bold
                                    )
                                )
                                .foregroundColor(.white)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(Color.blue)
                                .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.top, 6)

                    // MARK: - 微型 SSH 键盘

                    if showMiniKeyboard {

                        ScrollView {
                            VStack(spacing: 5) {

                                // 第一行：0 - 9
                                HStack(spacing: 4) {
                                    ForEach(
                                        ["1", "2", "3", "4", "5",
                                         "6", "7", "8", "9", "0"],
                                        id: \.self
                                    ) { value in
                                        miniKey(value)
                                    }
                                }

                                // Ctrl 第一组
                                HStack(spacing: 4) {
                                    miniKey(
                                        "Ctrl+C",
                                        hint: "停止",
                                        color: Color.red.opacity(0.35)
                                    ) {
                                        session.sendRaw("\u{03}")
                                    }

                                    miniKey(
                                        "Ctrl+D",
                                        hint: "退出/EOF"
                                    ) {
                                        session.sendRaw("\u{04}")
                                    }

                                    miniKey(
                                        "Ctrl+L",
                                        hint: "清屏"
                                    ) {
                                        session.sendRaw("\u{0C}")
                                    }

                                    miniKey(
                                        "Ctrl+Z",
                                        hint: "挂起"
                                    ) {
                                        session.sendRaw("\u{1A}")
                                    }
                                }

                                // Ctrl 第二组
                                HStack(spacing: 4) {
                                    miniKey(
                                        "Ctrl+A",
                                        hint: "行首"
                                    ) {
                                        session.sendRaw("\u{01}")
                                    }

                                    miniKey(
                                        "Ctrl+E",
                                        hint: "行尾"
                                    ) {
                                        session.sendRaw("\u{05}")
                                    }

                                    miniKey(
                                        "Ctrl+U",
                                        hint: "清前"
                                    ) {
                                        session.sendRaw("\u{15}")
                                    }

                                    miniKey(
                                        "Ctrl+K",
                                        hint: "清后"
                                    ) {
                                        session.sendRaw("\u{0B}")
                                    }
                                }

                                // Tab / Esc / 方向键
                                HStack(spacing: 4) {

                                    miniKey(
                                        "Tab",
                                        hint: "补全"
                                    ) {
                                        session.sendRaw("\t")
                                    }

                                    miniKey(
                                        "Esc",
                                        hint: "取消",
                                        color: Color.orange.opacity(0.35)
                                    ) {
                                        session.sendRaw("\u{1B}")
                                    }

                                    miniKey(
                                        "↑",
                                        hint: "上一条"
                                    ) {
                                        session.sendRaw("\u{1B}[A")
                                    }

                                    miniKey(
                                        "↓",
                                        hint: "下一条"
                                    ) {
                                        session.sendRaw("\u{1B}[B")
                                    }

                                    miniKey(
                                        "←",
                                        hint: "左移"
                                    ) {
                                        session.sendRaw("\u{1B}[D")
                                    }

                                    miniKey(
                                        "→",
                                        hint: "右移"
                                    ) {
                                        session.sendRaw("\u{1B}[C")
                                    }
                                }

                                // 常用 Linux 符号
                                HStack(spacing: 4) {
                                    miniKey("/")
                                    miniKey("-")
                                    miniKey("_")
                                    miniKey(".")
                                    miniKey(":")
                                    miniKey("|")
                                    miniKey("$")
                                    miniKey("~")
                                }

                                // 常用功能
                                HStack(spacing: 4) {

                                    miniKey(
                                        "空格"
                                    ) {
                                        inputCommand.append(" ")
                                    }

                                    miniKey(
                                        "退格",
                                        icon: "delete.left"
                                    ) {
                                        if !inputCommand.isEmpty {
                                            inputCommand.removeLast()
                                        }
                                    }

                                    miniKey(
                                        "x-ui"
                                    ) {
                                        runCommand("x-ui")
                                    }

                                    miniKey(
                                        "88"
                                    ) {
                                        runCommand("88")
                                    }

                                    miniKey(
                                        "粘贴",
                                        hint: "剪贴板",
                                        color: Color.blue.opacity(0.35)
                                    ) {
                                        pasteClipboard()
                                    }

                                    miniKey(
                                        "回车",
                                        hint: "执行",
                                        color: Color.blue
                                    ) {
                                        executeCurrentInput()
                                    }
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                        }
                        .frame(maxHeight: 255)
                    }
                }
                .background(Color(white: 0.08))
            }

            // MARK: - Toast

            if let tip = copiedTip {
                VStack {
                    Spacer()

                    Text(tip)
                        .font(
                            .system(
                                size: 12,
                                weight: .medium
                            )
                        )
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
            ToolbarItem(
                placement: .navigationBarTrailing
            ) {
                Button(
                    session.isConnected
                        ? "断开"
                        : "连接"
                ) {
                    if session.isConnected {
                        session.disconnect()
                    } else {
                        connectToServer()
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            NavigationView {
                Form {
                    Section(
                        header: Text("快捷键属性")
                    ) {
                        TextField(
                            "按键名称 (例如: 3x-ui / x-ui)",
                            text: $newCmdName
                        )

                        TextField(
                            "执行命令 (例如: x-ui)",
                            text: $newCmdContent
                        )
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    }
                }
                .navigationTitle("添加快捷键")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(
                        placement: .cancellationAction
                    ) {
                        Button("取消") {
                            showingAddSheet = false
                        }
                    }

                    ToolbarItem(
                        placement: .confirmationAction
                    ) {
                        Button("保存") {
                            addQuickCmd()
                            showingAddSheet = false
                        }
                        .disabled(
                            newCmdName
                                .trimmingCharacters(
                                    in: .whitespaces
                                )
                                .isEmpty
                            ||
                            newCmdContent
                                .trimmingCharacters(
                                    in: .whitespaces
                                )
                                .isEmpty
                        )
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

    // MARK: - Clipboard

    private func pasteClipboard() {
        guard let pasteString = UIPasteboard.general.string,
              !pasteString.isEmpty else {
            showToast("剪贴板为空")
            return
        }

        inputCommand.append(pasteString)
        showToast("已从剪贴板粘贴")
    }

    // MARK: - Copy

    private func copyBlock(
        _ text: String,
        tip: String
    ) {
        UIPasteboard.general.string = text
        showToast(tip)
    }

    // MARK: - Output Rendering

    @ViewBuilder
    private func renderOutputLines(
        _ fullText: String,
        defaultColor: Color
    ) -> some View {

        let lines = fullText.components(
            separatedBy: "\n"
        )

        VStack(
            alignment: .leading,
            spacing: 2
        ) {

            ForEach(
                Array(lines.enumerated()),
                id: \.offset
            ) { _, line in

                let trimmed = line
                    .trimmingCharacters(
                        in: .whitespaces
                    )

                // Prompt 行不再额外生成 key:value 按钮
                let isPromptLine =
                    trimmed.range(
                        of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^\r\n]*[#$]$"#,
                        options: .regularExpression
                    ) != nil

                /*
                 任意：

                 key: value

                 都提供单独复制按钮。

                 不再限制必须是 URL / port / username 等。
                */

                let colonIndex = trimmed.firstIndex(
                    of: ":"
                )

                let hasKeyValue =
                    !isPromptLine &&
                    !trimmed.isEmpty &&
                    colonIndex != nil

                if hasKeyValue,
                   let colonIndex = colonIndex {

                    let key = String(
                        trimmed[..<colonIndex]
                    )
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )

                    let value = String(
                        trimmed[
                            trimmed.index(
                                after: colonIndex
                            )...
                        ]
                    )
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )

                    HStack(
                        alignment: .center,
                        spacing: 6
                    ) {

                        Text(line)
                            .font(
                                .system(
                                    size: 13,
                                    design: .monospaced
                                )
                            )
                            .foregroundColor(
                                defaultColor
                            )
                            .textSelection(.enabled)

                        Spacer(minLength: 3)

                        Button(action: {

                            UIPasteboard.general.string =
                                value

                            showToast(
                                "已复制 \(key) 的值"
                            )

                        }) {
                            HStack(spacing: 3) {

                                Image(
                                    systemName: "doc.on.doc"
                                )

                                Text("复制值")
                            }
                            .font(
                                .system(
                                    size: 10,
                                    weight: .medium
                                )
                            )
                            .foregroundColor(.cyan)
                            .padding(
                                .horizontal,
                                5
                            )
                            .padding(
                                .vertical,
                                4
                            )
                            .background(
                                Color(white: 0.18)
                            )
                            .cornerRadius(4)
                        }
                    }

                } else {

                    Text(
                        line.isEmpty
                            ? " "
                            : line
                    )
                    .font(
                        .system(
                            size: 13,
                            design: .monospaced
                        )
                    )
                    .foregroundColor(
                        defaultColor
                    )
                    .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Mini Keyboard Key

    private func miniKey(
        _ label: String,
        hint: String? = nil,
        icon: String? = nil,
        color: Color = Color(white: 0.22),
        action: (() -> Void)? = nil
    ) -> some View {

        Button(action: {
            if let action = action {
                action()
            } else {
                inputCommand.append(label)
            }
        }) {
            VStack(
                spacing: 1
            ) {

                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }

                Text(label)
                    .font(
                        .system(
                            size: 11,
                            weight: .medium,
                            design: .monospaced
                        )
                    )
                    .lineLimit(1)

                if let hint = hint {
                    Text(hint)
                        .font(
                            .system(
                                size: 8,
                                weight: .regular
                            )
                        )
                        .lineLimit(1)
                }
            }
            .frame(
                maxWidth: .infinity
            )
            .frame(
                height: hint == nil
                    ? 34
                    : 38
            )
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(6)
        }
    }

    // MARK: - Scroll

    private func scrollToBottom(
        proxy: ScrollViewProxy
    ) {
        DispatchQueue.main.async {
            withAnimation(
                .easeOut(duration: 0.15)
            ) {
                proxy.scrollTo(
                    "BOTTOM_ANCHOR",
                    anchor: .bottom
                )
            }
        }
    }

    // MARK: - Connect

    private func connectToServer() {
        session.host = host
        session.port = port
        session.username = username
        session.password = password
        session.connect()
    }

    // MARK: - Execute

    private func executeCurrentInput() {
        let cmd = inputCommand
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !cmd.isEmpty else {
            return
        }

        runCommand(cmd)
        inputCommand = ""
    }

    private func runCommand(
        _ cmd: String
    ) {
        session.sendCommand(cmd)
    }

    // MARK: - Toast

    private func showToast(
        _ msg: String
    ) {
        withAnimation {
            copiedTip = msg
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.8
        ) {
            withAnimation {
                copiedTip = nil
            }
        }
    }

    // MARK: - Quick Commands

    private func loadQuickCommands() {
        if let data = UserDefaults.standard.data(
            forKey: storageKey
        ),
           let decoded = try? JSONDecoder().decode(
                [QuickCmd].self,
                from: data
           ) {

            self.quickCommands = decoded

        } else {

            self.quickCommands = [
                QuickCmd(
                    name: "输入 k 菜单",
                    cmd: "k"
                ),
                QuickCmd(
                    name: "面板管理 (x-ui)",
                    cmd: "x-ui"
                ),
                QuickCmd(
                    name: "查看文件 (ls)",
                    cmd: "ls -la"
                ),
                QuickCmd(
                    name: "磁盘空间 (df)",
                    cmd: "df -h"
                ),
                QuickCmd(
                    name: "系统信息 (uname)",
                    cmd: "uname -a"
                )
            ]

            saveQuickCommands()
        }
    }

    private func addQuickCmd() {
        let name = newCmdName
            .trimmingCharacters(
                in: .whitespaces
            )

        let cmd = newCmdContent
            .trimmingCharacters(
                in: .whitespaces
            )

        guard !name.isEmpty,
              !cmd.isEmpty else {
            return
        }

        quickCommands.append(
            QuickCmd(
                name: name,
                cmd: cmd
            )
        )

        saveQuickCommands()

        newCmdName = ""
        newCmdContent = ""
    }

    private func deleteQuickCmd(
        _ item: QuickCmd
    ) {
        quickCommands.removeAll {
            $0.id == item.id
        }

        saveQuickCommands()
    }

    private func saveQuickCommands() {
        if let encoded = try? JSONEncoder().encode(
            quickCommands
        ) {
            UserDefaults.standard.set(
                encoded,
                forKey: storageKey
            )
        }
    }
}
