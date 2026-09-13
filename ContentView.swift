import SwiftUI
import Foundation

struct ServerProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String
}

final class ServerStore: ObservableObject {
    @Published var servers: [ServerProfile] = [] {
        didSet {
            save()
        }
    }

    @Published var quickCommands: [String] = [
        "ls -la",
        "df -h",
        "top -bn1",
        "whoami",
        "pwd"
    ] {
        didSet {
            saveQuickCommands()
        }
    }

    private let serversKey = "saved_servers"
    private let quickCommandsKey = "quick_commands"

    init() {
        load()
        loadQuickCommands()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serversKey)
        }
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: serversKey),
            let decoded = try? JSONDecoder().decode(
                [ServerProfile].self,
                from: data
            )
        else {
            return
        }

        servers = decoded
    }

    private func saveQuickCommands() {
        UserDefaults.standard.set(
            quickCommands,
            forKey: quickCommandsKey
        )
    }

    private func loadQuickCommands() {
        if let saved = UserDefaults.standard.stringArray(
            forKey: quickCommandsKey
        ), !saved.isEmpty {
            quickCommands = saved
        }
    }

    func addServer(_ profile: ServerProfile) {
        servers.append(profile)
    }

    func deleteServer(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
    }

    func addQuickCommand(_ command: String) {
        let value = command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard
            !value.isEmpty,
            !quickCommands.contains(value)
        else {
            return
        }

        quickCommands.append(value)
    }

    func deleteQuickCommand(at offsets: IndexSet) {
        quickCommands.remove(atOffsets: offsets)
    }
}

struct ContentView: View {
    @StateObject private var store = ServerStore()

    var body: some View {
        ServerListView(store: store)
    }
}
