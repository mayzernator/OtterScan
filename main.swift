// OtterScan: finds devices on your local network. `OtterScan --cli [CIDR] [--ports]` prints a table instead of opening the window.
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        prepareProcess()
        DispatchQueue.global().async { askForLocalNetwork() }  // so macOS asks for Local Network access right away
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

struct OtterScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = ScanModel()

    var body: some Scene {
        WindowGroup("OtterScan") {
            ContentView().environmentObject(model).frame(minWidth: 820, minHeight: 440)
        }
        .defaultSize(width: 1320, height: 760)
        .commands {
            CommandGroup(after: .appSettings) {  // right under Settings… in the menu named after the app
                Button("Check for Updates…") { checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {}  // one window is all this app has
            CommandGroup(replacing: .printItem) {
                Button("Print…") { NotificationCenter.default.post(name: .printList, object: nil) }
                    .keyboardShortcut("p").disabled(model.view == .exposed)
            }
            CommandGroup(before: .toolbar) {
                Button("Devices") { model.view = .devices }.keyboardShortcut("1")
                Button("Ports") { model.view = .ports }.keyboardShortcut("2")
                Button("Public Ports") { model.view = .exposed }.keyboardShortcut("3")
                Button("Next View") {
                    let all = ViewKind.allCases
                    model.view = all[(all.firstIndex(of: model.view)! + 1) % all.count]
                }.keyboardShortcut("`")
                Button(model.showDetails ? "Hide Details" : "Show Details") { model.showDetails.toggle() }.keyboardShortcut("b")
                Divider()
            }
            CommandMenu("Scan") {
                Button(model.running ? "Stop" : "Scan") { model.toggle() }.keyboardShortcut("s")
                Button(model.running && model.live ? "Stop Live Scan" : "Live Scan") { model.liveScan() }.keyboardShortcut("l")
            }
        }
        Settings { PreferencesView() }  // SwiftUI puts this on Cmd+,
    }
}

if CommandLine.arguments.dropFirst().first == "--cli" {
    do { try runCLI(Array(CommandLine.arguments.dropFirst(2))) } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}
UserDefaults.standard.register(defaults: ["defaultMode": "common", "livePause": 5.0, "autoDetails": true])
OtterScanApp.main()
