import SwiftUI

@main
struct QuranApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, idealWidth: 1700, minHeight: 760, idealHeight: 1150)
        }
        .windowResizability(.contentSize)
    }
}
