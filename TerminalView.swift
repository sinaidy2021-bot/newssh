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

    // SSH 当前正在输入的命令
    @State private var inputCommand: String = ""

    // 苹果原生键盘
    @State private var systemKeyboardText: String = ""
    @FocusState private var isSystemKeyboardFocused: Bool

    // 自定义 SSH 软键盘始终显示
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
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 4)
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
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 4)
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

                            // MARK: - 当前输入行

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

                                    Rectangle()
                                        .fill(Color.green)
                                        .frame(width: 7, height: 15)
                                        .opacity(0.8)

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
                    .onChange(of: inputCommand) { _ in
                        scrollToCurrentCommand(proxy: proxy)
                    }
                }

                // MARK: - 紧凑 SSH 软键盘

                compactKeyboard
                    .background(Color(white: 0.08))
            }

            // MARK: - 左下角苹果键盘按钮

            VStack {
                Spacer()

                HStack {
                    Button(action: {
                        toggleSystemKeyboard()
                    }) {
                        Image(
                            systemName: isSystemKeyboardFocused
                                ? "keyboard.chevron.compact.down"
                                : "keyboard"
                        )
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color(white: 0.22))
                        .clipShape(Circle())
                    }
                    .padding(.leading, 8)
                    .padding(.bottom, 6)

                    Spacer()
                }
            }

            // MARK: - 隐藏的苹果输入框
            //
            // 这里只负责接收 iPhone 原生键盘输入。
            // 真正执行 SSH 命令仍然走 inputCommand -> sendCommand。

            VStack {
                Spacer()

                TextField("", text: $systemKeyboardText)
                    .focused($isSystemKeyboardFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.return)
                    .onSubmit {
                        executeCurrentInput()
                    }
                    .onChange(of: systemKeyboardText) { value in
                        if value != inputCommand {
                            inputCommand = value
                        }
                    }
                    .frame(width: 2, height: 2)
                    .opacity(0.01)
                    .padding(.bottom, 2)
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

    // MARK: - 紧凑软键盘

    private var compactKeyboard: some View {
        VStack(spacing: 3) {

            // 数字
            HStack(spacing: 3) {
                ForEach(
                    ["1", "2", "3", "4", "5",
                     "6", "7", "8", "9", "0"],
                    id: \.self
                ) { value in
                    miniKey(value)
                }
            }

            // Ctrl
            HStack(spacing: 3) {

                miniKey(
                    "Ctrl+C",
                    hint: "停止",
                    color: Color.red.opacity(0.35)
                ) {
                    session.sendRaw("\u{03}")
                }

                miniKey("Ctrl+D", hint: "退出") {
                    session.sendRaw("\u{04}")
                }

                miniKey("Ctrl+L", hint: "清屏") {
                    session.sendRaw("\u{0C}")
                }

                miniKey("Ctrl+Z", hint: "挂起") {
                    session.sendRaw("\u{1A}")
                }
            }

            // 编辑
            HStack(spacing: 3) {

                miniKey("Ctrl+A", hint: "行首") {
                    session.sendRaw("\u{01}")
                }

                miniKey("Ctrl+E", hint: "行尾") {
                    session.sendRaw("\u{05}")
                }

                miniKey("Ctrl+U", hint: "清前") {
                    session.sendRaw("\u{15}")
                }

                miniKey("Ctrl+K", hint: "清后") {
                    session.sendRaw("\u{0B}")
                }
            }

            // Tab / Esc / 方向
            HStack(spacing: 3) {

                miniKey("Tab", hint: "补全") {
                    session.sendRaw("\t")
                }

                miniKey(
                    "Esc",
                    hint: "取消",
                    color: Color.orange.opacity(0.35)
                ) {
                    session.sendRaw("\u{1B}")
                }

                miniKey("↑", hint: "上一条") {
                    session.sendRaw("\u{1B}[A")
                }

                miniKey("↓", hint: "下一条") {
                    session.sendRaw("\u{1B}[B")
                }

                miniKey("←", hint: "左移") {
                    session.sendRaw("\u{1B}[D")
                }

                miniKey("→", hint: "右移") {
                    session.sendRaw("\u{1B}[C")
                }
            }

            // 符号
            HStack(spacing: 3) {
                miniKey("/")
                miniKey("-")
                miniKey("_")
                miniKey(".")
                miniKey(":")
                miniKey("|")
                miniKey("$")
                miniKey("~")
            }

            // 功能键
            HStack(spacing: 3) {

                miniKey("空格") {
                    inputCommand.append(" ")
                    syncNativeInput()
                }

                miniKey(
                    "退格",
                    icon: "delete.left"
                ) {
                    if !inputCommand.isEmpty {
                        inputCommand.removeLast()
                        syncNativeInput()
                    }
                }

                miniKey("x-ui") {
                    runCommand("x-ui")
                }

                miniKey("88") {
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
        .padding(.horizontal, 5)
        .padding(.top, 4)
        .padding(.bottom, 5)
    }

    // MARK: - 粘贴

    private func pasteClipboard() {
        guard let pasteString = UIPasteboard.general.string,
              !pasteString.isEmpty else {
            showToast("剪贴板为空")
            return
        }

        inputCommand.append(pasteString)
        syncNativeInput()
        showToast("已从剪贴板粘贴")
    }

    // MARK: - 同步苹果键盘输入

    private func syncNativeInput() {
        if systemKeyboardText != inputCommand {
            systemKeyboardText = inputCommand
        }
    }

    // MARK: - 苹果键盘开关

    private func toggleSystemKeyboard() {
        if isSystemKeyboardFocused {
            isSystemKeyboardFocused = false
            return
        }

        systemKeyboardText = inputCommand

        DispatchQueue.main.async {
            isSystemKeyboardFocused = true
        }
    }

    // MARK: - 复制

    private func copyBlock(
        _ text: String,
        tip: String
    ) {
        UIPasteboard.general.string = text
        showToast(tip)
    }

    // MARK: - 输出渲染

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

                let isPromptLine =
                    trimmed.range(
                        of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^\r\n]*[#$]$"#,
                        options: .regularExpression
                    ) != nil

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

    // MARK: - 软键

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
                syncNativeInput()
            }
        }) {
            VStack(spacing: 0) {

                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                }

                Text(label)
                    .font(
                        .system(
                            size: 10,
                            weight: .medium,
                            design: .monospaced
                        )
                    )
                    .lineLimit(1)

                if let hint = hint {
                    Text(hint)
                        .font(
                            .system(
                                size: 7,
                                weight: .regular
                            )
                        )
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(
                height: hint == nil
                    ? 29
                    : 31
            )
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(5)
        }
    }

    // MARK: - 滚动

    private func scrollToBottom(
        proxy: ScrollViewProxy
    ) {
        DispatchQueue.main.async {
            withAnimation(
                .easeOut(duration: 0.12)
            ) {
                proxy.scrollTo(
                    "BOTTOM_ANCHOR",
                    anchor: .bottom
                )
            }
        }
    }

    private func scrollToCurrentCommand(
        proxy: ScrollViewProxy
    ) {
        DispatchQueue.main.async {
            withAnimation(
                .easeOut(duration: 0.1)
            ) {
                proxy.scrollTo(
                    "CURRENT_PROMPT",
                    anchor: .bottom
                )
            }
        }
    }

    // MARK: - SSH

    private func connectToServer() {
        session.host = host
        session.port = port
        session.username = username
        session.password = password
        session.connect()
    }

    private func executeCurrentInput() {

        let cmd = inputCommand
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !cmd.isEmpty else {
            return
        }

        // 关键：
        // 这里直接走原来的 SSHSession.sendCommand()
        runCommand(cmd)

        inputCommand = ""
        systemKeyboardText = ""

        isSystemKeyboardFocused = false
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

    // MARK: - 快捷命令

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
