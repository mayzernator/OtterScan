// "Check for Updates…" in the app menu: asks GitHub for the latest release and says whether this build is behind it.
import AppKit

private var checking = false  // main thread only; stops a second click from stacking a second alert

// At launch: at most one silent check a day, and only if the Settings toggle is on.
func checkForUpdatesAtLaunch() {
    let d = UserDefaults.standard
    guard d.bool(forKey: "autoUpdate"), Date().timeIntervalSince(d.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast) > 86400 else { return }
    d.set(Date(), forKey: "lastUpdateCheck")
    checkForUpdates(automatic: true)
}

// automatic: say nothing unless an update is available (no "up to date" or error alerts).
func checkForUpdates(automatic: Bool = false) {
    #if FAKE_UPDATE  // test build only (SWIFTFLAGS=-DFAKE_UPDATE ./build.sh): offers the DMG at URL $FAKE_DMG as version 99.0
    if let dmg = ProcessInfo.processInfo.environment["FAKE_DMG"] {
        if ProcessInfo.processInfo.environment["FAKE_AUTO"] != nil {  // press Download by itself: tests no click is needed after it
            RunLoop.main.add(Timer(timeInterval: 2, repeats: false) { _ in NSApp.stopModal(withCode: .alertFirstButtonReturn) }, forMode: .common)
        }
        return showUpdateResult(.success(Release(version: "99.0", page: URL(string: RELEASES_PAGE)!, dmg: URL(string: dmg)!, notes: "## Fixed\n- **No more quitting on big networks.** Nothing else changed.\n\n**Full Changelog**: \(RELEASES_PAGE)")), automatic: automatic)
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
            showUpdateResult(result, automatic: automatic)
        }
    }.resume()
}

private func showUpdateResult(_ result: Result<Release, Error>, automatic: Bool) {
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let d = UserDefaults.standard
    let alert = NSAlert()
    switch result {
    case .success(let r) where isNewer(r.version, than: current):
        if automatic && d.string(forKey: "skippedVersion") == r.version { return }  // a manual check still offers it
        if automatic && d.bool(forKey: "autoInstall"), let dmg = r.dmg { return install(dmg, version: r.version) }
        return promptForUpdate(r, current: current)
    case _ where automatic: return
    case .success(let r): return promptForUpdate(r, current: current, upToDate: true)
    case .failure(let e):
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = e.localizedDescription
    }
    NSApp.activate()
    alert.runModal()
}

// A plain grey window laid out like Sparkle's, not an NSAlert: an alert is glass in macOS 26 and stacks its buttons.
// upToDate: the same window for a manual check that found nothing newer, with that release's notes and only an OK button.
private func promptForUpdate(_ release: Release, current: String, upToDate: Bool = false) {
    let d = UserDefaults.standard
    let icon = NSImageView(image: NSApp.applicationIconImage)
    icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
    let title = NSTextField(labelWithString: upToDate ? "You're up to date!" : "A new version of OtterScan is available!")
    title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let info = NSTextField(wrappingLabelWithString: upToDate
        ? "OtterScan \(current) is the latest version. Here's what's new in \(release.version):"
        : "OtterScan \(release.version) is now available—you have \(current). Would you like to download it now?")
    info.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    let heading = NSStackView(views: [title, info])
    heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 6
    let top = NSStackView(views: [icon, heading])
    top.alignment = .centerY; top.spacing = 16

    // Release notes, as GitHub's Markdown
    let notes = NSTextView()
    notes.isEditable = false
    notes.textContainerInset = NSSize(width: 8, height: 10)
    // Headings and bullets by hand: the inline-only parser keeps line breaks but shows "## " and "- " as typed
    let md = (release.notes.isEmpty ? "No release notes." : release.notes).split(separator: "\n", omittingEmptySubsequences: false).map { line in
        if line.hasPrefix("#") { return "**\(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))**" }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return "•  " + line.dropFirst(2) }
        return String(line)
    }.joined(separator: "\n")
    let text = (try? NSMutableAttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? NSMutableAttributedString(string: md)
    text.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor],
                       range: NSRange(location: 0, length: text.length))
    notes.textStorage?.setAttributedString(text)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .lineBorder
    notes.autoresizingMask = .width
    scroll.documentView = notes
    scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

    let auto = NSButton(checkboxWithTitle: "Automatically download and install updates in the future", target: nil, action: nil)
    auto.controlSize = .small; auto.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    auto.state = d.bool(forKey: "autoInstall") ? .on : .off
    // A borderless link, like the "Learn More" links in System Settings
    let github = NSButton(title: "View on GitHub", target: modalPicker, action: #selector(ModalPicker.open(_:)))
    github.isBordered = false
    github.image = githubMark
    github.imagePosition = .imageLeading
    github.contentTintColor = .linkColor
    github.controlSize = .small; github.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    github.toolTip = release.page.absoluteString
    modalPicker.page = release.page
    let options = NSStackView(views: [auto, NSView(), github])
    func button(_ title: String, _ code: NSApplication.ModalResponse, _ key: String = "") -> NSButton {
        let b = NSButton(title: title, target: modalPicker, action: #selector(ModalPicker.pick(_:)))
        b.tag = code.rawValue; b.keyEquivalent = key
        return b
    }
    let buttons = NSStackView(views: upToDate ? [NSView(), button("OK", .alertSecondButtonReturn, "\r")]
                                              : [button("Skip This Version", .alertThirdButtonReturn), NSView(),
                                                 button("Remind Me Later", .alertSecondButtonReturn, "\u{1b}"),
                                                 button("Install Update", .alertFirstButtonReturn, "\r")])

    let stack = NSStackView(views: [top, scroll, options, buttons])
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
    stack.setCustomSpacing(10, after: scroll)
    for v in [top, scroll, options, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    stack.widthAnchor.constraint(equalToConstant: 540).isActive = true
    let content = NSView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),  // the hidden title bar already leaves room above the icon,
        stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
        stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20)])
    content.layoutSubtreeIfNeeded()

    // Not resizable, so zoom shows greyed out like Sparkle's
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: content.fittingSize), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.title = "Software Update"
    w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
    w.hidesOnDeactivate = false
    w.contentView = content
    NSApp.activate()
    w.center(); w.makeKeyAndOrderFront(nil)
    // The close button counts as Remind Me Later; without this the modal session outlives its window
    let closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: nil) { _ in
        NSApp.stopModal(withCode: .alertSecondButtonReturn)
    }
    let choice = NSApp.runModal(for: w)
    NotificationCenter.default.removeObserver(closing)
    w.close()
    d.set(auto.state == .on, forKey: "autoInstall")
    switch choice {
    case .alertFirstButtonReturn:
        guard let dmg = release.dmg else { NSWorkspace.shared.open(release.page); return }
        install(dmg, version: release.version)
    case .alertThirdButtonReturn: d.set(release.version, forKey: "skippedVersion")
    default: break  // Remind Me Later: the next daily check asks again
    }
}

private final class ModalPicker: NSObject {
    var page: URL?
    @objc func pick(_ b: NSButton) { NSApp.stopModal(withCode: .init(b.tag)) }
    @objc func open(_ b: NSButton) { if let page { NSWorkspace.shared.open(page) } }
}
private let modalPicker = ModalPicker()

// GitHub's mark (Octicons, 16 pt), as a template image so it takes the link colour
private let githubMark: NSImage? = {
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 16 16"><path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg>"#
    let image = NSImage(data: Data(svg.utf8))
    image?.isTemplate = true
    return image
}()  // buttons hold their target weakly

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
