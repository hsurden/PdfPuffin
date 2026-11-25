import AppKit
import Foundation

/// Updates from the public GitHub repo's Releases. A release tagged `v0.3` with the
/// asset `PdfPuffin-for-Mac.zip` is an update for any older installed version.
///
/// The app downloads the ZIP itself, rather than sending you to the browser: files an
/// app fetches for itself are not marked as "downloaded from the internet", so after the
/// first install macOS does not stop each update with an unverified-developer warning.
/// The new copy replaces this one when PdfPuffin quits (unsaved documents still ask
/// first), then it reopens.
struct AppUpdate {
    let version: String
    let download: URL
    let notes: String

    static let repo = "hsurden/PdfPuffin"
    static let assetName = "PdfPuffin-for-Mac.zip"

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String }
        let tag_name: String
        let assets: [Asset]
        let body: String?
    }

    static func latest(after installed: String) async throws -> AppUpdate? {
        let endpoint = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("PdfPuffin-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return try available(after: installed, status: http.statusCode, data: data)
    }

    /// Version numbers as integers, trailing zeros dropped ("0.2.0" == "0.2").
    static func parts(_ string: String) throws -> [Int] {
        var numbers: [Int] = []
        for field in string.components(separatedBy: ".") {
            guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(field) else { throw URLError(.cannotParseResponse) }
            numbers.append(number)
        }
        while numbers.last == 0 { numbers.removeLast() }
        return numbers
    }

    static func isNewer(_ candidate: String, than installed: String) throws -> Bool {
        try parts(installed).lexicographicallyPrecedes(parts(candidate))
    }

    static func available(after installed: String, status: Int, data: Data) throws -> AppUpdate? {
        if status == 404 { return nil } // GitHub has no published stable release.
        guard status == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let tag = release.tag_name
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard try isNewer(version, than: installed) else { return nil }
        guard release.assets.contains(where: { $0.name == assetName }) else {
            throw NSError(domain: "PdfPuffin.Update", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Version \(version) is published, but its Mac ZIP is not available yet. Try again later."
            ])
        }
        let url = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(assetName)")!
        return AppUpdate(version: version, download: url,
                         notes: (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: download and check

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Where downloads are unpacked before installing.
    static var stagingRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PdfPuffin Updates")
    }

    /// Downloads and unpacks the update; returns the checked new PdfPuffin.app.
    func downloadAndStage() async throws -> URL {
        var request = URLRequest(url: download, timeoutInterval: 120)
        request.setValue("PdfPuffin-Update-Check", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("The download failed. Try again later.") }
        let fm = FileManager.default
        let dir = Self.stagingRoot.appendingPathComponent(version)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent(Self.assetName)
        try fm.moveItem(at: file, to: zip)
        return try Self.unpack(zip: zip, into: dir, expecting: version,
                               bundleID: Bundle.main.bundleIdentifier ?? "com.hs.PdfPuffin")
    }

    /// Unzips `zip` and checks the app inside: PdfPuffin's bundle ID, the expected
    /// version, and an intact code signature.
    static func unpack(zip: URL, into dir: URL, expecting version: String, bundleID: String) throws -> URL {
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) == 0 else { throw Failure("The update could not be unpacked.") }
        let apps = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first, let info = Bundle(url: app)?.infoDictionary else {
            throw Failure("The update did not contain the app.")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw Failure("The download is not PdfPuffin.") }
        guard let v = info["CFBundleShortVersionString"] as? String, (try? parts(v)) == (try? parts(version)) else {
            throw Failure("The download is not version \(version).")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", app.path]) == 0 else {
            throw Failure("The update's signature is damaged, so it was not installed.")
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: install

    /// Why this copy can't replace itself, or nil if it can.
    static func cannotInstallReason(at target: URL = Bundle.main.bundleURL) -> String? {
        if target.path.contains("/AppTranslocation/") {
            return "PdfPuffin is running from a temporary location. Move it into Applications, open it from there, then check again."
        }
        if !FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) {
            return "PdfPuffin can't write to \(target.deletingLastPathComponent().path)."
        }
        return nil
    }

    /// Started as PdfPuffin quits: waits for this process to end, swaps in the new
    /// app (keeping the old one if the copy fails), and optionally reopens it.
    static func spawnInstaller(newApp: URL, replacing target: URL, relaunch: Bool,
                               waitingFor pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        tmp="$3.updating"
        /bin/rm -rf "$tmp"
        if /usr/bin/ditto "$2" "$tmp"; then
            /bin/rm -rf "$3" && /bin/mv "$tmp" "$3"
            /usr/bin/xattr -dr com.apple.quarantine "$3" 2>/dev/null
            /bin/rm -rf "$5"
        fi
        if [ "$4" = 1 ]; then /usr/bin/open "$3"; fi
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "pdfpuffin-update", String(pid),
                       newApp.path, target.path, relaunch ? "1" : "0", newApp.deletingLastPathComponent().path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

// MARK: - menu and launch check

final class UpdateController {
    static let shared = UpdateController()
    private var checking = false
    /// A downloaded, checked update waiting for PdfPuffin to quit.
    private(set) var staged: (version: String, app: URL)?
    private var relaunchAfterInstall = false

    static var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkForUpdates") }
    }
    private static let lastCheckKey = "lastUpdateCheck"
    private var installed: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// At launch: at most once a day, quietly; speaks up only when there is an update.
    func checkAtLaunch() {
        guard Self.checksAutomatically else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.check(quietly: true) }
    }

    func check(quietly: Bool) {
        guard !checking else { return }
        if let staged {
            if !quietly { offerRestart(version: staged.version) }
            return
        }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            do {
                let update = try await AppUpdate.latest(after: installed)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                if let update { offer(update) }
                else if !quietly { info("You have the latest version", "PdfPuffin \(installed) is the newest release.") }
            } catch {
                if !quietly { info("Couldn’t check for updates", error.localizedDescription) }
            }
        }
    }

    private func offer(_ update: AppUpdate) {
        let a = NSAlert()
        a.messageText = "PdfPuffin \(update.version) is available"
        var text = "You have version \(installed)."
        if !update.notes.isEmpty { text += "\n\n" + update.notes }
        a.informativeText = text
        let reason = AppUpdate.cannotInstallReason()
        a.addButton(withTitle: reason == nil ? "Install Update" : "Download")
        a.addButton(withTitle: "Later")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let reason {
            info("PdfPuffin can't update itself here", reason + " The download will open in your browser instead.")
            NSWorkspace.shared.open(update.download)
            return
        }
        Task { @MainActor in
            do {
                let app = try await update.downloadAndStage()
                staged = (update.version, app)
                offerRestart(version: update.version)
            } catch {
                info("The update wasn't installed", error.localizedDescription)
            }
        }
    }

    private func offerRestart(version: String) {
        let a = NSAlert()
        a.messageText = "PdfPuffin \(version) is ready"
        a.informativeText = "Restart to finish updating. If you have unsaved changes, PdfPuffin asks about them first. Choose “When I Quit” to update the next time you quit."
        a.addButton(withTitle: "Restart Now")
        a.addButton(withTitle: "When I Quit")
        relaunchAfterInstall = a.runModal() == .alertFirstButtonReturn
        if relaunchAfterInstall { NSApp.terminate(nil) }
    }

    /// Called from applicationWillTerminate: hands the staged update to the installer.
    func installIfStaged() {
        guard let staged, AppUpdate.cannotInstallReason() == nil else { return }
        AppUpdate.spawnInstaller(newApp: staged.app, replacing: Bundle.main.bundleURL, relaunch: relaunchAfterInstall)
    }

    private func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
