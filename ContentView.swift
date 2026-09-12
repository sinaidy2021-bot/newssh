import SwiftUI

struct ContentView: View {
    @StateObject private var session = SSHSession()

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var commandText = ""

    var body: some View {
        NavigationStack {
            Group {
                if session.connected {
                    terminalView
                } else {
                    connectionForm
                }
            }
            .navigationTitle("MySSH")
        }
    }

    private var connectionForm: some View {
        Form {
            Section("服务器信息") {
                TextField("主机地址", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("端口", text: $port)
                    .keyboardType(.numberPad)
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
            }

            Section {
                Button("连接") {
                    connect()
                }
                .disabled(host.isEmpty || username.isEmpty || Int(port) == nil)
            }

            if !session.status.isEmpty {
                Section {
                    Text(session.status)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var terminalView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(session.blocks) { block in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("$ \(block.command)")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.green)
                                if !block.output.isEmpty {
                                    Text(block.output)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
                            }
                            .id(block.id)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black)
                .onChange(of: session.blocks.count) { _ in
                    if let last = session.blocks.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            HStack {
                TextField("输入命令", text: $commandText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        sendCommand()
                    }

                Button("发送") {
                    sendCommand()
                }
                .disabled(commandText.isEmpty)
            }
            .padding()

            Button("断开连接", role: .destructive) {
                Task {
                    await session.disconnect()
                }
            }
            .padding(.bottom)
        }
    }

    private func connect() {
        guard let portNumber = Int(port) else { return }
        Task {
            await session.connect(
                host: host,
                port: portNumber,
                username: username,
                password: password
            )
        }
    }

    private func sendCommand() {
        let command = commandText
        commandText = ""
        session.beginCommand(command)
    }
}

#Preview {
    ContentView()
}
