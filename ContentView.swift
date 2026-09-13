import SwiftUI

struct ContentView: View {
    @StateObject private var store = ServerStore()

    var body: some View {
        ServerListView(store: store)
    }
}
