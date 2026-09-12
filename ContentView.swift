import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var session = SSHSession()
    @State private var host = ""
    @State private var username = "root"
    @State private var port = "22"
    @State private var password = ""
    @State private var command = ""
    @State private var mode = 0

    var body: some View {
        NavigationStack {
            Group {
                if session.connected { terminalView } else { loginView }
            }
            .navigationTitle("我的 SSH")
        }
        .preferredColorScheme(.dark)
    }

    private var loginView: some View {
        Form {
            Section("服务器") {
                TextField("服务器地址", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                TextField("端口", text: $port)
                    .keyboardType(.numberPad)
                SecureField("密码", text: $password)
            }

            Section {
                Button("连接服务器") {
                    Task {
                        await session.connect(
                            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                            port: Int(port) ?? 22,
                            username: username,
                            password: password
                        )
                    }
                }
                .disabled(host.isEmpty || username.isEmpty || password.isEmpty)
            }

            Section {
                Text(session.status)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var terminalView: some View {
        VStack(spacing: 0) {
            HStack {
                Label(session.status, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Picker("", selection: $mode) {
                    Text("分段").tag(0)
                    Text("终端").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Button("断开") { session.disconnect() }
            }
            .padding(10)

            if mode == 0 {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.blocks) { block in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("$ \(block.command)")
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button("复制命令") {
                                        UIPasteboard.general.string = block.command
                                    }
                                    Button("复制输出") {
                                        UIPasteboard.general.string = block.output
                                    }
                                    Button("复制全部") {
                                        UIPasteboard.general.string =
                                            "$ \(block.command)\n\(block.output)"
                                    }
                                }

                                Text(block.output.isEmpty ? "等待输出…" : block.output)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(10)
                }
            } else {
                ScrollView {
                    Text(String(decoding: session.terminalBytes, as: UTF8.self))
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    QuickKey("Esc") { session.write("\u{1B}") }
                    QuickKey("Tab") { session.write("\t") }
                    QuickKey("Ctrl+C") { session.write("\u{03}") }
                    QuickKey("Ctrl+D") { session.write("\u{04}") }
                    QuickKey("↑") { session.write("\u{1B}[A") }
                    QuickKey("↓") { session.write("\u{1B}[B") }
                    QuickKey("←") { session.write("\u{1B}[D") }
                    QuickKey("→") { session.write("\u{1B}[C") }
                    QuickKey("Enter") { session.write("\n") }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            HStack {
                TextField("输入命令…", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendCommand() }

                Button("发送") { sendCommand() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(10)
        }
        .background(Color.black)
    }

    private func sendCommand() {
        guard !command.isEmpty else { return }
        session.beginCommand(command)
        command = ""
    }
}

struct QuickKey: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
    }
}
