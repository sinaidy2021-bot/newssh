import SwiftUI

struct ServerListView: View {
    @ObservedObject var store: ServerStore

    @State private var showingAddSheet = false
    @State private var newName = ""
    @State private var newHost = ""
    @State private var newPort = "22"
    @State private var newUsername = "root"
    @State private var newPassword = ""

    var body: some View {
        NavigationStack {
            List {
                if store.servers.isEmpty {
                    VStack(alignment: .center, spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 44))
                            .foregroundStyle(.gray)

                        Text("暂无服务器")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Text("点击右上角「+」添加你的 VPS 服务器")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.servers) { server in
                        NavigationLink {
                            TerminalView(
                                serverName: server.name,
                                host: server.host,
                                port: server.port,
                                username: server.username,
                                password: server.password
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name)
                                    .font(.headline)

                                Text("\(server.username)@\(server.host):\(server.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete(perform: store.deleteServer)
                }
            }
            .navigationTitle("服务器列表")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        resetForm()
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加服务器")
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                NavigationStack {
                    Form {
                        Section("基本信息") {
                            TextField(
                                "名称（如：香港VPS）",
                                text: $newName
                            )

                            TextField(
                                "主机 IP / 域名",
                                text: $newHost
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            TextField(
                                "端口",
                                text: $newPort
                            )
                            .keyboardType(.numberPad)
                        }

                        Section("认证信息") {
                            TextField(
                                "用户名",
                                text: $newUsername
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            SecureField(
                                "密码",
                                text: $newPassword
                            )
                        }
                    }
                    .navigationTitle("添加服务器")
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
                                addServer()
                            }
                            .disabled(!formIsValid)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 表单验证

    private var formIsValid: Bool {
        let name = newName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let host = newHost.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let port = Int(newPort) ?? 0

        return !name.isEmpty &&
               !host.isEmpty &&
               (1...65535).contains(port)
    }

    // MARK: - 重置表单

    private func resetForm() {
        newName = ""
        newHost = ""
        newPort = "22"
        newUsername = "root"
        newPassword = ""
    }

    // MARK: - 添加服务器

    private func addServer() {
        guard formIsValid else {
            return
        }

        let name = newName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let host = newHost.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let username = newUsername.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let port = Int(newPort) ?? 22

        store.addServer(
            ServerProfile(
                name: name,
                host: host,
                port: port,
                username: username.isEmpty ? "root" : username,
                password: newPassword
            )
        )

        resetForm()
        showingAddSheet = false
    }
}
