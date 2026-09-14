import Foundation
import UIKit
import SwiftTerm
import NIOCore
import NIOPosix
import NIOSSH

struct SSHConnectionInfo: Equatable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let term: String = "xterm-256color"
    let environment: [String: String] = ["LANG": "en_US.UTF-8"]
}

private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // 保持和参考项目一致：先保证密码 SSH 可以直接使用。
        // 正式产品可进一步加入 known-host / 指纹校验。
        validationCompletePromise.succeed(())
    }
}

private final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let password: String
    private var attempted = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !attempted, availableMethods.contains(.password) else {
            nextChallengePromise.succeed(nil)
            return
        }

        attempted = true
        nextChallengePromise.succeed(
            .init(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
        )
    }
}

private enum SSHClientError: Error {
    case invalidChannelType
}

private final class SSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

private final class SSHShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private weak var terminalView: SshTerminalView?
    private let term: String
    private let environment: [String: String]
    private let initialWindowSize: (cols: Int, rows: Int)

    init(
        terminalView: SshTerminalView?,
        term: String,
        environment: [String: String],
        initialWindowSize: (cols: Int, rows: Int)
    ) {
        self.terminalView = terminalView
        self.term = term
        self.environment = environment
        self.initialWindowSize = initialWindowSize
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure {
            context.fireErrorCaught($0)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: term,
            terminalCharacterWidth: max(initialWindowSize.cols, 80),
            terminalRowHeight: max(initialWindowSize.rows, 24),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        context.triggerUserOutboundEvent(pty, promise: nil)

        for (name, value) in environment {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.EnvironmentRequest(
                    wantReply: false,
                    name: name,
                    value: value
                ),
                promise: nil
            )
        }

        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ShellRequest(wantReply: false),
            promise: nil
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data else { return }
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }

        let chunkSize = 4096
        var next = 0
        while next < bytes.count {
            let end = min(next + chunkSize, bytes.count)
            let chunk = Array(bytes[next..<end])
            DispatchQueue.main.async { [weak terminalView] in
                terminalView?.feed(byteArray: chunk)
            }
            next = end
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            DispatchQueue.main.async { [weak terminalView] in
                terminalView?.connectionMessage("SSH 会话结束，状态码 \(status.exitStatus)")
            }
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            DispatchQueue.main.async { [weak terminalView] in
                terminalView?.connectionMessage("SSH 会话结束：\(signal.signalName)")
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

private final class SSHConnection {
    private weak var terminalView: SshTerminalView?
    private let info: SSHConnectionInfo
    private let initialWindowSize: (cols: Int, rows: Int)

    private var group: EventLoopGroup?
    private var channel: Channel?
    private var sessionChannel: Channel?

    init(
        terminalView: SshTerminalView,
        info: SSHConnectionInfo,
        initialWindowSize: (cols: Int, rows: Int)
    ) {
        self.terminalView = terminalView
        self.info = info
        self.initialWindowSize = initialWindowSize
    }

    func connect() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let auth = PasswordAuthDelegate(username: info.username, password: info.password)
        let serverAuth = AcceptAllHostKeysDelegate()

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    guard let self else { return }

                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: auth,
                                serverAuthDelegate: serverAuth
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )

                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHErrorHandler { [weak self] error in
                            self?.handleError(error)
                        }
                    )
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        bootstrap.connect(host: info.host, port: info.port).whenComplete { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                self.handleError(error)
                self.shutdownGroup()
            case .success(let channel):
                self.channel = channel
                self.createSessionChannel(on: channel)
            }
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty, let sessionChannel else { return }

        sessionChannel.eventLoop.execute {
            var buffer = sessionChannel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let payload = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            sessionChannel.writeAndFlush(payload, promise: nil)
        }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let sessionChannel else { return }

        sessionChannel.eventLoop.execute {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0
            )
            sessionChannel.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    func disconnect() {
        if let channel {
            channel.closeFuture.whenComplete { [weak self] _ in
                self?.shutdownGroup()
            }
            channel.close(promise: nil)
        } else {
            shutdownGroup()
        }
    }

    private func createSessionChannel(on channel: Channel) {
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                self.handleError(error)

            case .success(let sshHandler):
                let promise = channel.eventLoop.makePromise(of: Channel.self)

                sshHandler.createChannel(promise, channelType: .session) { [weak self] childChannel, channelType in
                    guard let self, channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                    }

                    return childChannel.eventLoop.makeCompletedFuture {
                        let handler = SSHShellChannelHandler(
                            terminalView: self.terminalView,
                            term: self.info.term,
                            environment: self.info.environment,
                            initialWindowSize: self.initialWindowSize
                        )

                        let sync = childChannel.pipeline.syncOperations
                        try sync.addHandler(handler)
                        try sync.addHandler(
                            SSHErrorHandler { [weak self] error in
                                self?.handleError(error)
                            }
                        )
                    }
                }

                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else { return }

                    switch result {
                    case .failure(let error):
                        self.handleError(error)
                    case .success(let childChannel):
                        self.sessionChannel = childChannel
                        self.sendInitialResize()
                        DispatchQueue.main.async { [weak self] in
                            self?.terminalView?.connectionSucceeded()
                        }
                    }
                }
            }
        }
    }

    private func sendInitialResize() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let terminal = self.terminalView?.getTerminal() else { return }
            self.resize(cols: terminal.cols, rows: terminal.rows)
        }
    }

    private func handleError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.terminalView?.connectionFailed(error.localizedDescription)
        }
    }

    private func shutdownGroup() {
        guard let group else { return }
        self.group = nil
        group.shutdownGracefully { _ in }
    }
}

final class SshTerminalView: TerminalView, TerminalViewDelegate {
    private var sshConnection: SSHConnection?
    private var configuredInfo: SSHConnectionInfo?
    private var inputBuffer = ""

    var onStatus: ((String, Bool) -> Void)?
    var onCommandSubmitted: ((String, Date) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        configureNativeColors()
        allowMouseReporting = true
        optionAsMetaKey = false
        backspaceSendsControlH = false
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        terminalDelegate = self
        configureNativeColors()
        backgroundColor = .black
    }

    deinit {
        sshConnection?.disconnect()
    }

    func configure(connectionInfo: SSHConnectionInfo) {
        guard configuredInfo != connectionInfo else { return }

        configuredInfo = connectionInfo
        sshConnection?.disconnect()
        sshConnection = nil
        inputBuffer = ""
        getTerminal().cmdReset()
        onStatus?("连接中", false)

        let terminal = getTerminal()
        let cols = terminal.cols > 0 ? terminal.cols : 80
        let rows = terminal.rows > 0 ? terminal.rows : 24

        let connection = SSHConnection(
            terminalView: self,
            info: connectionInfo,
            initialWindowSize: (cols, rows)
        )

        sshConnection = connection
        connection.connect()

        DispatchQueue.main.async { [weak self] in
            self?.becomeFirstResponder()
        }
    }

    func sendText(_ text: String, submit: Bool = true) {
        var value = text
        if submit && !value.hasSuffix("\n") && !value.hasSuffix("\r") {
            value += "\n"
        }
        sendRaw(Data(value.utf8))
    }

    func sendRaw(_ data: Data) {
        recordInput(data)
        sshConnection?.send(data)
    }

    func sendSpecial(_ bytes: [UInt8]) {
        sendRaw(Data(bytes))
    }

    func disconnect() {
        sshConnection?.disconnect()
        sshConnection = nil
        onStatus?("未连接", false)
    }

    func copyAllTerminal() {
        selectAll(nil)
        copy(nil)
    }

    func connectionSucceeded() {
        let time = Self.clockString(Date())
        feed(text: "\n[\(time)] SSH 已连接\n")
        onStatus?("已连接", true)
    }

    func connectionFailed(_ message: String) {
        feed(text: "\n[\(Self.clockString(Date()))] SSH 连接失败：\(message)\n")
        onStatus?("连接失败", false)
    }

    func connectionMessage(_ message: String) {
        feed(text: "\n[\(Self.clockString(Date()))] \(message)\n")
        onStatus?("未连接", false)
    }

    private func recordInput(_ data: Data) {
        for byte in data {
            switch byte {
            case 10, 13:
                let command = inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty {
                    onCommandSubmitted?(command, Date())
                }
                inputBuffer = ""
            case 8, 127:
                if !inputBuffer.isEmpty {
                    inputBuffer.removeLast()
                }
            case 32...126:
                if let scalar = UnicodeScalar(Int(byte)) {
                    inputBuffer.append(Character(String(scalar)))
                }
            default:
                break
            }
        }
    }

    private static func clockString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: TerminalViewDelegate

    func scrolled(source: TerminalView, position: Double) {}

    func setTerminalTitle(source: TerminalView, title: String) {}

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sshConnection?.resize(cols: newCols, rows: newRows)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        recordInput(Data(bytes))
        sshConnection?.send(Data(bytes))
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(bytes: content, encoding: .utf8)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
