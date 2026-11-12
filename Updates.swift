// "Check for Updates…" in the app menu: asks GitHub for the latest release and says whether this build is behind it.
import AppKit

private var checking = false  // main thread only; stops a second click from stacking a second alert

func checkForUpdates() {
    #if FAKE_UPDATE  // test build only (SWIFTFLAGS=-DFAKE_UPDATE ./build.sh): offers the DMG at URL $FAKE_DMG as version 99.0
    if let dmg = ProcessInfo.processInfo.environment["FAKE_DMG"] {
        if ProcessInfo.processInfo.environment["FAKE_AUTO"] != nil {  // press Download by itself: tests no click is needed after it
            RunLoop.main.add(Timer(timeInterval: 2, repeats: false) { _ in NSApp.stopModal(withCode: .alertFirstButtonReturn) }, forMode: .common)
        }
        return showUpdateResult(.success(Release(version: "99.0", page: URL(string: RELEASES_PAGE)!, dmg: URL(string: dmg)!)))
    }
    #endif
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
    install(dmg, version: release.version)
}

// A URLSession download carries no quarantine flag, so Gatekeeper never asks for "Open Anyway".
// A plain window with a progress bar, not a modal alert: a modal session holds off terminate until it is clicked away.
private func install(_ dmg: URL, version: String) {
    var task: URLSessionDownloadTask!
    task = URLSession.shared.downloadTask(with: dmg) { file, _, error in
        var failure: String?
        if let file {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("otterscan-update-\(UUID().uuidString)")
            let img = tmp.appendingPathExtension("dmg")
            do {
                try FileManager.default.moveItem(at: file, to: img)
                try runInstaller(img, mount: tmp)
            } catch { failure = error.localizedDescription }
        } else if (error as? URLError)?.code != .cancelled { failure = error?.localizedDescription ?? "Download failed" }
        DispatchQueue.main.async {
            progressWindow?.close(); progressWindow = nil
            if let failure {
                let a = NSAlert(); a.messageText = "Couldn't install the update"; a.informativeText = failure
                a.runModal()
            } else if file != nil { NSApp.terminate(nil) }
        }
    }
    showProgress(version, task)
    task.resume()
}

private var progressWindow: NSPanel?  // main thread only

private func showProgress(_ version: String, _ task: URLSessionDownloadTask) {
    let icon = NSImageView(image: NSApp.applicationIconImage)
    icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
    let title = NSTextField(labelWithString: "Updating to OtterScan \(version)")
    title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let note = NSTextField(labelWithString: "OtterScan will restart by itself when it's ready.")
    note.textColor = .secondaryLabelColor
    let bar = NSProgressIndicator()
    bar.style = .bar
    bar.observedProgress = task.progress
    let cancel = NSButton(title: "Cancel", target: task, action: #selector(URLSessionTask.cancel))
    cancel.keyEquivalent = "\u{1b}"
    let buttons = NSStackView(views: [NSView(), cancel])
    let text = NSStackView(views: [title, note, bar, buttons])
    text.orientation = .vertical; text.alignment = .leading; text.spacing = 10
    text.setCustomSpacing(16, after: bar)  // air between the bar and Cancel
    for v in [bar, buttons] { v.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
    let row = NSStackView(views: [icon, text])
    row.alignment = .top; row.spacing = 20
    text.widthAnchor.constraint(equalToConstant: 320).isActive = true
    // Pinned with explicit margins: an NSStackView's edgeInsets left the bottom edge tight against Cancel.
    let content = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(row)
    NSLayoutConstraint.activate([
        row.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
        row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28)])
    content.layoutSubtreeIfNeeded()

    let w = NSPanel(contentRect: NSRect(origin: .zero, size: content.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
    w.title = "Software Update"
    w.hidesOnDeactivate = false  // a panel vanishes when the app loses focus otherwise
    w.contentView = content
    progressWindow = w
    NSApp.activate()
    w.center(); w.makeKeyAndOrderFront(nil)
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
