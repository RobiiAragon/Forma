import SwiftUI

@main
struct FormaDesktopApp: App {
    @StateObject private var store = DesktopStore()
    var body: some Scene {
        WindowGroup("Forma Desktop") { DesktopContentView(store: store).frame(minWidth: 1000, minHeight: 680) }
            .commands {
                CommandGroup(after: .newItem) { Button("Importar fuentes RGB-D…") { store.chooseImport() }.keyboardShortcut("o") }
            }
    }
}
