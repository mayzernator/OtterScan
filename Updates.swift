// "Check for Updates…" in the app menu: asks GitHub for the latest release and says whether this build is behind it.
import AppKit

private var checking = false  // main thread only; stops a second click from stacking a second alert

func checkForUpdates() {
    guard !checking, let url = URL(string: RELEASES_API) else { return }
    checking = true
    var req = URLRequest(url: url)
    req.timeoutInterval = 8
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: req) { data, response, error in
        let result = Result { () -> Release in
            guard let data, let http = response as? HTTPURLResponse else { throw error ?? ScanError("No answer from GitHub") }
            return try parseRelease(data, status: http.statusCode)
        }
        DispatchQueue.main.async {
            checking = false
            showUpdateResult(result)
        }
    }.resume()
}

private func showUpdateResult(_ result: Result<Release, Error>) {
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let alert = NSAlert()
    var release: Release?
    switch result {
    case .success(let r) where isNewer(r.version, than: current):
        alert.messageText = "Update available!"
        alert.informativeText = "\(current) -> \(r.version)"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        release = r
    case .success:
        alert.messageText = "You're up to date"
        alert.informativeText = "OtterScan \(current) is the latest version."
    case .failure(let e):
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = e.localizedDescription
    }
    NSApp.activate()
    guard alert.runModal() == .alertFirstButtonReturn, let release else { return }
    guard let dmg = release.dmg else { NSWorkspace.shared.open(release.page); return }
    install(dmg)
}

// A URLSession download carries no quarantine flag, so Gatekeeper never asks for "Open Anyway".
private func install(_ dmg: URL) {
    let note = NSAlert()
    note.messageText = "Downloading update…"
    note.informativeText = "OtterScan will restart when it's installed."
    note.addButton(withTitle: "Hide")
    NSApp.activate()
    URLSession.shared.downloadTask(with: dmg) { file, _, error in
        var failure: String?
        if let file {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("otterscan-update-\(UUID().uuidString)")
            let img = tmp.appendingPathExtension("dmg")
            do {
                try FileManager.default.moveItem(at: file, to: img)
                try runInstaller(img, mount: tmp)
            } catch { failure = error.localizedDescription }
        } else { failure = error?.localizedDescription ?? "Download failed" }
        DispatchQueue.main.async {
            if let failure {
                NSApp.abortModal()
                let a = NSAlert(); a.messageText = "Couldn't install the update"; a.informativeText = failure
                a.runModal()
            } else { NSApp.abortModal(); NSApp.terminate(nil) }  // terminate waits for the open modal, so end it first
        }
    }.resume()
    note.runModal()
}

// Mounts the image, then a detached shell waits for this app to quit, swaps the bundle and reopens it.
private func runInstaller(_ img: URL, mount: URL) throws {
    func sh(_ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw ScanError("\(args[0]) failed") }
    }
    try sh(["hdiutil", "attach", img.path, "-mountpoint", mount.path, "-nobrowse", "-quiet"])
    let app = Bundle.main.bundlePath
    let script = "while kill -0 $1 2>/dev/null; do sleep 0.2; done; rm -rf \"$2\" && ditto \"$3/OtterScan.app\" \"$2\"; xattr -cr \"$2\"; hdiutil detach \"$3\" -quiet; rm -f \"$4\"; open \"$2\""
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script, "sh", String(getpid()), app, mount.path, img.path]
    try p.run()
}
