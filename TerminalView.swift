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
            terminalView
            quickCommands
            commandBar

            if showMiniKeyboard {
                miniKeyboard
            } else {
                collapsedKeyboardBar
            }
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

    // MARK: - é¡¶é¨è¿æ¥ç¶æ

    private var connectionBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)

            Text(session.statusText)
                .font(.body)
                .lineLimit(1)

            Spacer()

            Button(shouldAutoScroll ? "è·é" : "å°åºé¨") {
                shouldAutoScroll.toggle()
            }

            Button("æ­å¼") {
                session.disconnect()
            }
            .disabled(!session.isConnected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - ç»ç«¯

    private var terminalView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Text(session.terminalText.isEmpty ? " " : session.terminalText)
                    .font(.system(size: 15, design: .monospaced))
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
        .frame(maxHeight: .infinity)
    }

    // MARK: - å¿«æ·å½ä»¤

    private var quickCommands: some View {
        HStack(spacing: 6) {
            Button("+ æ·»å ") {
                commandFieldFocused = true
            }
            .buttonStyle(.borderedProminent)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.quickCommands, id: \.self) { command in
                        HStack(spacing: 0) {
                            Button(command) {
                                executeCommand(command)
                            }
                            .font(.system(size: 13, design: .monospaced))
                            .buttonStyle(.bordered)

                            Button {
                                executeCommand(command)
                            } label: {
                                Text(command)
                            }
                            .font(.system(size: 13, design: .monospaced))
                            .buttonStyle(.bordered)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = command
                                } label: {
                                    Label("å¤å¶æ­¤å½ä»¤", systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                }
            }

            Button {
                let all = store.quickCommands.joined(separator: "\n")
                UIPasteboard.general.string = all
            } label: {
                Image(systemName: "doc.on.doc.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("å¤å¶å¨é¨å¿«æ·å½ä»¤")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    // MARK: - å½ä»¤è¾å¥

    private var commandBar: some View {
        HStack(spacing: 8) {
            TextField("è¾å¥å½ä»¤â¦", text: $commandText, axis: .vertical)
                .focused($commandFieldFocused)
                .font(.system(size: 15, design: .monospaced))
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit {
                    executeCommandText()
                }

            Button("åé") {
                executeCommandText()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(Color(.systemBackground))
    }

    // MARK: - å¯æ¶èµ·è½¯é®ç

    private var miniKeyboard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    showMiniKeyboard = false
                } label: {
                    Label("æ¶èµ·", systemImage: "chevron.down")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    commandFieldFocused = true
                } label: {
                    Label("ç³»ç»é®ç", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                key("1") { session.sendKey("1") }
                key("2") { session.sendKey("2") }
                key("3") { session.sendKey("3") }
                key("4") { session.sendKey("4") }
                key("5") { session.sendKey("5") }
                key("k") { session.sendKey("k") }

                sideKey("ç²è´´", systemImage: "doc.on.clipboard") {
                    sendPaste()
                }
            }

            HStack(spacing: 6) {
                key("6") { session.sendKey("6") }
                key("7") { session.sendKey("7") }
                key("8") { session.sendKey("8") }
                key("9") { session.sendKey("9") }
                key("0") { session.sendKey("0") }
                key("-") { session.sendKey("-") }

                sideKey("åè½¦", systemImage: "return") {
                    session.sendKey("\r")
                }
            }

            HStack(spacing: 6) {
                key("Ctrl+C", tint: .red) { session.sendCtrlC() }
                key("ESC", tint: .orange) { session.sendEscape() }
                key("ç©ºæ ¼") { session.sendSpace() }
                key("éæ ¼") { session.sendBackspace() }
            }

            HStack(spacing: 6) {
                key("x-ui") {
                    executeCommand("x-ui")
                }
                .frame(maxWidth: .infinity)

                key("qéåº", tint: .purple) {
                    session.sendKey("q")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
    }

    private var collapsedKeyboardBar: some View {
        HStack {
            Button {
                showMiniKeyboard = true
            } label: {
                Label("å±å¼é®ç", systemImage: "chevron.up")
            }
            .buttonStyle(.borderedProminent)

            Button {
                commandFieldFocused = true
            } label: {
                Label("ç³»ç»é®ç", systemImage: "keyboard")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - æé®

    private func key(
        _ title: String,
        tint: Color = .blue,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }

    private func sideKey(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
            }
            .frame(width: 112, minHeight: 82)
        }
        .buttonStyle(.borderedProminent)
    }

    // MARK: - æä½

    private func sendPaste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            return
        }
        session.sendKey(text)
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
}
