import SwiftUI

struct ServerItem: Identifiable {
    let id = UUID()
    let name: String
    let host: String
    let port: Int
    let username: String
    let password: String
}

struct ServerListView: View {
    @State private var servers: [ServerItem] = [
        ServerItem(name: "默认测试服务器", host: "127.0.0.1", port: 22, username: "root", password: "")
    ]
    
    @State private var showingAddScreen = false
    @State private var newName = ""
    @State private var newHost = ""
    @State private var newPort = "22"
    @State private var newUsername = "root"
    @State private var newPassword = ""

    var body: some View {
        NavigationView {
            List {
                ForEach(servers) { server in
                    NavigationLink(destination: TerminalView(serverName: server.name)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name)
                                .font(.headline)
                            Text("\(server.username)@\(server.host):\(server.port)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete(perform: deleteServer)
            }
            .navigationTitle("服务器列表")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddScreen = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddScreen) {
                NavigationView {
                    Form {
                        TextField("服务器备注名称", text: $newName)
                        TextField("IP 地址 (Host)", text: $newHost)
                            .keyboardType(.decimalPad)
                            .autocapitalization(.none)
                        TextField("端口 (Port)", text: $newPort)
                            .keyboardType(.numberPad)
                        TextField("用户名 (Username)", text: $newUsername)
                            .autocapitalization(.none)
                        SecureField("密码 (Password)", text: $newPassword)
                    }
                    .navigationTitle("添加服务器")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showingAddScreen = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                addServer()
                            }
                        }
                    }
                }
            }
        }
    }

    private func addServer() {
        let portInt = Int(newPort) ?? 22
        let server = ServerItem(
            name: newName.isEmpty ? newHost : newName,
            host: newHost,
            port: portInt,
            username: newUsername.isEmpty ? "root" : newUsername,
            password: newPassword
        )
        servers.append(server)
        showingAddScreen = false
        
        newName = ""
        newHost = ""
        newPort = "22"
        newUsername = "root"
        newPassword = ""
    }

    private func deleteServer(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
    }
}
