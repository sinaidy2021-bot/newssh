import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Quick Command

struct QuickCmd:
    Identifiable,
    Codable,
    Equatable {

    var id = UUID()

    var name: String

    var cmd: String
}

// MARK: - Command Editor Bridge

final class CommandEditorBridge:
    ObservableObject {

    weak var textView: UITextView?

    func insert(
        _ text: String
    ) {

        textView?.insertText(
            text
        )
    }

    func paste() {

        textView?.paste(nil)
    }

    func backspace() {

        textView?.deleteBackward()
    }

    func moveLeft() {

        guard
            let textView,
            let range =
                textView.selectedTextRange
        else {
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

        guard
            let textView,
            let range =
                textView.selectedTextRange
        else {
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

        moveVertical(
            -1
        )
    }

    func moveDown() {

        moveVertical(
            1
        )
    }

    private func moveVertical(
        _ direction: CGFloat
    ) {

        guard
            let textView,
            let range =
                textView.selectedTextRange
        else {
            return
        }

        let caret =
            textView.caretRect(
                for: range.start
            )

        let lineHeight =
            max(
                textView.font?.lineHeight ?? 18,
                18
            )

        let point =
            CGPoint(
                x: caret.midX,
                y:
                    caret.midY
                    + direction * lineHeight
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

// MARK: - Command Editor

struct CommandEditorView:
    UIViewRepresentable {

    @Binding var text: String

    @Binding var systemKeyboardEnabled: Bool

    let bridge:
        CommandEditorBridge

    let onSubmit:
        () -> Void

    func makeCoordinator()
        -> Coordinator {

        Coordinator(
            self
        )
    }

    func makeUIView(
        context:
            Context
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

        textView.textContainer
            .lineFragmentPadding = 0

        textView.text =
            text

        // 默认关闭系统键盘，
        // 但 UITextView 本身仍然可以操作光标。
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
        context:
            Context
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
                    location:
                        safeLocation,
                    length: 0
                )
        }

        if context.coordinator
            .lastSystemKeyboardState
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

                uiView.reloadInputViews()
            }
        }
    }

    final class Coordinator:
        NSObject,
        UITextViewDelegate {

        var parent:
            CommandEditorView

        var lastSystemKeyboardState =
            false

        init(
            _ parent:
                CommandEditorView
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

            if text == "\n" {

                parent.onSubmit()

                return false
            }

            return true
        }
    }
}

// MARK: - Terminal View

struct TerminalView:
    View {

    let serverName: String

    let host: String

    let port: Int

    let username: String

    let password: String

    @StateObject private var session =
        SSHSession()

    @State private var inputCommand =
        ""

    @State private var systemKeyboardEnabled =
        false

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

    // MARK: Body

    var body: some View {

        ZStack {

            VStack(
                spacing: 0
            ) {

                quickCommandBar

                terminalArea

                compactKeyboard
                    .background(
                        Color(
                            white: 0.075
                        )
                    )
            }

            toastView

            keyboardButton
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

            addCommandSheet
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

    // MARK: Quick Command Bar

    private var quickCommandBar:
        some View {

        ScrollView(
            .horizontal,
            showsIndicators: false
        ) {

            HStack(
                spacing: 8
            ) {

                Button {

                    showingAddSheet =
                        true

                } label: {

                    HStack(
                        spacing: 3
                    ) {

                        Image(
                            systemName:
                                "plus"
                        )

                        Text(
                            "添加"
                        )
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
                        Color.blue.opacity(
                            0.3
                        )
                    )
                    .foregroundColor(
                        .blue
                    )
                    .cornerRadius(
                        6
                    )
                }

                ForEach(
                    quickCommands
                ) { item in

                    Button {

                        runCommand(
                            item.cmd
                        )

                    } label: {

                        Text(
                            item.name
                        )
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
                            Color(
                                white: 0.18
                            )
                        )
                        .foregroundColor(
                            .white
                        )
                        .cornerRadius(
                            6
                        )
                    }
                    .contextMenu {

                        Button(
                            role:
                                .destructive
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
            Color(
                white: 0.12
            )
        )
    }

    // MARK: Terminal Area

    private var terminalArea:
        some View {

        ScrollViewReader { proxy in

            ScrollView {

                LazyVStack(
                    alignment:
                        .leading,
                    spacing: 10
                ) {

                    ForEach(
                        session.history
                    ) { item in

                        commandBlock(
                            item
                        )
                        .id(
                            item.id
                        )
                    }

                    if session.isConnected {

                        currentInputView
                            .id(
                                "CURRENT_INPUT"
                            )
                    }

                    Color.clear
                        .frame(
                            height: 8
                        )
                        .id(
                            "BOTTOM"
                        )
                }
                .padding(
                    8
                )
                .frame(
                    maxWidth:
                        .infinity,
                    alignment:
                        .topLeading
                )
            }
            .background(
                Color.black
            )

            .onChange(
                of:
                    session.history.count
            ) { _ in

                scrollBottom(
                    proxy
                )
            }

            .onChange(
                of:
                    session.history.last?.output
            ) { _ in

                scrollBottom(
                    proxy
                )
            }

            .onChange(
                of:
                    session.currentPrompt
            ) { _ in

                scrollBottom(
                    proxy
                )
            }

            .onChange(
                of:
                    inputCommand
            ) { _ in

                scrollBottom(
                    proxy
                )
            }
        }
    }

    // MARK: Command Block

    private func commandBlock(
        _ item:
            CommandHistoryItem
    ) -> some View {

        VStack(
            alignment:
                .leading,
            spacing: 6
        ) {

            if item.command == "system" {

                HStack {

                    Text(
                        "[系统状态]"
                    )
                    .font(
                        .system(
                            size: 11,
                            weight: .bold,
                            design:
                                .monospaced
                        )
                    )
                    .foregroundColor(
                        .yellow
                    )

                    Spacer()

                    copyButton(
                        title:
                            "复制",
                        text:
                            item.output
                    )
                }

                renderOutput(
                    item.output,
                    color:
                        .yellow
                )

            } else {

                // -----------------------------
                // 命令
                // -----------------------------

                HStack(
                    alignment:
                        .top,
                    spacing: 4
                ) {

                    Text(
                        item.prompt.isEmpty
                        ? session.currentPrompt
                        : item.prompt
                    )
                    .font(
                        .system(
                            size: 13,
                            weight: .bold,
                            design:
                                .monospaced
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
                            design:
                                .monospaced
                        )
                    )
                    .foregroundColor(
                        .white
                    )
                    .textSelection(
                        .enabled
                    )

                    Spacer()
                }

                // -----------------------------
                // 输出
                // -----------------------------

                if !item.output.isEmpty {

                    renderOutput(
                        item.output,
                        color:
                            .green
                    )
                }

                // -----------------------------
                // 操作
                // -----------------------------

                HStack(
                    spacing: 6
                ) {

                    copyButton(
                        title:
                            "复制输出",
                        text:
                            item.output
                    )

                    let prompt =
                        item.prompt.isEmpty
                        ? session.currentPrompt
                        : item.prompt

                    copyButton(
                        title:
                            "复制整段",
                        text:
                            "\(prompt) \(item.command)\n\(item.output)"
                    )

                    Spacer()
                }
            }
        }
        .padding(
            8
        )
        .background(
            Color(
                white: 0.05
            )
        )
        .cornerRadius(
            6
        )
    }

    // MARK: Output

    @ViewBuilder
    private func renderOutput(
        _ text: String,
        color: Color
    ) -> some View {

        let lines =
            text.components(
                separatedBy:
                    "\n"
            )

        VStack(
            alignment:
                .leading,
            spacing: 2
        ) {

            ForEach(
                Array(
                    lines.enumerated()
                ),
                id:
                    \.offset
            ) { _, line in

                outputLine(
                    line,
                    color:
                        color
                )
            }
        }
    }

    // MARK: Output Line

    @ViewBuilder
    private func outputLine(
        _ line: String,
        color: Color
    ) -> some View {

        let value =
            line.trimmingCharacters(
                in: .whitespaces
            )

        // -----------------------------
        // 空行
        // -----------------------------

        if value.isEmpty {

            Text(" ")
                .font(
                    .system(
                        size: 13,
                        design:
                            .monospaced
                    )
                )

            return
        }

        // -----------------------------
        // key: value
        // -----------------------------

        if let colon =
            value.firstIndex(
                of: ":"
            ) {

            let key =
                String(
                    value[
                        ..<colon
                    ]
                )
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

            let copiedValue =
                String(
                    value[
                        value.index(
                            after:
                                colon
                        )...
                    ]
                )
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

            // 避免把普通 URL / 时间等乱识别
            let shouldShowCopy =
                !key.isEmpty
                &&
                !copiedValue.isEmpty
                &&
                key.count <= 40

            HStack(
                alignment:
                    .center,
                spacing: 6
            ) {

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
                    color
                )
                .textSelection(
                    .enabled
                )

                Spacer(
                    minLength: 3
                )

                if shouldShowCopy {

                    Button {

                        UIPasteboard
                            .general
                            .string =
                            copiedValue

                        showToast(
                            "已复制 \(key)"
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
                        .cornerRadius(
                            4
                        )
                    }
                }
            }

        } else {

            Text(
                line
            )
            .font(
                .system(
                    size: 13,
                    design:
                        .monospaced
                )
            )
            .foregroundColor(
                color
            )
            .textSelection(
                .enabled
            )
        }
    }

    // MARK: Copy Button

    private func copyButton(
        title: String,
        text: String
    ) -> some View {

        Button {

            UIPasteboard
                .general
                .string =
                text

            showToast(
                "已复制"
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
                    title
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
            .cornerRadius(
                4
            )
        }
    }

    // MARK: Current Input

    private var currentInputView:
        some View {

        HStack(
            alignment:
                .top,
            spacing: 4
        ) {

            Text(
                session.currentPrompt
            )
            .font(
                .system(
                    size: 13,
                    weight:
                        .bold,
                    design:
                        .monospaced
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
    }

    // MARK: Compact Keyboard

    private var compactKeyboard:
        some View {

        VStack(
            spacing: 2
        ) {

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
                        Color.blue.opacity(
                            0.35
                        )
                ) {

                    pasteClipboard()
                }

                Spacer(
                    minLength: 3
                )

                Button {

                    executeCurrentInput()

                } label: {

                    VStack(
                        spacing: 0
                    ) {

                        Text(
                            session.commandIsRunning
                            ? "发送"
                            : "回车"
                        )
                        .font(
                            .system(
                                size: 10,
                                weight:
                                    .bold
                            )
                        )

                        Text(
                            session.commandIsRunning
                            ? "输入"
                            : "执行"
                        )
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
                    .cornerRadius(
                        5
                    )
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

    // MARK: Horizontal Keyboard Row

    private func horizontalKeyRow(
        _ keys:
            [(String, String?)]
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
                    id:
                        \.offset
                ) { _, item in

                    miniKey(
                        item.0,
                        hint:
                            item.1
                    ) {

                        handleKey(
                            item.0
                        )
                    }
                    .frame(
                        width:
                            keyWidth(
                                item.0
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

        if label.hasPrefix(
            "Ctrl+"
        ) {
            return 62
        }

        if label == "Tab"
            || label == "Esc" {

            return 48
        }

        return 48
    }

    // MARK: Key Handling

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

    // MARK: Mini Key

    private func miniKey(
        _ label: String,
        hint: String? = nil,
        icon: String? = nil,
        color:
            Color =
                Color(
                    white: 0.20
                ),
        action:
            @escaping () -> Void
    ) -> some View {

        Button(
            action:
                action
        ) {

            VStack(
                spacing: 0
            ) {

                if let icon {

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

                Text(
                    label
                )
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
                .lineLimit(
                    1
                )

                if let hint {

                    Text(
                        hint
                    )
                    .font(
                        .system(
                            size: 7
                        )
                    )
                    .lineLimit(
                        1
                    )
                }
            }
            .frame(
                maxWidth:
                    .infinity
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
            .cornerRadius(
                4
            )
        }
    }

    // MARK: Keyboard Button

    private var keyboardButton:
        some View {

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
                    .foregroundColor(
                        .white
                    )
                    .frame(
                        width: 34,
                        height: 34
                    )
                    .background(
                        Color(
                            white: 0.22
                        )
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

    // MARK: Toast

    @ViewBuilder
    private var toastView:
        some View {

        if let copiedTip {

            VStack {

                Spacer()

                Text(
                    copiedTip
                )
                .font(
                    .system(
                        size: 12,
                        weight: .medium
                    )
                )
                .foregroundColor(
                    .white
                )
                .padding(
                    .horizontal,
                    12
                )
                .padding(
                    .vertical,
                    8
                )
                .background(
                    Color.black.opacity(
                        0.85
                    )
                )
                .cornerRadius(
                    8
                )
                .padding(
                    .bottom,
                    100
                )
            }
            .transition(
                .opacity
            )
        }
    }

    // MARK: Paste

    private func pasteClipboard() {

        guard
            let string =
                UIPasteboard
                    .general
                    .string,
            !string.isEmpty
        else {

            showToast(
                "剪贴板为空"
            )

            return
        }

        editorBridge.insert(
            string
        )

        showToast(
            "已粘贴"
        )
    }

    // MARK: Execute

    private func executeCurrentInput() {

        let text =
            inputCommand

        guard !text.isEmpty else {
            return
        }

        // ----------------------------------------
        // 当前命令正在运行：
        //
        // 这是交互输入。
        //
        // y
        // n
        // 1
        // 2
        // password
        // q
        //
        // 全部直接进入当前 PTY。
        // ----------------------------------------

        if session.commandIsRunning {

            session.sendInteractiveInput(
                text + "\n"
            )

        } else {

            // ----------------------------------------
            // 当前没有程序运行：
            //
            // 才是新 Shell 命令。
            // ----------------------------------------

            let command =
                text.trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

            guard !command.isEmpty else {
                return
            }

            runCommand(
                command
            )
        }

        inputCommand = ""

        systemKeyboardEnabled =
            false

        editorBridge.textView?
            .resignFirstResponder()
    }

    // MARK: Run Command

    private func runCommand(
        _ command: String
    ) {

        session.sendCommand(
            command
        )
    }

    // MARK: Scroll

    private func scrollBottom(
        _ proxy:
            ScrollViewProxy
    ) {

        DispatchQueue.main.async {

            withAnimation(
                .easeOut(
                    duration: 0.08
                )
            ) {

                proxy.scrollTo(
                    "BOTTOM",
                    anchor: .bottom
                )
            }
        }
    }

    // MARK: Connect

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

    // MARK: Toast

    private func showToast(
        _ message: String
    ) {

        withAnimation {

            copiedTip =
                message
        }

        DispatchQueue.main.asyncAfter(
            deadline:
                .now() + 1.6
        ) {

            withAnimation {

                copiedTip =
                    nil
            }
        }
    }

    // MARK: Quick Commands

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

            quickCommands =
                decoded

        } else {

            quickCommands = [

                QuickCmd(
                    name:
                        "输入 k 菜单",
                    cmd:
                        "k"
                ),

                QuickCmd(
                    name:
                        "面板管理",
                    cmd:
                        "x-ui"
                ),

                QuickCmd(
                    name:
                        "查看文件",
                    cmd:
                        "ls -la"
                ),

                QuickCmd(
                    name:
                        "磁盘空间",
                    cmd:
                        "df -h"
                ),

                QuickCmd(
                    name:
                        "系统信息",
                    cmd:
                        "uname -a"
                )
            ]

            saveQuickCommands()
        }
    }

    private func addQuickCmd() {

        let name =
            newCmdName.trimmingCharacters(
                in:
                    .whitespaces
            )

        let command =
            newCmdContent.trimmingCharacters(
                in:
                    .whitespaces
            )

        guard !name.isEmpty,
              !command.isEmpty
        else {
            return
        }

        quickCommands.append(
            QuickCmd(
                name:
                    name,
                cmd:
                    command
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

        guard let data =
                try? JSONEncoder().encode(
                    quickCommands
                )
        else {
            return
        }

        UserDefaults.standard.set(
            data,
            forKey:
                storageKey
        )
    }

    // MARK: Add Command Sheet

    private var addCommandSheet:
        some View {

        NavigationView {

            Form {

                Section(
                    header:
                        Text(
                            "快捷命令"
                        )
                ) {

                    TextField(
                        "名称，例如：3x-ui",
                        text:
                            $newCmdName
                    )

                    TextField(
                        "命令，例如：x-ui",
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

                    Button(
                        "取消"
                    ) {

                        showingAddSheet =
                            false
                    }
                }

                ToolbarItem(
                    placement:
                        .confirmationAction
                ) {

                    Button(
                        "保存"
                    ) {

                        addQuickCmd()

                        showingAddSheet =
                            false
                    }
                    .disabled(
                        newCmdName
                            .trimmingCharacters(
                                in:
                                    .whitespaces
                            )
                            .isEmpty
                        ||
                        newCmdContent
                            .trimmingCharacters(
                                in:
                                    .whitespaces
                            )
                            .isEmpty
                    )
                }
            }
        }
    }
}
