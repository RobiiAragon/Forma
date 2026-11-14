import SwiftUI

@main
struct FormaApp: App {
    @StateObject private var store: ScanStore
    private let hostedUnitTests: Bool
    init() {
        // Hosted unit tests must not recover or modify the user's real library.
        let testing = NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["FORMA_UI_TESTING"] == "1" ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        let isolated = testing ? FileManager.default.temporaryDirectory.appendingPathComponent("Forma-TestHost-\(UUID().uuidString)") : nil
        hostedUnitTests = testing && ProcessInfo.processInfo.environment["FORMA_UI_TESTING"] != "1"
        _store = StateObject(wrappedValue: ScanStore(baseURL: isolated))
        if !testing { ProcessingActivityCoordinator.shared.configure() }
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if hostedUnitTests {
                    VStack(spacing: 18) {
                        ProgressView()
                        Text("Comprobando Forma").font(.title2.bold())
                        Text("Mantén esta pantalla abierta mientras terminan las pruebas.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(FormaStyle.background)
                } else {
                    LibraryView().environmentObject(store)
                        .task { await GaussianJobRegistry.shared.recoverRunningJobs() }
                }
            }.preferredColorScheme(.dark).tint(FormaStyle.accent)
        }
    }
}
