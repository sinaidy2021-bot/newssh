import SwiftUI

struct TerminalView: View {
    let serverName: String
    let host: String
    let port: Int
    let username: String
    let password: String

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @StateObject private var session: SSHSession

    @State private var commandText = ""
    @State private var shouldAutoScroll = true
    @State private var isAtBottom = true

    private let maxRenderedLinesPerBlock = 400
    private let bottomID = "BOTTOM_ANCHOR"

    init(
        serverName: String,
        host: String,
        port: Int,
        username: String,
        password: String
    ) {
        self.serverName = serverName
        self.host = host
        self.port = port
        self.username = username
        self.password = password

        _session = StateObject(
            wrappedValue: SSHSession(
                host: host,
                port: port,
                username: username,
                password: password
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionBar

            Divider()

            terminalScrollView

            Divider()

            commandBar

            Divider()

            miniKeyboard
        }
        .navigationTitle(serverName)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.black)
        .onAppear {
            session.connect()
        }
        .onDisappear {
            session.disconnect()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                session.appDidEnterBackground()

            case .active:
                session.appWillEnterForeground()

            default:
                break
            }
        }
    }

    private var connectionBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(
                    session.isConnected
                    ? Color.green
                    : Color.red
                )
                .frame(width: 9, height: 9)

            Text(
                session.isConnected
                ? "已连接"
                : "未连接"
            )
            .font(.caption)

            Spacer()

            Button("断开") {
                session.disconnect()
            }
            .font(.caption)
            .disabled(!session.isConnected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var terminalScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(session.history) { block in
                        historyBlock(block)
                            .id(block.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(10)
            }
            .background(Color.black)
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.history.count) { _, _ in
                scheduleScrollIfNeeded(proxy)
            }
        }
    }

    private func historyBlock(
        _ block: CommandHistoryItem
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 4
        ) {
            if block.command != "system" {
                Text(
                    "root@\(serverName)~# \(block.command)"
                )
                .font(
                    .system(
                        size: 14,
                        design: .monospaced
                    )
                )
                .foregroundColor(.green)
                .textSelection(.enabled)
            }

            if !block.output.isEmpty {
                Text(
                    renderedOutput(block.output)
                )
                .font(
                    .system(
                        size: 14,
                        design: .monospaced
                    )
                )
                .foregroundColor(.white)
                .textSelection(.enabled)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
            }
        }
    }

    private func renderedOutput(_ text: String) -> String {
        let lines = text.components(
            separatedBy: .newlines
        )

        if lines.count <= maxRenderedLinesPerBlock {
            return text
        }

        return lines
            .suffix(maxRenderedLinesPerBlock)
            .joined(separator: "\n")
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            TextField(
                "输入命令…",
                text: $commandText,
                axis: .vertical
            )
            .font(
                .system(
                    size: 15,
                    design: .monospaced
                )
            )
            .lineLimit(1...4)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.send)
            .onSubmit {
                executeCommandText()
            }

            Button("发送") {
                executeCommandText()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(Color(.systemBackground))
    }

    private var miniKeyboard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                miniKey("1") { session.sendKey("1") }
                miniKey("2") { session.sendKey("2") }
                miniKey("3") { session.sendKey("3") }
                miniKey("4") { session.sendKey("4") }
                miniKey("5") { session.sendKey("5") }
                miniKey("k") { session.sendKey("k") }
            }

            HStack(spacing: 6) {
                miniKey("6") { session.sendKey("6") }
                miniKey("7") { session.sendKey("7") }
                miniKey("8") { session.sendKey("8") }
                miniKey("9") { session.sendKey("9") }
                miniKey("0") { session.sendKey("0") }
                miniKey("-") { session.sendKey("-") }
            }

            HStack(spacing: 6) {
                miniKey("Ctrl+C") {
                    session.sendCtrlC()
                }

                miniKey("ESC") {
                    session.sendEscape()
                }

                miniKey("空格") {
                    session.sendSpace()
                }

                miniKey("退格") {
                    session.sendBackspace()
                }
            }

            HStack(spacing: 6) {
                miniKey("x-ui") {
                    executeCommand("x-ui")
                }

                miniKey("q退出", color: .purple) {
                    session.sendKey("q")
                }
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
    }

    private func miniKey(
        _ title: String,
        color: Color = .blue,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(
                    .system(
                        size: 13,
                        weight: .medium,
                        design: .monospaced
                    )
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: 34
                )
        }
        .buttonStyle(.bordered)
        .tint(color)
    }

    private func executeCommandText() {
        let value = commandText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !value.isEmpty else {
            return
        }

        commandText = ""
        executeCommand(value)
    }

    private func executeCommand(_ command: String) {
        shouldAutoScroll = true
        session.sendCommand(command)
    }

    private func scheduleScrollIfNeeded(
        _ proxy: ScrollViewProxy
    ) {
        guard shouldAutoScroll else {
            return
        }

        DispatchQueue.main.async {
            proxy.scrollTo(
                bottomID,
                anchor: .bottom
            )
        }
    }
}
