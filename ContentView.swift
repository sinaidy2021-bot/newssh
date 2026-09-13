import SwiftUI
struct ContentView: View {
    @StateObject var session = SSHSession()
    @State var host = ""
    @State var user = "root"
    @State var pass = ""
    @State var go = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("主机IP", text: $host)
                TextField("用户名", text: $user)
                SecureField("密码", text: $pass)
                Button("连接") {
                    session.host = host; session.username = user; session.password = pass
                    session.connect(); go = true
                }
            }.navigationTitle("MySSH").navigationDestination(isPresented: $go) { TerminalView(session: session) }
        }
    }
}
