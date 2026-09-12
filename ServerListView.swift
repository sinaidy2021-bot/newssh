import SwiftUI

struct ServerListView: View {
    @ObservedObject var store: ServerStore
    @State private var showingAddSheet = false

    var body: some View {
        List {
            ForEach(store.servers) { server in
                NavigationLink {
                    TerminalView(store: store, profile: server)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name)
                            .font(.headline)
                        Text("\(server.username)@\(server.host):\(server.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: store.deleteServer)
        }
        .navigationTitle("我的服务器")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if store.servers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("还没有服务器")
                        .font(.headline)
                    Text("点击右上角加号添加一台服务器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddServerView(store: store)
        }
    }
}

struct AddServerView: View {
    @ObservedObject var store: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("备注名称") {
                    TextField("例如：我的服务器", text: $name)
                }
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
            }
            .navigationTitle("添加服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(host.isEmpty || username.isEmpty || Int(port) == nil)
                }
            }
        }
    }

    private func save() {
        guard let portNumber = Int(port) else { return }
        let profile = ServerProfile(
            name: name.isEmpty ? host : name,
            host: host,
            port: portNumber,
            username: username,
            password: password
        )
        store.addServer(profile)
        dismiss()
    }
}
