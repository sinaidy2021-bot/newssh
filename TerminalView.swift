import SwiftUI
import UIKit
import SwiftTerm

private struct QuickCmd: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var cmd: String

    init(id: UUID = UUID(), name: String, cmd: String) {
        self.id = id
        self.name = name
        self.cmd = cmd
    }
}

private struct CommandLogItem: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let command: String
}

struct TerminalView: View {
    let serverName: String
    let host: String
    let port: Int
    let username: String
    let password: String

    @Environment(\.dismiss) private var dismiss

    @State private var sshTerminal: SshTerminalView?
    @State private var connectionState = "连接中"
    @State private var isConnected = false
    @State private var showMiniKeyboard = true
    @State private var commandText = ""
    @State private var commandLogs: [CommandLogItem] = []
    @State private var quickCommands: [QuickCmd] = TerminalView.loadQuickCommands()
    @State private var showAddQuickCommand = false
    @State private var newQuickName = ""
    @State private var newQuickCommand = ""
    @State private var showCopiedToast = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if !commandLogs.isEmpty {
                commandLogBar
            }

            terminalArea

            quickCommandBar

            if showMiniKeyboard {
                miniKeyboard
            }
        }
        .background(Color.black)
        .navigationBarHidden(true)
        .sheet(isPresented: $showAddQuickCommand) {
            addQuickCommandSheet
        }
        .overlay(alignment: .center) {
            if showCopiedToast {
                Text("已复制")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.85), in: Capsule())
                    .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.15)) {
                showMiniKeyboard = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.15)) {
                showMiniKeyboard = true
            }
        }
        .onAppear {
            commandLogs.removeAll()
        }
        .onDisappear {
            sshTerminal?.disconnect()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                sshTerminal?.disconnect()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(serverName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(username)@\(host):\(port)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(connectionState)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isConnected ? .green : .secondary)
            }

            Button {
                if let sshTerminal {
                    sshTerminal.copyAllTerminal()
                    showToast()
                }
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 36, height: 36)
            }
            .disabled(sshTerminal == nil)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .background(Color(white: 0.07))
    }

    private var commandLogBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(commandLogs.suffix(2)) { item in
                HStack(spacing: 6) {
                    Text(timeString(item.time))
                        .foregroundStyle(.gray)
                    Text("$")
                        .foregroundStyle(.green)
                    Text(item.command)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(.caption2, design: .monospaced))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.04))
    }

    private var terminalArea: some View {
        TerminalRepresentable(
            terminal: $sshTerminal,
            info: SSHConnectionInfo(
                host: host,
                port: port,
                username: username,
                password: password
            ),
            onStatus: { state, connected in
                connectionState = state
                isConnected = connected
            },
            onCommand: { command, date in
                commandLogs.append(CommandLogItem(time: date, command: command))
                if commandLogs.count > 40 {
                    commandLogs.removeFirst(commandLogs.count - 40)
                }
            }
        )
        .background(Color.black)
        .clipped()
    }

    private var quickCommandBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(quickCommands) { item in
                            Button {
                                sshTerminal?.sendText(item.cmd)
                            } label: {
                                Text(item.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .frame(height: 34)
                                    .background(Color(white: 0.14), in: Capsule())
                            }
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = item.cmd
                                    showToast()
                                } label: {
                                    Label("复制命令", systemImage: "doc.on.doc")
                                }

                                Button {
                                    sshTerminal?.sendText(item.cmd)
                                } label: {
                                    Label("执行", systemImage: "play.fill")
                                }

                                Button(role: .destructive) {
                                    quickCommands.removeAll { $0.id == item.id }
                                    saveQuickCommands()
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }

                Button {
                    showAddQuickCommand = true
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                        .frame(width: 34, height: 34)
                        .background(Color(white: 0.14), in: Circle())
                }

                Button {
                    let text = quickCommands.map { "\($0.name) = \($0.cmd)" }.joined(separator: "\n")
                    UIPasteboard.general.string = text
                    showToast()
                } label: {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Color(white: 0.14), in: Circle())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundStyle(.white)

            HStack(spacing: 8) {
                TextField("输入命令", text: $commandText)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit {
                        submitCommand()
                    }
                    .submitLabel(.send)

                Button("发送") {
                    submitCommand()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .frame(width: 62, height: 40)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 7)
        }
        .background(Color(white: 0.055))
    }

    private var miniKeyboard: some View {
        VStack(spacing: 6) {
            HStack {
                Button("收起") {
                    withAnimation { showMiniKeyboard = false }
                }
                .font(.caption)

                Spacer()

                Button {
                    showMiniKeyboard = false
                    DispatchQueue.main.async {
                        sshTerminal?.becomeFirstResponder()
                    }
                } label: {
                    Label("系统键盘", systemImage: "keyboard")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)

            HStack(spacing: 6) {
                keyRow(["1", "2", "3", "4", "5", "k"])
                largeKeyboardAction("粘贴") {
                    if let value = UIPasteboard.general.string, !value.isEmpty {
                        sshTerminal?.sendText(value, submit: false)
                    }
                }
                .frame(width: 76)
            }

            HStack(spacing: 6) {
                keyRow(["6", "7", "8", "9", "0", "-"])
                largeKeyboardAction("回车") {
                    sshTerminal?.sendSpecial([13])
                }
                .frame(width: 76)
            }

            HStack(spacing: 6) {
                miniKey("Ctrl+C", width: nil) { sshTerminal?.sendSpecial([3]) }
                miniKey("ESC", width: nil) { sshTerminal?.sendSpecial([27]) }
                miniKey("空格", width: nil) { sshTerminal?.sendSpecial([32]) }
                miniKey("退格", width: nil) { sshTerminal?.sendSpecial([127]) }
            }

            HStack(spacing: 6) {
                miniKey("x-ui", width: nil) { sshTerminal?.sendText("x-ui") }
                miniKey("q退出", width: nil) { sshTerminal?.sendSpecial([113]) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 7)
        .background(Color(white: 0.075))
    }


    private func largeKeyboardAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Color(white: 0.20), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func keyRow(_ keys: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                miniKey(key, width: nil) {
                    if key == "k" {
                        sshTerminal?.sendSpecial([107])
                    } else if let byte = UInt8(key) {
                        sshTerminal?.sendSpecial([byte])
                    }
                }
            }
        }
    }

    private func miniKey(_ title: String, width: CGFloat?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: width == nil ? .infinity : width, minHeight: 40)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var addQuickCommandSheet: some View {
        NavigationStack {
            Form {
                Section("快捷命令") {
                    TextField("名称", text: $newQuickName)
                    TextField("命令", text: $newQuickCommand)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("添加快捷命令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showAddQuickCommand = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let name = newQuickName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cmd = newQuickCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !cmd.isEmpty else { return }
                        quickCommands.append(QuickCmd(name: name, cmd: cmd))
                        saveQuickCommands()
                        newQuickName = ""
                        newQuickCommand = ""
                        showAddQuickCommand = false
                    }
                }
            }
        }
    }

    private func submitCommand() {
        let value = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        sshTerminal?.sendText(value)
        commandText = ""
    }

    private func showToast() {
        withAnimation { showCopiedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation { showCopiedToast = false }
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func loadQuickCommands() -> [QuickCmd] {
        if let data = UserDefaults.standard.data(forKey: "MySSH.QuickCommands"),
           let value = try? JSONDecoder().decode([QuickCmd].self, from: data),
           !value.isEmpty {
            return value
        }

        return [
            QuickCmd(name: "ls -la", cmd: "ls -la"),
            QuickCmd(name: "df -h", cmd: "df -h"),
            QuickCmd(name: "top", cmd: "top -bn1"),
            QuickCmd(name: "whoami", cmd: "whoami"),
            QuickCmd(name: "pwd", cmd: "pwd")
        ]
    }

    private func saveQuickCommands() {
        guard let data = try? JSONEncoder().encode(quickCommands) else { return }
        UserDefaults.standard.set(data, forKey: "MySSH.QuickCommands")
    }
}

private struct TerminalRepresentable: UIViewRepresentable {
    @Binding var terminal: SshTerminalView?
    let info: SSHConnectionInfo
    let onStatus: (String, Bool) -> Void
    let onCommand: (String, Date) -> Void

    func makeUIView(context: Context) -> SshTerminalView {
        let view = SshTerminalView(frame: .zero)
        view.onStatus = onStatus
        view.onCommandSubmitted = onCommand
        view.configure(connectionInfo: info)

        DispatchQueue.main.async {
            terminal = view
        }

        return view
    }

    func updateUIView(_ uiView: SshTerminalView, context: Context) {
        uiView.onStatus = onStatus
        uiView.onCommandSubmitted = onCommand
    }
}
