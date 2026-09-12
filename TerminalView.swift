import SwiftUI
import UIKit

struct TerminalView: View {
    @ObservedObject var store: ServerStore
    let profile: ServerProfile

    @StateObject private var session = SSHSession()
    @State private var commandText = ""
    @State private var showingAddQuickCommand = false
    @State private var newQuickCommand = ""

    var body: some View {
        VStack(spacing: 0) {
            quickCommandsBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.blocks) { block in
                            blockView(block)
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
                    .onSubmit { sendCommand() }

                Button("发送") { sendCommand() }
                    .disabled(commandText.isEmpty || !session.connected)
            }
            .padding()
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(session.connected ? "断开" : "连接") {
                    toggleConnection()
                }
            }
        }
        .task {
            if !session.connected {
                await session.connect(profile: profile)
            }
        }
        .onDisappear {
            Task { await session.disconnect() }
        }
    }

    private var quickCommandsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.quickCommands, id: \.self) { command in
                    Button(command) {
                        commandText = command
                        sendCommand()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(.footnote, design: .monospaced))
                }

                Button {
                    showingAddQuickCommand = true
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemBackground))
        .alert("添加常用命令", isPresented: $showingAddQuickCommand) {
            TextField("命令内容", text: $newQuickCommand)
            Button("取消", role: .cancel) { newQuickCommand = "" }
            Button("添加") {
                store.addQuickCommand(newQuickCommand)
                newQuickCommand = ""
            }
        }
    }

    private func blockView(_ block: SSHBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("$ \(block.command)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)

                Spacer()

                Button {
                    UIPasteboard.general.string = block.output.isEmpty ? block.command : block.output
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.gray)
                }
            }

            if !block.output.isEmpty {
                Text(block.output)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }

            Divider()
                .background(Color.gray.opacity(0.3))
        }
    }

    private func sendCommand() {
        guard !commandText.isEmpty else { return }
        let command = commandText
        commandText = ""
        session.runCommand(command)
    }

    private func toggleConnection() {
        if session.connected {
            Task { await session.disconnect() }
        } else {
            Task { await session.connect(profile: profile) }
        }
    }
}
