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
                if servers.isEmpty {
                    VStack(alignment: .center, spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 44))
                            .foregroundColor(.gray)
                        Text("暂无服务器")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("点击右上角「+」添加你的 VPS 服务器")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(servers) { server in
                        NavigationLink(destination: TerminalView(
                            serverName: server.name,
                            host: server.host,
                            port: server.port,
                            username: server.username,
                            password: server.password
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name)
                                    .font(.headline)
                                Text("\(server.username)@\(server.host):\(server.port)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete(perform: deleteServer)
                }
            }
            .navigationTitle("服务器列表")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                NavigationView {
                    Form {
                        Section(header: Text("基本信息")) {
                            TextField("名称 (如: 香港VPS)", text: $newName)
                            TextField("主机 IP / 域名", text: $newHost)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            TextField("端口", text: $newPort)
                                .keyboardType(.numberPad)
                        }
                        Section(header: Text("认证信息")) {
                            TextField("用户名", text: $newUsername)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            SecureField("密码", text: $newPassword)
                        }
                    }
                    .navigationTitle("添加服务器")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showingAddSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                addServer()
                                showingAddSheet = false
                            }
                            .disabled(newName.isEmpty || newHost.isEmpty)
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
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ServerItem].self, from: data) {
            self.servers = decoded
        } else {
            // 清空默认测试机器，保持为空列表
            self.servers = []
        }
    }

    private func addServer() {
        let p = Int(newPort) ?? 22
        let item = ServerItem(
            name: newName.trimmingCharacters(in: .whitespaces),
            host: newHost.trimmingCharacters(in: .whitespaces),
            port: p,
            username: newUsername.trimmingCharacters(in: .whitespaces),
            password: newPassword
        )
        servers.append(item)
        saveServers()
        
        newName = ""
        newHost = ""
        newPort = "22"
        newUsername = "root"
        newPassword = ""
    }

    private func deleteServer(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
        saveServers()
    }

    private func saveServers() {
        if let encoded = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}
