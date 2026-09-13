import SwiftUI
struct TerminalView: View {
    @ObservedObject var session: SSHSession
    @State var cmd = ""
    var body: some View {
        VStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.history) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.command).bold().font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Button("复制整段") { UIPasteboard.general.string = "> \(item.command)\n\(item.output)" }
                                .font(.caption).padding(6).background(Color.blue).foregroundColor(.white).clipShape(Capsule())
                            }
                            Text(item.output.isEmpty ? " " : item.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            if item.output.count > 100 {
                                Button("复制输出") { UIPasteboard.general.string = item.output }.font(.caption)
                            }
                        }.padding(12).background(Color(.secondarySystemBackground)).cornerRadius(10)
                    }
                }.padding()
            }
            HStack {
                TextField("命令", text: $cmd, onCommit: { send() }).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("发送") { send() }
            }.padding()
            HStack {
                Button("Ctrl+C") { session.sendCtrlC() }
                Button("Tab") { session.sendTab() }
                Spacer()
                Button("断开") { session.disconnect() }.tint(.red)
            }.font(.caption).padding(.horizontal).padding(.bottom, 8)
        }.navigationTitle(session.host)
    }
    func send() { let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines); if c.isEmpty { return }; session.sendCommand(c); cmd = "" }
}
