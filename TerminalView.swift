import SwiftUI
import UIKit

struct TerminalView: View {
    let serverName: String
    let host: String
    let port: Int
    let username: String
    let password: String
    @ObservedObject var store: ServerStore

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: SSHSession
    @State private var commandText = ""
    @State private var shouldAutoScroll = true
    @State private var showMiniKeyboard = true
    @FocusState private var commandFieldFocused: Bool

    private let bottomID = "BOTTOM_ANCHOR"

    init(
        serverName: String,
        host: String,
        port: Int,
        username: String,
        password: String,
        store: ServerStore
    ) {
        self.serverName = serverName
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.store = store

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
            terminalView
            Divider()
            quickCommands
            Divider()
            commandBar
            Divider()
            keyboardPanel
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(serverName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            session.connect()
        }
        .onDisappear {
            session.disconnect()
        }
        .onChange(of: scenePhase) { _, phase in
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

    private var connectionBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isConnected ? .green : .red)
                .frame(width: 8, height: 8)

            Text(session.statusText)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Button {
                shouldAutoScroll.toggle()
            } label: {
                Text(shouldAutoScroll ? "跟随" : "到底部")
                    .font(.caption)
            }

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

    private var terminalView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Text(session.terminalText.isEmpty ? " " : session.terminalText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)

                Color.clear
                    .frame(height: 1)
                    .id(bottomID)
            }
            .background(Color.black)
            .scrollIndicators(.visible)
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        shouldAutoScroll = false
                    }
            )
            .onChange(of: session.outputRevision) { _, _ in
                guard shouldAutoScroll else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
    }

    private var quickCommands: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.quickCommands, id: \.self) { command in
                        Button(command) {
                            executeCommand(command)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .buttonStyle(.bordered)
                        .contextMenu {
                            Button {
                                copyText(command)
                            } label: {
                                Label("复制此命令", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Button {
                copyText(store.quickCommands.joined(separator: "\n"))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.bordered)
            .accessibilityLabel("复制全部快捷命令")
        }
        .background(Color(.secondarySystemBackground))
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            TextField("输入命令…", text: $commandText, axis: .vertical)
                .font(.system(size: 15, design: .monospaced))
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($commandFieldFocused)
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

    private var keyboardPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showMiniKeyboard.toggle()
                    }
                } label: {
                    Label(
                        showMiniKeyboard ? "收起" : "展开",
                        systemImage: showMiniKeyboard ? "chevron.down" : "chevron.up"
                    )
                    .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.bordered)

                Button {
                    commandFieldFocused = true
                } label: {
                    Label("系统键盘", systemImage: "keyboard")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)

            if showMiniKeyboard {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            key("1") { session.sendKey("1") }
                            key("2") { session.sendKey("2") }
                            key("3") { session.sendKey("3") }
                            key("4") { session.sendKey("4") }
                            key("5") { session.sendKey("5") }
                            key("k") { session.sendKey("k") }
                        }

                        HStack(spacing: 5) {
                            key("6") { session.sendKey("6") }
                            key("7") { session.sendKey("7") }
                            key("8") { session.sendKey("8") }
                            key("9") { session.sendKey("9") }
                            key("0") { session.sendKey("0") }
                            key("-") { session.sendKey("-") }
                        }

                        HStack(spacing: 5) {
                            key("Ctrl+C", tint: .red) {
                                session.sendCtrlC()
                            }
                            key("ESC", tint: .orange) {
                                session.sendEscape()
                            }
                            key("空格") {
                                session.sendSpace()
                            }
                            key("退格") {
                                session.sendBackspace()
                            }
                        }

                        HStack(spacing: 5) {
                            key("x-ui") {
                                executeCommand("x-ui")
                            }
                            key("q退出", tint: .purple) {
                                session.sendKey("q")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 5) {
                        key("粘贴", tint: .blue) {
                            pasteToTerminal()
                        }
                        .frame(width: 82, height: 58)

                        key("回车", tint: .blue) {
                            session.sendKey("\r")
                        }
                        .frame(width: 82, height: 112)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 7)
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private func key(
        _ title: String,
        tint: Color = .blue,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    private func executeCommandText() {
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        commandText = ""
        executeCommand(command)
    }

    private func executeCommand(_ command: String) {
        shouldAutoScroll = true
        session.sendCommand(command)
    }

    private func copyText(_ text: String) {
        UIPasteboard.general.string = text
    }

    private func pasteToTerminal() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            return
        }
        session.sendKey(text)
    }
}
