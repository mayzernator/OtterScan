// OtterScan: finds devices on your local network. `OtterScan --cli [CIDR] [--ports]` prints a table instead of opening the window.
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        prepareProcess()
        DispatchQueue.global().async { askForLocalNetwork() }  // so macOS asks for Local Network access right away
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }  // asks for nothing yet
    }

    // macOS hides an app's notifications while it is in front; show ours anyway.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }

    // Clicking a notification brings the app forward and opens that device's details.
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        if let ip = r.notification.request.content.userInfo["ip"] as? String {
            NotificationCenter.default.post(name: .openDevice, object: ip)
        }
        done()
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
            CommandGroup(replacing: .help) {  // there is no help book for the default item to open
                Button("Report a Bug…") {
                    let info = { Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "?" }
                    #if arch(arm64)
                    let arch = "arm64"
                    #else
                    let arch = "x86_64"
                    #endif
                    NSWorkspace.shared.open(bugReportURL(version: info("CFBundleShortVersionString"), build: info("CFBundleVersion"),
                                                         os: ProcessInfo.processInfo.operatingSystemVersionString, arch: arch))
                }
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
UserDefaults.standard.register(defaults: ["defaultMode": "common", "livePause": 5.0, "autoDetails": true, "liveAtLaunch": true])
OtterScanApp.main()
