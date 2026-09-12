import SwiftUI

struct ContentView: View {
    @StateObject private var store = ServerStore()

    var body: some View {
        NavigationStack {
            ServerListView(store: store)
        }
    }
}

#Preview {
    ContentView()
}
