import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - TerminalView

struct TerminalView: View {

    @StateObject private var session = SSHSession()

    @State private var commandText = ""
    @State private var showSystemKeyboard = false
    @State private var toastMessage = ""
    @State private var showToast = false
    @State private var showSettings = false

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""

    // 新增：支持用已保存的服务器信息初始化
    init(server: ServerItem? = nil) {
        if let server {
            _host = State(initialValue: server.host)
            _port = State(initialValue: String(server.port))
            _username = State(initialValue: server.username)
            _password = State(initialValue: server.password)
        }
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {

                topBar

                Divider()
                    .background(Color.gray.opacity(0.35))

                historyView

                Divider()
                    .background(Color.gray.opacity(0.35))

                quickCommands

                compactKeyboard

                commandInput
            }

            if showToast {
                toastView
            }
        }
        .onAppear {
            if !host.isEmpty && !username.isEmpty {
                connectIfNeeded()
            }
        }
        .sheet(isPresented: $showSettings) {
            settingsView
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {

            Circle()
                .fill(session.isConnected ? Color.green : Color.red)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.isConnected ? "SSH 已连接" : "SSH 未连接")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                if !host.isEmpty {
                    Text("\(username)@\(host):\(port)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            Button {
                if session.isConnected {
                    session.disconnect()
                } else {
                    connectIfNeeded()
                }
            } label: {
                Image(systemName: session.isConnected
                      ? "rectangle.portrait.and.arrow.right"
                      : "bolt.horizontal.circle")
                    .font(.system(size: 17))
                    .foregroundColor(.white)
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.black)
    }

    // MARK: - History

    private var historyView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {

                    if session.history.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                                .frame(height: 35)

                            Image(systemName: "terminal")
                                .font(.system(size: 35))
                                .foregroundColor(.gray)

                            Text("等待 SSH 连接")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)

                            Spacer()
                                .frame(height: 35)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    ForEach(session.history) { item in
                        commandBlock(item)
                            .id(item.id)
                    }

                    Color.clear
                        .frame(height: 8)
                        .id("BOTTOM")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .background(Color.black)
            .onChange(of: session.history.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Command Block

    private func commandBlock(_ item: CommandHistoryItem) -> some View {

        VStack(alignment: .leading, spacing: 7) {

            HStack(alignment: .top, spacing: 8) {

                Text("$")
                    .foregroundColor(.green)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))

                Text(item.command)
                    .foregroundColor(.white)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    copyWholeBlock(item)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.borderless)
            }

            if !item.prompt.isEmpty {
                Text(item.prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
                    .textSelection(.enabled)
            }

            if !item.output.isEmpty {
                outputView(item.output)
            }

            HStack {
                Spacer()

                Button {
                    copyOutput(item.output)
                } label: {
                    Label(
                        "复制本段输出",
                        systemImage: "doc.on.doc"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                }
                .buttonStyle(.borderless)

                Button {
                    copyWholeBlock(item)
                } label: {
                    Label(
                        "复制整段",
                        systemImage: "square.on.square"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Output View

    private func outputView(_ output: String) -> some View {

        let lines = output.components(separatedBy: "\n")

        return VStack(alignment: .leading, spacing: 2) {

            ForEach(
                Array(lines.enumerated()),
                id: \.offset
            ) { index, line in

                outputLine(
                    line: line,
                    lines: lines,
                    index: index
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Single Output Line

    private func outputLine(
        line: String,
        lines: [String],
        index: Int
    ) -> AnyView {

        let trimmed = line.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if trimmed.isEmpty {
            return AnyView(
                Text(" ")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 13)
            )
        }

        let keyValue = copyableKeyValue(from: line)

        let pem = pemBlock(
            from: lines,
            at: index
        )

        return AnyView(
            HStack(
                alignment: .top,
                spacing: 7
            ) {

                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )

                if let keyValue = keyValue {

                    Button {
                        UIPasteboard.general.string =
                            keyValue.value

                        showToast(
                            "已复制 \(keyValue.key)"
                        )
                    } label: {
                        Image(
                            systemName: "doc.on.doc"
                        )
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 20)
                }

                if let pem = pem {

                    Button {
                        UIPasteboard.general.string =
                            pem.text

                        showToast("密钥已复制")
                    } label: {
                        Image(systemName: "key")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 20)
                }
            }
        )
    }

    // MARK: - Key / Value Detection

    private func copyableKeyValue(
        from line: String
    ) -> (key: String, value: String)? {

        let trimmed = line.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.contains("@"),
           (
                trimmed.hasSuffix("#") ||
                trimmed.hasSuffix("$")
           ) {
            return nil
        }

        if trimmed.hasPrefix("http://") ||
           trimmed.hasPrefix("https://") {
            return nil
        }

        let separators = [
            ":",
            "：",
            "="
        ]

        var foundKey = ""
        var foundValue = ""

        for separator in separators {

            guard let range = trimmed.range(
                of: separator
            ) else {
                continue
            }

            let key = String(
                trimmed[..<range.lowerBound]
            )
            .trimmingCharacters(
                in: .whitespaces
            )

            let value = String(
                trimmed[range.upperBound...]
            )
            .trimmingCharacters(
                in: .whitespaces
            )

            if !key.isEmpty && !value.isEmpty {

                foundKey = key
                foundValue = value

                break
            }
        }

        guard !foundKey.isEmpty,
              !foundValue.isEmpty else {
            return nil
        }

        let normalizedKey = foundKey
            .lowercased()
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        let allowedKeys: Set<String> = [
            "username",
            "user",
            "login",
            "password",
            "passwd",
            "pass",
            "private key",
            "public key",
            "key",
            "secret",
            "token",
            "access token",
            "api key",
            "api secret",
            "uuid",
            "id",
            "address",
            "host",
            "hostname",
            "port",
            "url",
            "endpoint",
            "server",
            "domain",
            "email",
            "用户名",
            "用户",
            "登录名",
            "密码",
            "私钥",
            "公钥",
            "密钥",
            "令牌",
            "地址",
            "主机",
            "服务器",
            "端口",
            "域名",
            "链接"
        ]

        guard allowedKeys.contains(
            normalizedKey
        ) else {
            return nil
        }

        return (
            key: foundKey,
            value: foundValue
        )
    }

    // MARK: - PEM Detection

    private func pemBlock(
        from lines: [String],
        at index: Int
    ) -> (
        text: String,
        endIndex: Int
    )? {

        guard index >= 0,
              index < lines.count else {
            return nil
        }

        let first = lines[index]
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard first.hasPrefix("-----BEGIN "),
              first.contains("KEY-----")
        else {
            return nil
        }

        var endIndex = index

        while endIndex < lines.count {

            let current = lines[endIndex]
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            if current.hasPrefix("-----END ") {

                let text = lines[
                    index...endIndex
                ]
                .joined(separator: "\n")

                return (
                    text: text,
                    endIndex: endIndex
                )
            }

            endIndex += 1
        }

        return nil
    }

    // MARK: - Quick Commands

    private var quickCommands: some View {

        ScrollView(
            .horizontal,
            showsIndicators: false
        ) {

            HStack(spacing: 7) {

                quickButton("ls") {
                    runCommand("ls -la")
                }

                quickButton("pwd") {
                    runCommand("pwd")
                }

                quickButton("whoami") {
                    runCommand("whoami")
                }

                quickButton("uname") {
                    runCommand("uname -a")
                }

                quickButton("df") {
                    runCommand("df -h")
                }

                quickButton("free") {
                    runCommand("free -h")
                }

                quickButton("ip") {
                    runCommand("ip addr")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color.black)
    }

    private func quickButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {

        Button(action: action) {

            Text(title)
                .font(
                    .system(
                        size: 11,
                        weight: .medium,
                        design: .monospaced
                    )
                )
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(
                        cornerRadius: 6
                    )
                    .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Compact Keyboard

    private var compactKeyboard: some View {

        ScrollView(
            .horizontal,
            showsIndicators: false
        ) {

            HStack(spacing: 5) {

                keyboardButton("Ctrl+C") {
                    session.sendRaw("\u{03}")
                }

                keyboardButton("Ctrl+D") {
                    session.sendRaw("\u{04}")
                }

                keyboardButton("Ctrl+L") {
                    session.sendRaw("\u{0C}")
                }

                keyboardButton("Ctrl+Z") {
                    session.sendRaw("\u{1A}")
                }

                keyboardButton("Ctrl+A") {
                    session.sendRaw("\u{01}")
                }

                keyboardButton("Ctrl+E") {
                    session.sendRaw("\u{05}")
                }

                keyboardButton("Ctrl+U") {
                    session.sendRaw("\u{15}")
                }

                keyboardButton("Ctrl+K") {
                    session.sendRaw("\u{0B}")
                }

                keyboardButton("Tab") {
                    session.sendRaw("\t")
                }

                keyboardButton("Esc") {
                    session.sendRaw("\u{1B}")
                }

                keyboardButton("↑") {
                    if session.commandIsRunning {
                        session.sendRaw("\u{1B}[A")
                    } else {
                        NotificationCenter.default.post(
                            name: .terminalMoveCursorUp,
                            object: nil
                        )
                    }
                }

                keyboardButton("↓") {
                    if session.commandIsRunning {
                        session.sendRaw("\u{1B}[B")
                    } else {
                        NotificationCenter.default.post(
                            name: .terminalMoveCursorDown,
                            object: nil
                        )
                    }
                }

                keyboardButton("←") {
                    if session.commandIsRunning {
                        session.sendRaw("\u{1B}[D")
                    } else {
                        NotificationCenter.default.post(
                            name: .terminalMoveCursorLeft,
                            object: nil
                        )
                    }
                }

                keyboardButton("→") {
                    if session.commandIsRunning {
                        session.sendRaw("\u{1B}[C")
                    } else {
                        NotificationCenter.default.post(
                            name: .terminalMoveCursorRight,
                            object: nil
                        )
                    }
                }

                keyboardButton("空格") {
                    if session.commandIsRunning {
                        session.sendRaw(" ")
                    } else {
                        NotificationCenter.default.post(
                            name: .terminalInsertText,
                            object: " "
                        )
                    }
                }

                keyboardButton("退格") {
                    if session.commandIsRunning {
                        session.sendRaw("\u{7F}")
                    } else {
                        NotificationCenter.default.post(
                            name: .terminalBackspace,
                            object: nil
                        )
                    }
                }

                keyboardButton("Enter") {
                    executeCurrentInput()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .background(
            Color.white.opacity(0.025)
        )
    }

    private func keyboardButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {

        Button(action: action) {

            Text(title)
                .font(
                    .system(
                        size: 10,
                        weight: .medium,
                        design: .monospaced
                    )
                )
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(
                        cornerRadius: 5
                    )
                    .fill(Color.white.opacity(0.09))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Command Input

    private var commandInput: some View {

        VStack(spacing: 5) {

            HStack(spacing: 7) {

                Text(
                    session.commandIsRunning
                    ? "↳"
                    : (session.currentPrompt.isEmpty
                       ? "$"
                       : session.currentPrompt)
                )
                .font(
                    .system(
                        size: 12,
                        design: .monospaced
                    )
                )
                .foregroundColor(
                    session.commandIsRunning
                    ? .orange
                    : .green
                )
                .lineLimit(1)

                CommandEditorView(
                    text: $commandText,
                    systemKeyboardEnabled: showSystemKeyboard
                ) {
                    executeCurrentInput()
                }
                .frame(minHeight: 38, maxHeight: 80)

                Button {
                    executeCurrentInput()
                } label: {

                    Image(
                        systemName:
                            session.commandIsRunning
                            ? "arrow.up.circle.fill"
                            : "return"
                    )
                    .font(.system(size: 22))
                    .foregroundColor(
                        session.commandIsRunning
                        ? .orange
                        : .green
                    )
                }
            }

            HStack {

                Button {
                    showSystemKeyboard.toggle()
                } label: {
                    Label(
                        showSystemKeyboard
                        ? "隐藏键盘"
                        : "系统键盘",
                        systemImage:
                            showSystemKeyboard
                            ? "keyboard.chevron.compact.down"
                            : "keyboard"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                }

                Spacer()

                if session.commandIsRunning {
                    Text("当前命令正在等待输入")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                } else {
                    Text("Enter 执行命令")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 6)
        .padding(.bottom, 7)
        .background(Color.black)
    }

    // MARK: - Settings

    private var settingsView: some View {

        NavigationStack {

            Form {

                Section("SSH") {

                    TextField(
                        "服务器地址",
                        text: $host
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(
                        "端口",
                        text: $port
                    )
                    .keyboardType(.numberPad)

                    TextField(
                        "用户名",
                        text: $username
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    SecureField(
                        "密码",
                        text: $password
                    )
                }

                Section {

                    Button("连接") {
                        showSettings = false
                        connectIfNeeded()
                    }

                    if session.isConnected {

                        Button(
                            "断开连接",
                            role: .destructive
                        ) {
                            session.disconnect()
                            showSettings = false
                        }
                    }
                }
            }
            .navigationTitle("SSH 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {

                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("关闭") {
                        showSettings = false
                    }
                }
            }
        }
    }

    // MARK: - Toast

    private var toastView: some View {

        VStack {

            Spacer()

            Text(toastMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.88))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            Color.white.opacity(0.15),
                            lineWidth: 1
                        )
                )
                .padding(.bottom, 90)
        }
        .transition(.opacity)
        .animation(
            .easeInOut(duration: 0.15),
            value: showToast
        )
    }

    // MARK: - Actions

    private func executeCurrentInput() {

        let value = commandText
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !value.isEmpty else {
            return
        }

        session.submitInput(value)

        commandText = ""

        if !showSystemKeyboard {
            NotificationCenter.default.post(
                name: .terminalResignEditor,
                object: nil
            )
        }
    }

    private func runCommand(
        _ command: String
    ) {

        guard !command.isEmpty else {
            return
        }

        session.sendCommand(command)
    }

    private func connectIfNeeded() {

        guard !host.isEmpty else {
            showToast("请输入服务器地址")
            return
        }

        let portValue =
            Int(port) ?? 22

        guard !username.isEmpty else {
            showToast("请输入用户名")
            return
        }

        session.connect(
            host: host,
            port: portValue,
            username: username,
            password: password
        )
    }

    // MARK: - Copy

    private func copyWholeBlock(
        _ item: CommandHistoryItem
    ) {

        var text = ""

        if !item.prompt.isEmpty {
            text += item.prompt + "\n"
        }

        text += "$ "
        text += item.command

        if !item.output.isEmpty {
            text += "\n"
            text += item.output
        }

        UIPasteboard.general.string = text

        showToast("整段已复制")
    }

    private func copyOutput(
        _ output: String
    ) {

        guard !output.isEmpty else {
            showToast("没有输出内容")
            return
        }

        UIPasteboard.general.string = output

        showToast("输出已复制")
    }

    private func showToast(
        _ message: String
    ) {

        toastMessage = message

        withAnimation {
            showToast = true
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.4
        ) {
            withAnimation {
                showToast = false
            }
        }
    }
}

// MARK: - Command Editor

struct CommandEditorView: UIViewRepresentable {

    @Binding var text: String

    var systemKeyboardEnabled: Bool

    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(
        context: Context
    ) -> UITextView {

        let textView = UITextView()

        textView.delegate = context.coordinator

        textView.backgroundColor = .clear

        textView.textColor = .white

        textView.font = UIFont.monospacedSystemFont(
            ofSize: 14,
            weight: .regular
        )

        textView.autocorrectionType = .no

        textView.autocapitalizationType = .none

        textView.spellCheckingType = .no

        textView.smartDashesType = .no

        textView.smartQuotesType = .no

        textView.smartInsertDeleteType = .no

        textView.returnKeyType = .go

        textView.textContainerInset = UIEdgeInsets(
            top: 7,
            left: 0,
            bottom: 7,
            right: 0
        )

        textView.isScrollEnabled = true

        textView.keyboardType = .asciiCapable

        if !systemKeyboardEnabled {
            textView.inputView =
                UIView(frame: .zero)
        }

        context.coordinator.textView = textView

        NotificationCenter.default.addObserver(
            forName: .terminalInsertText,
            object: nil,
            queue: .main
        ) { notification in

            guard let value =
                    notification.object as? String
            else {
                return
            }

            textView.insertText(value)
        }

        NotificationCenter.default.addObserver(
            forName: .terminalBackspace,
            object: nil,
            queue: .main
        ) { _ in

            guard let selectedRange =
                    textView.selectedTextRange
            else {
                return
            }

            if selectedRange.isEmpty {

                if let position =
                    textView.position(
                        from: selectedRange.start,
                        offset: -1
                    ) {

                    textView.textRange(
                        from: position,
                        to: selectedRange.start
                    ).map {
                        textView.replace(
                            $0,
                            withText: ""
                        )
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .terminalMoveCursorLeft,
            object: nil,
            queue: .main
        ) { _ in
            moveCursor(
                in: textView,
                offset: -1
            )
        }

        NotificationCenter.default.addObserver(
            forName: .terminalMoveCursorRight,
            object: nil,
            queue: .main
        ) { _ in
            moveCursor(
                in: textView,
                offset: 1
            )
        }

        NotificationCenter.default.addObserver(
            forName: .terminalMoveCursorUp,
            object: nil,
            queue: .main
        ) { _ in
            moveCursorVertical(
                in: textView,
                direction: -1
            )
        }

        NotificationCenter.default.addObserver(
            forName: .terminalMoveCursorDown,
            object: nil,
            queue: .main
        ) { _ in
            moveCursorVertical(
                in: textView,
                direction: 1
            )
        }

        NotificationCenter.default.addObserver(
            forName: .terminalResignEditor,
            object: nil,
            queue: .main
        ) { _ in
            textView.resignFirstResponder()
        }

        return textView
    }

    func updateUIView(
        _ textView: UITextView,
        context: Context
    ) {

        if textView.text != text {
            textView.text = text
        }

        let shouldUseSystemKeyboard =
            systemKeyboardEnabled

        let currentlyUsingHiddenKeyboard =
            textView.inputView != nil

        if shouldUseSystemKeyboard {
            if currentlyUsingHiddenKeyboard {
                textView.inputView = nil
                textView.reloadInputViews()
            }
        } else {
            if !currentlyUsingHiddenKeyboard {
                textView.inputView =
                    UIView(frame: .zero)
                textView.reloadInputViews()
            }
        }
    }

    static func dismantleUIView(
        _ textView: UITextView,
        coordinator: Coordinator
    ) {

        NotificationCenter.default.removeObserver(
            coordinator
        )
    }

    // MARK: Coordinator

    final class Coordinator:
        NSObject,
        UITextViewDelegate {

        var parent: CommandEditorView

        weak var textView: UITextView?

        init(
            _ parent: CommandEditorView
        ) {
            self.parent = parent
        }

        func textViewDidChange(
            _ textView: UITextView
        ) {

            parent.text = textView.text
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {

            if text == "\n" {

                DispatchQueue.main.async {
                    self.parent.onSubmit()
                }

                return false
            }

            return true
        }
    }

    // MARK: Cursor Helpers

    private func moveCursor(
        in textView: UITextView,
        offset: Int
    ) {

        guard let selectedRange =
                textView.selectedTextRange
        else {
            return
        }

        let current =
            selectedRange.start

        guard let position =
                textView.position(
                    from: current,
                    offset: offset
                )
        else {
            return
        }

        textView.selectedTextRange =
            textView.textRange(
                from: position,
                to: position
            )
    }

    private func moveCursorVertical(
        in textView: UITextView,
        direction: Int
    ) {

        guard let selectedRange =
                textView.selectedTextRange
        else {
            return
        }

        let current =
            selectedRange.start

        let caretRect =
            textView.caretRect(
                for: current
            )

        let x =
            caretRect.midX

        let y =
            caretRect.midY +
            CGFloat(direction) *
            max(caretRect.height, 18)

        let point = CGPoint(
            x: x,
            y: y
        )

        if let position =
            textView.closestPosition(
                to: point
            ) {

            textView.selectedTextRange =
                textView.textRange(
                    from: position,
                    to: position
                )
        }
    }
}

// MARK: - Notifications

extension Notification.Name {

    static let terminalInsertText =
        Notification.Name(
            "terminalInsertText"
        )

    static let terminalBackspace =
        Notification.Name(
            "terminalBackspace"
        )

    static let terminalMoveCursorLeft =
        Notification.Name(
            "terminalMoveCursorLeft"
        )

    static let terminalMoveCursorRight =
        Notification.Name(
            "terminalMoveCursorRight"
        )

    static let terminalMoveCursorUp =
        Notification.Name(
            "terminalMoveCursorUp"
        )

    static let terminalMoveCursorDown =
        Notification.Name(
            "terminalMoveCursorDown"
        )

    static let terminalResignEditor =
        Notification.Name(
            "terminalResignEditor"
        )
}
