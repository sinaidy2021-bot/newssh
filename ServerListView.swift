import SwiftUI

struct ServerItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String
}

struct ServerListView: View {

    @State private var servers: [ServerItem] = []
    @State private var showingAddSheet = false

    @State private var newName = ""
    @State private var newHost = ""
    @State private var newPort = "22"
    @State private var newUsername = "root"
    @State private var newPassword = ""

    private let storageKey = "SavedSSHServers"

    var body: some View {
        NavigationView {
            List {
                if servers.count == 0 {

                    VStack(spacing: 12) {
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
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)

                } else {

                    ForEach(servers) { server in

                        NavigationLink {
                            TerminalView(server: server)
                        } label: {

                            VStack(
                                alignment: .leading,
                                spacing: 5
                            ) {
                                Text(server.name)
                                    .font(.headline)

                                Text(
                                    server.username
                                    + "@"
                                    + server.host
                                    + ":"
                                    + String(server.port)
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    .onDelete { offsets in
                        deleteServers(offsets)
                    }
                }
            }
            .navigationTitle("服务器列表")
            .toolbar {
                ToolbarItem(
                    placement: .navigationBarTrailing
                ) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {

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
                            placement: .navigationBarLeading
                        ) {
                            Button("取消") {
                                showingAddSheet = false
                            }
                        }

                        ToolbarItem(
                            placement: .navigationBarTrailing
                        ) {
                            Button("保存") {
                                addServer()
                            }
                            .disabled(
                                newName
                                    .trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    )
                                    .isEmpty
                                ||
                                newHost
                                    .trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    )
                                    .isEmpty
                            )
                        }
                    }
                }
            }
            .onAppear {
                loadServers()
            }
        }
    }

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

    private func saveServers() {

        guard let data = try? JSONEncoder().encode(
            servers
        ) else {
            return
        }

        UserDefaults.standard.set(
            data,
            forKey: storageKey
        )
    }

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

        let port = Int(newPort) ?? 22

        let server = ServerItem(
            name: name,
            host: host,
            port: port,
            username: username.isEmpty ? "root" : username,
            password: newPassword
        )

        servers.append(server)

        saveServers()

        newName = ""
        newHost = ""
        newPort = "22"
        newUsername = "root"
        newPassword = ""

        showingAddSheet = false
    }

    private func deleteServers(
        _ offsets: IndexSet
    ) {
        servers.remove(atOffsets: offsets)
        saveServers()
    }
}
