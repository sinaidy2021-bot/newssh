import Foundation
import Combine

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
        didSet { save() }
    }

    @Published var quickCommands: [String] = [
        "ls -la",
        "df -h",
        "top -bn1",
        "whoami",
        "pwd"
    ] {
        didSet { saveQuickCommands() }
    }

    private let serversKey = "saved_servers"
    private let legacyServersKey = "SavedSSHServers"
    private let quickCommandsKey = "quick_commands"

    init() {
        load()
        loadQuickCommands()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: serversKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            servers = decoded
            return
        }

        // 兼容旧版 ServerListView 使用的 SavedSSHServers。
        if let data = UserDefaults.standard.data(forKey: legacyServersKey),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            servers = decoded
            save()
        }
    }

    private func saveQuickCommands() {
        UserDefaults.standard.set(quickCommands, forKey: quickCommandsKey)
    }

    private func loadQuickCommands() {
        if let saved = UserDefaults.standard.stringArray(forKey: quickCommandsKey),
           !saved.isEmpty {
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
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !quickCommands.contains(value) else { return }
        quickCommands.append(value)
    }

    func deleteQuickCommand(at offsets: IndexSet) {
        quickCommands.remove(atOffsets: offsets)
    }
}
