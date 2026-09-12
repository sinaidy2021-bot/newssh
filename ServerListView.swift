import SwiftUI

// MARK: - Server Model

struct ServerItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String
}

// MARK: - Server List

struct ServerListView: View {

    @State private var servers: [ServerItem] = []
    @State private var showingAddSheet = false

    private let storageKey = "SavedSSHServers"

    var body: some View {
        NavigationView {
            List {
                serverListContent
            }
            .navigationTitle("服务器列表")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddServerView(
                    servers: $servers,
                    storageKey: storageKey
                )
            }
            .onAppear {
                loadServers()
            }
        }
    }

    @ViewBuilder
    private var serverListContent: some View {
        if servers.isEmpty {
            EmptyServerView()
        } else {
            ForEach(servers) { server in
                ServerRowView(server: server)
            }
            .onDelete(perform: deleteServer)
        }
    }

    // MARK: - Storage

    private func loadServers() {
        guard let data = UserDefaults.standard.data(
            forKey: storageKey
        ) else {
            servers = []
            return
        }

        guard let decoded = try? JSONDecoder().decode(
            [ServerItem].self,
            from: data
        ) else {
            servers = []
            return
        }

        servers = decoded
    }

    private func deleteServer(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
        saveServers()
    }

    private func saveServers() {
        guard let encoded = try? JSONEncoder().encode(
            servers
        ) else {
            return
        }

        UserDefaults.standard.set(
            encoded,
            forKey: storageKey
        )
    }
}

// MARK: - Server Row

private struct ServerRowView: View {

    let server: ServerItem

    var body: some View {
        NavigationLink {
            TerminalView(
                serverName: server.name,
                host: server.host,
                port: server.port,
                username: server.username,
                password: server.password
            )
        } label: {
            VStack(
                alignment: .leading,
                spacing: 4
            ) {
                Text(server.name)
                    .font(.headline)

                Text(
                    "\(server.username)@\(server.host):\(server.port)"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Empty Server View

private struct EmptyServerView: View {

    var body: some View {
        VStack(
            alignment: .center,
            spacing: 12
        ) {
            Image(systemName: "server.rack")
                .font(.system(size: 44))
                .foregroundColor(.gray)

            Text("暂无服务器")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("点击右上角「+」添加你的 VPS 服务器")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 180
        )
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }
}

// MARK: - Add Server View

private struct AddServerView: View {

    @Environment(\.dismiss) private var dismiss

    @Binding var servers: [ServerItem]

    let storageKey: String

    @State private var newName = ""
    @State private var newHost = ""
    @State private var newPort = "22"
    @State private var newUsername = "root"
    @State private var newPassword = ""

    var body: some View {
        NavigationView {
            Form {

                Section {
                    TextField(
                        "名称 (如: 香港VPS)",
                        text: $newName
                    )

                    TextField(
                        "主机 IP / 域名",
                        text: $newHost
                    )
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                    TextField(
                        "端口",
                        text: $newPort
                    )
                    .keyboardType(.numberPad)

                } header: {
                    Text("基本信息")
                }

                Section {
                    TextField(
                        "用户名",
                        text: $newUsername
                    )
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                    SecureField(
                        "密码",
                        text: $newPassword
                    )

                } header: {
                    Text("认证信息")
                }
            }
            .navigationTitle("添加服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {

                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(
                    placement: .confirmationAction
                ) {
                    Button("保存") {
                        addServer()
                    }
                    .disabled(
                        newName.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                        ||
                        newHost.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                }
            }
        }
    }

    // MARK: - Add

    private func addServer() {

        let name = newName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let host = newHost.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let username = newUsername.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let portValue = Int(newPort) ?? 22

        let server = ServerItem(
            name: name,
            host: host,
            port: portValue,
            username: username.isEmpty ? "root" : username,
            password: newPassword
        )

        servers.append(server)

        saveServers()

        dismiss()
    }

    // MARK: - Storage

    private func saveServers() {

        guard let encoded = try? JSONEncoder().encode(
            servers
        ) else {
            return
        }

        UserDefaults.standard.set(
            encoded,
            forKey: storageKey
        )
    }
}
