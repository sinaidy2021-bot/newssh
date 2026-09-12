import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - 快捷命令

struct QuickCmd: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var cmd: String
}

// MARK: - 命令编辑器控制器

final class CommandEditorBridge: ObservableObject {

    weak var textView: UITextView?

    func insert(_ text: String) {

        guard let textView = textView else {
            return
        }

        textView.insertText(text)
    }

    func paste() {

        guard let textView = textView else {
            return
        }

        textView.paste(nil)
    }

    func backspace() {

        guard let textView = textView else {
            return
        }

        textView.deleteBackward()
    }

    func moveLeft() {

        guard let textView = textView,
              let range = textView.selectedTextRange else {
            return
        }

        guard let position =
                textView.position(
                    from: range.start,
                    offset: -1
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

    func moveRight() {

        guard let textView = textView,
              let range = textView.selectedTextRange else {
            return
        }

        guard let position =
                textView.position(
                    from: range.end,
                    offset: 1
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

    func moveUp() {

        moveVertical(-1)
    }

    func moveDown() {

        moveVertical(1)
    }

    private func moveVertical(
        _ direction: CGFloat
    ) {

        guard let textView = textView,
              let range = textView.selectedTextRange else {
            return
        }

        let caret =
            textView.caretRect(
                for: range.start
            )

        let point = CGPoint(
            x: caret.midX,
            y: caret.midY
                + direction *
                max(
                    textView.font?.lineHeight ?? 18,
                    18
                )
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

// MARK: - 真正可自由定位光标的输入框

struct CommandEditorView: UIViewRepresentable {

    @Binding var text: String

    @Binding var systemKeyboardEnabled: Bool

    let bridge: CommandEditorBridge

    let onSubmit: () -> Void

    func makeCoordinator()
        -> Coordinator {

        Coordinator(self)
    }

    func makeUIView(
        context: Context
    ) -> UITextView {

        let textView =
            UITextView()

        textView.delegate =
            context.coordinator

        textView.backgroundColor =
            .clear

        textView.textColor =
            .white

        textView.font =
            UIFont.monospacedSystemFont(
                ofSize: 13,
                weight: .regular
            )

        textView.isEditable =
            true

        textView.isSelectable =
            true

        textView.isScrollEnabled =
            false

        textView.autocorrectionType =
            .no

        textView.spellCheckingType =
            .no

        textView.smartQuotesType =
            .no

        textView.smartDashesType =
            .no

        textView.smartInsertDeleteType =
            .no

        textView.autocapitalizationType =
            .none

        textView.textContainerInset =
            UIEdgeInsets(
                top: 1,
                left: 0,
                bottom: 1,
                right: 0
            )

        textView.textContainer.lineFragmentPadding =
            0

        textView.text =
            text

        // 默认不弹 iPhone 系统键盘。
        // 仍然保留真正 UITextView 的光标、选择、
        // 长按复制、拖动光标等能力。
        textView.inputView =
            UIView(
                frame: .zero
            )

        bridge.textView =
            textView

        return textView
    }

    func updateUIView(
        _ uiView: UITextView,
        context: Context
    ) {

        bridge.textView =
            uiView

        if uiView.text != text {

            let selectedRange =
                uiView.selectedRange

            uiView.text =
                text

            let safeLocation =
                min(
                    selectedRange.location,
                    uiView.text.count
                )

            uiView.selectedRange =
                NSRange(
                    location: safeLocation,
                    length: 0
                )
        }

        if context.coordinator.lastSystemKeyboardState
            != systemKeyboardEnabled {

            context.coordinator
                .lastSystemKeyboardState =
                systemKeyboardEnabled

            if systemKeyboardEnabled {

                uiView.inputView =
                    nil

                uiView.reloadInputViews()

                DispatchQueue.main.async {

                    uiView.becomeFirstResponder()
                }

            } else {

                uiView.inputView =
                    UIView(
                        frame: .zero
                    )

                if uiView.isFirstResponder {

                    uiView.reloadInputViews()

                } else {

                    DispatchQueue.main.async {

                        uiView.becomeFirstResponder()
                    }
                }
            }
        }
    }

    final class Coordinator:
        NSObject,
        UITextViewDelegate {

        var parent: CommandEditorView

        var lastSystemKeyboardState =
            false

        init(
            _ parent: CommandEditorView
        ) {
            self.parent =
                parent
        }

        func textViewDidChange(
            _ textView: UITextView
        ) {

            parent.text =
                textView.text
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {

            // 系统键盘回车直接执行。
            if text == "\n" {

                parent.onSubmit()

                return false
            }

            return true
        }
    }
}

// MARK: - Terminal

struct TerminalView: View {

    let serverName: String
    let host: String
    let port: Int
    let username: String
    let password: String

    @StateObject private var session =
        SSHSession()

    // 真正的命令输入内容
    @State private var inputCommand =
        ""

    // 系统键盘开关
    @State private var systemKeyboardEnabled =
        false

    // UITextView 控制器
    @StateObject private var editorBridge =
        CommandEditorBridge()

    @Environment(\.scenePhase)
    private var scenePhase

    @State private var quickCommands:
        [QuickCmd] = []

    @State private var showingAddSheet =
        false

    @State private var newCmdName =
        ""

    @State private var newCmdContent =
        ""

    @State private var copiedTip:
        String?

    private let storageKey =
        "SavedQuickCommands"

    // MARK: - Body

    var body: some View {

        ZStack {

            VStack(spacing: 0) {

                // MARK: 顶部快捷命令

                ScrollView(
                    .horizontal,
                    showsIndicators: false
                ) {

                    HStack(spacing: 8) {

                        Button {
                            showingAddSheet = true
                        } label: {

                            HStack(spacing: 3) {

                                Image(
                                    systemName: "plus"
                                )

                                Text("添加")
                            }
                            .font(
                                .system(
                                    size: 11,
                                    weight: .bold
                                )
                            )
                            .padding(
                                .horizontal,
                                9
                            )
                            .padding(
                                .vertical,
                                5
                            )
                            .background(
                                Color.blue.opacity(0.3)
                            )
                            .foregroundColor(.blue)
                            .cornerRadius(6)
                        }

                        ForEach(
                            quickCommands
                        ) { item in

                            Button {

                                runCommand(
                                    item.cmd
                                )

                            } label: {

                                Text(item.name)
                                    .font(
                                        .system(
                                            size: 11,
                                            weight: .medium
                                        )
                                    )
                                    .padding(
                                        .horizontal,
                                        9
                                    )
                                    .padding(
                                        .vertical,
                                        5
                                    )
                                    .background(
                                        Color(white: 0.18)
                                    )
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                            }
                            .contextMenu {

                                Button(
                                    role: .destructive
                                ) {

                                    deleteQuickCmd(
                                        item
                                    )

                                } label: {

                                    Label(
                                        "删除快捷键",
                                        systemImage:
                                            "trash"
                                    )
                                }
                            }
                        }
                    }
                    .padding(
                        .horizontal,
                        10
                    )
                    .padding(
                        .vertical,
                        6
                    )
                }
                .background(
                    Color(white: 0.12)
                )

                // MARK: 终端

                ScrollViewReader { proxy in

                    ScrollView {

                        LazyVStack(
                            alignment: .leading,
                            spacing: 10
                        ) {

                            ForEach(
                                session.history
                            ) { item in

                                VStack(
                                    alignment: .leading,
                                    spacing: 6
                                ) {

                                    if item.command ==
                                        "system" {

                                        HStack {

                                            Text(
                                                "[系统状态]"
                                            )
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

                                            Button {

                                                copyBlock(
                                                    item.output,
                                                    tip:
                                                        "已复制系统信息"
                                                )

                                            } label: {

                                                Image(
                                                    systemName:
                                                        "doc.on.doc"
                                                )
                                                .font(
                                                    .system(
                                                        size: 11
                                                    )
                                                )
                                                .foregroundColor(
                                                    .gray
                                                )
                                            }
                                        }

                                        renderOutputLines(
                                            item.output,
                                            defaultColor:
                                                .yellow
                                        )

                                    } else {

                                        // MARK: 命令头

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
                                            .foregroundColor(
                                                .cyan
                                            )

                                            Text(
                                                item.command
                                            )
                                            .font(
                                                .system(
                                                    size: 13,
                                                    weight: .bold,
                                                    design: .monospaced
                                                )
                                            )
                                            .foregroundColor(
                                                .white
                                            )
                                            .textSelection(
                                                .enabled
                                            )

                                            Spacer(
                                                minLength: 4
                                            )
                                        }

                                        // MARK: 该命令自己的输出

                                        renderOutputLines(
                                            item.output,
                                            defaultColor:
                                                .green
                                        )

                                        // MARK: 复制按钮

                                        HStack(spacing: 6) {

                                            Button {

                                                copyBlock(
                                                    item.output,
                                                    tip:
                                                        "已复制本段输出"
                                                )

                                            } label: {

                                                HStack(
                                                    spacing: 4
                                                ) {

                                                    Image(
                                                        systemName:
                                                            "doc.on.doc"
                                                    )

                                                    Text(
                                                        "复制本段输出"
                                                    )
                                                }
                                                .font(
                                                    .system(
                                                        size: 10,
                                                        weight: .medium
                                                    )
                                                )
                                                .foregroundColor(
                                                    .gray
                                                )
                                                .padding(
                                                    .horizontal,
                                                    7
                                                )
                                                .padding(
                                                    .vertical,
                                                    4
                                                )
                                                .background(
                                                    Color(
                                                        white: 0.16
                                                    )
                                                )
                                                .cornerRadius(4)
                                            }

                                            Button {

                                                let prompt =
                                                    item.prompt.isEmpty
                                                    ? session.currentPrompt
                                                    : item.prompt

                                                let fullBlock =
                                                    "\(prompt) \(item.command)\n" +
                                                    item.output

                                                copyBlock(
                                                    fullBlock,
                                                    tip:
                                                        "已复制整段"
                                                )

                                            } label: {

                                                HStack(
                                                    spacing: 4
                                                ) {

                                                    Image(
                                                        systemName:
                                                            "doc.on.doc.fill"
                                                    )

                                                    Text(
                                                        "复制整段"
                                                    )
                                                }
                                                .font(
                                                    .system(
                                                        size: 10,
                                                        weight: .medium
                                                    )
                                                )
                                                .foregroundColor(
                                                    .gray
                                                )
                                                .padding(
                                                    .horizontal,
                                                    7
                                                )
                                                .padding(
                                                    .vertical,
                                                    4
                                                )
                                                .background(
                                                    Color(
                                                        white: 0.16
                                                    )
                                                )
                                                .cornerRadius(4)
                                            }

                                            Spacer()
                                        }
                                    }
                                }
                                .padding(8)
                                .background(
                                    Color(white: 0.05)
                                )
                                .cornerRadius(6)
                                .id(item.id)
                            }

                            // MARK: 当前命令输入

                            if session.isConnected {

                                HStack(
                                    alignment: .top,
                                    spacing: 4
                                ) {

                                    Text(
                                        session.currentPrompt
                                    )
                                    .font(
                                        .system(
                                            size: 13,
                                            weight: .bold,
                                            design: .monospaced
                                        )
                                    )
                                    .foregroundColor(
                                        .cyan
                                    )
                                    .padding(
                                        .top,
                                        3
                                    )

                                    CommandEditorView(
                                        text:
                                            $inputCommand,
                                        systemKeyboardEnabled:
                                            $systemKeyboardEnabled,
                                        bridge:
                                            editorBridge,
                                        onSubmit: {
                                            executeCurrentInput()
                                        }
                                    )
                                    .frame(
                                        minHeight: 22,
                                        maxHeight: 120
                                    )

                                    Spacer(
                                        minLength: 0
                                    )
                                }
                                .padding(
                                    .horizontal,
                                    8
                                )
                                .padding(
                                    .top,
                                    2
                                )
                                .id(
                                    "CURRENT_PROMPT"
                                )
                            }

                            Color.clear
                                .frame(height: 8)
                                .id(
                                    "BOTTOM_ANCHOR"
                                )
                        }
                        .padding(8)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .topLeading
                        )
                    }
                    .background(
                        Color.black
                    )
                    .onChange(
                        of: session.history.count
                    ) { _ in

                        scrollToBottom(
                            proxy: proxy
                        )
                    }
                    .onChange(
                        of: session.history.last?.output
                    ) { _ in

                        scrollToBottom(
                            proxy: proxy
                        )
                    }
                    .onChange(
                        of: session.currentPrompt
                    ) { _ in

                        scrollToBottom(
                            proxy: proxy
                        )
                    }
                    .onChange(
                        of: inputCommand
                    ) { _ in

                        scrollToCurrentCommand(
                            proxy: proxy
                        )
                    }
                }

                // MARK: 紧凑快捷键栏

                compactKeyboard
                    .background(
                        Color(white: 0.075)
                    )
            }

            // MARK: 左下角系统键盘按钮

            VStack {

                Spacer()

                HStack {

                    Button {

                        systemKeyboardEnabled.toggle()

                        DispatchQueue.main.async {
                            editorBridge.textView?
                                .becomeFirstResponder()
                        }

                    } label: {

                        Image(
                            systemName:
                                systemKeyboardEnabled
                                ? "keyboard.chevron.compact.down"
                                : "keyboard"
                        )
                        .font(
                            .system(
                                size: 14,
                                weight: .bold
                            )
                        )
                        .foregroundColor(.white)
                        .frame(
                            width: 34,
                            height: 34
                        )
                        .background(
                            Color(white: 0.22)
                        )
                        .clipShape(
                            Circle()
                        )
                    }
                    .padding(
                        .leading,
                        7
                    )
                    .padding(
                        .bottom,
                        4
                    )

                    Spacer()
                }
            }
        }
        .navigationTitle(
            serverName
        )
        .navigationBarTitleDisplayMode(
            .inline
        )
        .toolbar {

            ToolbarItem(
                placement:
                    .navigationBarTrailing
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
        .sheet(
            isPresented:
                $showingAddSheet
        ) {

            NavigationView {

                Form {

                    Section(
                        header:
                            Text("快捷键属性")
                    ) {

                        TextField(
                            "按键名称 (例如: 3x-ui / x-ui)",
                            text:
                                $newCmdName
                        )

                        TextField(
                            "执行命令 (例如: x-ui)",
                            text:
                                $newCmdContent
                        )
                        .autocapitalization(
                            .none
                        )
                        .disableAutocorrection(
                            true
                        )
                    }
                }
                .navigationTitle(
                    "添加快捷键"
                )
                .navigationBarTitleDisplayMode(
                    .inline
                )
                .toolbar {

                    ToolbarItem(
                        placement:
                            .cancellationAction
                    ) {

                        Button("取消") {

                            showingAddSheet =
                                false
                        }
                    }

                    ToolbarItem(
                        placement:
                            .confirmationAction
                    ) {

                        Button("保存") {

                            addQuickCmd()

                            showingAddSheet =
                                false

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
        .onChange(
            of: scenePhase
        ) { phase in

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

    // MARK: - 紧凑快捷键栏

    private var compactKeyboard: some View {

        VStack(
            spacing: 2
        ) {

            // -----------------------------------------
            // 第一行：数字，可横向滑动
            // -----------------------------------------

            horizontalKeyRow(
                [
                    ("1", nil),
                    ("2", nil),
                    ("3", nil),
                    ("4", nil),
                    ("5", nil),
                    ("6", nil),
                    ("7", nil),
                    ("8", nil),
                    ("9", nil),
                    ("0", nil)
                ]
            )

            // -----------------------------------------
            // 第二行：Ctrl 快捷键
            // -----------------------------------------

            horizontalKeyRow(
                [
                    ("Ctrl+C", "停止"),
                    ("Ctrl+D", "退出"),
                    ("Ctrl+L", "清屏"),
                    ("Ctrl+Z", "挂起"),
                    ("Ctrl+A", "行首"),
                    ("Ctrl+E", "行尾"),
                    ("Ctrl+U", "清前"),
                    ("Ctrl+K", "清后"),
                    ("Ctrl+X", "控制"),
                    ("Tab", "补全"),
                    ("Esc", "取消")
                ]
            )

            // -----------------------------------------
            // 第三行：方向 + 常用符号
            // -----------------------------------------

            horizontalKeyRow(
                [
                    ("↑", "上条"),
                    ("↓", "下条"),
                    ("←", "左移"),
                    ("→", "右移"),
                    ("/", nil),
                    ("-", nil),
                    ("_", nil),
                    (".", nil),
                    (":", nil),
                    ("|", nil),
                    ("$", nil),
                    ("~", nil)
                ]
            )

            // -----------------------------------------
            // 第四行：
            // 左边功能键，右下角固定回车
            // -----------------------------------------

            HStack(
                spacing: 3
            ) {

                miniKey(
                    "空格"
                ) {

                    editorBridge.insert(
                        " "
                    )
                }

                miniKey(
                    "退格",
                    icon:
                        "delete.left"
                ) {

                    editorBridge.backspace()
                }

                miniKey(
                    "x-ui"
                ) {

                    runCommand(
                        "x-ui"
                    )
                }

                miniKey(
                    "88"
                ) {

                    runCommand(
                        "88"
                    )
                }

                miniKey(
                    "粘贴",
                    hint:
                        "剪贴板",
                    color:
                        Color.blue.opacity(0.35)
                ) {

                    pasteClipboard()
                }

                Spacer(
                    minLength: 3
                )

                // 回车永远在最右边
                Button {

                    executeCurrentInput()

                } label: {

                    VStack(
                        spacing: 0
                    ) {

                        Text("回车")
                            .font(
                                .system(
                                    size: 10,
                                    weight: .bold
                                )
                            )

                        Text("执行")
                            .font(
                                .system(
                                    size: 7
                                )
                            )
                    }
                    .frame(
                        width: 68,
                        height: 31
                    )
                    .background(
                        Color.blue
                    )
                    .foregroundColor(
                        .white
                    )
                    .cornerRadius(5)
                }
            }
        }
        .padding(
            .horizontal,
            5
        )
        .padding(
            .top,
            3
        )
        .padding(
            .bottom,
            4
        )
    }

    // MARK: - 横向键盘行

    private func horizontalKeyRow(
        _ keys: [(String, String?)]
    ) -> some View {

        ScrollView(
            .horizontal,
            showsIndicators: false
        ) {

            HStack(
                spacing: 3
            ) {

                ForEach(
                    Array(
                        keys.enumerated()
                    ),
                    id: \.offset
                ) { _, item in

                    let label =
                        item.0

                    let hint =
                        item.1

                    miniKey(
                        label,
                        hint: hint
                    ) {

                        handleKey(
                            label
                        )
                    }
                    .frame(
                        width:
                            keyWidth(
                                label
                            )
                    )
                }
            }
            .padding(
                .horizontal,
                2
            )
        }
        .frame(
            height: 31
        )
    }

    private func keyWidth(
        _ label: String
    ) -> CGFloat {

        if label.count <= 1 {
            return 30
        }

        if label.hasPrefix("Ctrl+") {
            return 62
        }

        if label == "Tab" {
            return 48
        }

        if label == "Esc" {
            return 48
        }

        return 48
    }

    // MARK: - 快捷键处理

    private func handleKey(
        _ label: String
    ) {

        switch label {

        case "Ctrl+C":

            session.sendRaw(
                "\u{03}"
            )

        case "Ctrl+D":

            session.sendRaw(
                "\u{04}"
            )

        case "Ctrl+L":

            session.sendRaw(
                "\u{0C}"
            )

        case "Ctrl+Z":

            session.sendRaw(
                "\u{1A}"
            )

        case "Ctrl+A":

            session.sendRaw(
                "\u{01}"
            )

        case "Ctrl+E":

            session.sendRaw(
                "\u{05}"
            )

        case "Ctrl+U":

            session.sendRaw(
                "\u{15}"
            )

        case "Ctrl+K":

            session.sendRaw(
                "\u{0B}"
            )

        case "Ctrl+X":

            session.sendRaw(
                "\u{18}"
            )

        case "Tab":

            session.sendRaw(
                "\t"
            )

        case "Esc":

            session.sendRaw(
                "\u{1B}"
            )

        case "↑":

            editorBridge.moveUp()

        case "↓":

            editorBridge.moveDown()

        case "←":

            editorBridge.moveLeft()

        case "→":

            editorBridge.moveRight()

        default:

            editorBridge.insert(
                label
            )
        }
    }

    // MARK: - 软键

    private func miniKey(
        _ label: String,
        hint: String? = nil,
        icon: String? = nil,
        color:
            Color = Color(white: 0.20),
        action:
            @escaping () -> Void
    ) -> some View {

        Button(
            action: action
        ) {

            VStack(
                spacing: 0
            ) {

                if let icon = icon {

                    Image(
                        systemName:
                            icon
                    )
                    .font(
                        .system(
                            size: 8
                        )
                    )
                }

                Text(label)
                    .font(
                        .system(
                            size:
                                label.count > 5
                                ? 8
                                : 10,
                            weight:
                                .medium,
                            design:
                                .monospaced
                        )
                    )
                    .lineLimit(1)

                if let hint = hint {

                    Text(hint)
                        .font(
                            .system(
                                size: 7
                            )
                        )
                        .lineLimit(1)
                }
            }
            .frame(
                maxWidth: .infinity
            )
            .frame(
                height:
                    hint == nil
                    ? 29
                    : 30
            )
            .background(
                color
            )
            .foregroundColor(
                .white
            )
            .cornerRadius(4)
        }
    }

    // MARK: - 粘贴

    private func pasteClipboard() {

        guard let pasteString =
                UIPasteboard.general.string,
              !pasteString.isEmpty
        else {

            showToast(
                "剪贴板为空"
            )

            return
        }

        // 插入当前光标位置，
        // 不再无脑 append 到末尾。
        editorBridge.insert(
            pasteString
        )

        showToast(
            "已粘贴到光标位置"
        )
    }

    // MARK: - 复制

    private func copyBlock(
        _ text: String,
        tip: String
    ) {

        UIPasteboard.general.string =
            text

        showToast(
            tip
        )
    }

    // MARK: - 输出渲染

    @ViewBuilder
    private func renderOutputLines(
        _ fullText: String,
        defaultColor: Color
    ) -> some View {

        let lines =
            fullText.components(
                separatedBy: "\n"
            )

        VStack(
            alignment: .leading,
            spacing: 2
        ) {

            ForEach(
                Array(
                    lines.enumerated()
                ),
                id: \.offset
            ) { _, line in

                let trimmed =
                    line.trimmingCharacters(
                        in: .whitespaces
                    )

                let isPromptLine =
                    trimmed.range(
                        of:
                            #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^\r\n]*[#$]$"#,
                        options:
                            .regularExpression
                    ) != nil

                let colonIndex =
                    trimmed.firstIndex(
                        of: ":"
                    )

                let hasKeyValue =
                    !isPromptLine &&
                    !trimmed.isEmpty &&
                    colonIndex != nil

                if hasKeyValue,
                   let colonIndex = colonIndex {

                    let key =
                        String(
                            trimmed[
                                ..<colonIndex
                            ]
                        )
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )

                    let value =
                        String(
                            trimmed[
                                trimmed.index(
                                    after:
                                        colonIndex
                                )...
                            ]
                        )
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )

                    HStack(
                        alignment:
                            .center,
                        spacing: 6
                    ) {

                        Text(line)
                            .font(
                                .system(
                                    size: 13,
                                    design:
                                        .monospaced
                                )
                            )
                            .foregroundColor(
                                defaultColor
                            )
                            .textSelection(
                                .enabled
                            )

                        Spacer(
                            minLength: 3
                        )

                        Button {

                            UIPasteboard.general.string =
                                value

                            showToast(
                                "已复制 \(key) 的值"
                            )

                        } label: {

                            HStack(
                                spacing: 3
                            ) {

                                Image(
                                    systemName:
                                        "doc.on.doc"
                                )

                                Text(
                                    "复制值"
                                )
                            }
                            .font(
                                .system(
                                    size: 10,
                                    weight:
                                        .medium
                                )
                            )
                            .foregroundColor(
                                .cyan
                            )
                            .padding(
                                .horizontal,
                                5
                            )
                            .padding(
                                .vertical,
                                4
                            )
                            .background(
                                Color(
                                    white: 0.18
                                )
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
                            design:
                                .monospaced
                        )
                    )
                    .foregroundColor(
                        defaultColor
                    )
                    .textSelection(
                        .enabled
                    )
                }
            }
        }
    }

    // MARK: - 滚动

    private func scrollToBottom(
        proxy: ScrollViewProxy
    ) {

        DispatchQueue.main.async {

            withAnimation(
                .easeOut(
                    duration: 0.12
                )
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
                .easeOut(
                    duration: 0.08
                )
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

        session.host =
            host

        session.port =
            port

        session.username =
            username

        session.password =
            password

        session.connect()
    }

    private func executeCurrentInput() {

        let cmd =
            inputCommand
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard !cmd.isEmpty else {
            return
        }

        runCommand(
            cmd
        )

        inputCommand =
            ""

        // 执行后恢复成自定义小键盘模式
        systemKeyboardEnabled =
            false

        editorBridge.textView?
            .resignFirstResponder()
    }

    private func runCommand(
        _ cmd: String
    ) {

        session.sendCommand(
            cmd
        )
    }

    // MARK: - Toast

    private func showToast(
        _ msg: String
    ) {

        withAnimation {

            copiedTip =
                msg
        }

        DispatchQueue.main.asyncAfter(
            deadline:
                .now() + 1.8
        ) {

            withAnimation {

                copiedTip =
                    nil
            }
        }
    }

    // MARK: - 快捷命令

    private func loadQuickCommands() {

        if let data =
            UserDefaults.standard.data(
                forKey:
                    storageKey
            ),
           let decoded =
            try? JSONDecoder().decode(
                [QuickCmd].self,
                from:
                    data
            ) {

            self.quickCommands =
                decoded

        } else {

            self.quickCommands = [

                QuickCmd(
                    name:
                        "输入 k 菜单",
                    cmd:
                        "k"
                ),

                QuickCmd(
                    name:
                        "面板管理 (x-ui)",
                    cmd:
                        "x-ui"
                ),

                QuickCmd(
                    name:
                        "查看文件 (ls)",
                    cmd:
                        "ls -la"
                ),

                QuickCmd(
                    name:
                        "磁盘空间 (df)",
                    cmd:
                        "df -h"
                ),

                QuickCmd(
                    name:
                        "系统信息 (uname)",
                    cmd:
                        "uname -a"
                )
            ]

            saveQuickCommands()
        }
    }

    private func addQuickCmd() {

        let name =
            newCmdName
                .trimmingCharacters(
                    in:
                        .whitespaces
                )

        let cmd =
            newCmdContent
                .trimmingCharacters(
                    in:
                        .whitespaces
                )

        guard !name.isEmpty,
              !cmd.isEmpty
        else {
            return
        }

        quickCommands.append(
            QuickCmd(
                name:
                    name,
                cmd:
                    cmd
            )
        )

        saveQuickCommands()

        newCmdName =
            ""

        newCmdContent =
            ""
    }

    private func deleteQuickCmd(
        _ item: QuickCmd
    ) {

        quickCommands.removeAll {

            $0.id ==
                item.id
        }

        saveQuickCommands()
    }

    private func saveQuickCommands() {

        if let encoded =
            try? JSONEncoder().encode(
                quickCommands
            ) {

            UserDefaults.standard.set(
                encoded,
                forKey:
                    storageKey
            )
        }
    }
}
