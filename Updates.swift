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
    var page: URL?
    switch result {
    case .success(let r) where isNewer(r.version, than: current):
        alert.messageText = "OtterScan \(r.version) is available"
        alert.informativeText = "You have version \(current)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        page = r.page
    case .success:
        alert.messageText = "You're up to date"
        alert.informativeText = "OtterScan \(current) is the latest version."
    case .failure(let e):
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = e.localizedDescription
    }
    NSApp.activate()
    if alert.runModal() == .alertFirstButtonReturn, let page { NSWorkspace.shared.open(page) }
}
