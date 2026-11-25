import AppKit
setvbuf(stdout, nil, _IONBF, 0)
// Run with scripts/test-updates.sh: version checks, unpacking and installing an update.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { exit(1) } }
let fm = FileManager.default

// Version comparison.
check(try! AppUpdate.isNewer("0.2", than: "0.1"), "0.2 is newer than 0.1")
check(try! AppUpdate.isNewer("0.10", than: "0.9"), "0.10 is newer than 0.9 (numbers, not text)")
check(!(try! AppUpdate.isNewer("0.2.0", than: "0.2")), "0.2.0 equals 0.2")
check(!(try! AppUpdate.isNewer("0.1", than: "0.2")), "older release is not offered")

// The GitHub answer.
func release(_ tag: String, assets: [String], body: String = "Bug fixes.") -> Data {
    try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "body": body, "assets": assets.map { ["name": $0] }])
}
let found = try! AppUpdate.available(after: "0.1", status: 200, data: release("v0.3", assets: ["PdfPuffin-for-Mac.zip"]))
check(found?.version == "0.3" && found?.notes == "Bug fixes."
      && found?.download.absoluteString == "https://github.com/hsurden/PdfPuffin/releases/download/v0.3/PdfPuffin-for-Mac.zip",
      "newer release found with its download and notes")
check({ if case .some(.none) = try? AppUpdate.available(after: "0.3", status: 200, data: release("v0.3", assets: ["PdfPuffin-for-Mac.zip"])) { return true }; return false }(),
      "same version: no update")
check({ if case .some(.none) = try? AppUpdate.available(after: "0.1", status: 404, data: Data()) { return true }; return false }(),
      "no releases yet: no update, no error")
check({ do { _ = try AppUpdate.available(after: "0.1", status: 200, data: release("v0.3", assets: [])); return false } catch { return true } }(),
      "release without the ZIP is an error")

// A fake PdfPuffin.app of a given version, zipped as a release would be.
func makeApp(_ dir: URL, version: String, id: String = "com.hs.PdfPuffin") -> URL {
    let app = dir.appendingPathComponent("PdfPuffin.app")
    try? fm.removeItem(at: app)
    try! fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version,
                                "CFBundleExecutable": "PdfPuffin", "CFBundlePackageType": "APPL"]
    (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    try! fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/PdfPuffin").path)
    AppUpdate.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    return app
}
func zipped(_ version: String, id: String = "com.hs.PdfPuffin", corrupt: Bool = false) -> URL {
    let src = root.appendingPathComponent("build-\(version)-\(id)")
    try! fm.createDirectory(at: src, withIntermediateDirectories: true)
    let app = makeApp(src, version: version, id: id)
    if corrupt { try! "tampered".write(to: app.appendingPathComponent("Contents/MacOS/PdfPuffin"), atomically: true, encoding: .utf8) }
    let zip = src.appendingPathComponent("PdfPuffin-for-Mac.zip")
    AppUpdate.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
    return zip
}
func stage(_ zip: URL, _ version: String) throws -> URL {
    let dir = root.appendingPathComponent("stage-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return try AppUpdate.unpack(zip: zip, into: dir, expecting: version, bundleID: "com.hs.PdfPuffin")
}
let good = try? stage(zipped("0.3"), "0.3")
check(good != nil, "a genuine update unpacks and passes its checks")
check((try? stage(zipped("0.3", id: "com.example.Other"), "0.3")) == nil, "another app's ZIP is refused")
check((try? stage(zipped("0.2"), "0.3")) == nil, "a ZIP of the wrong version is refused")
check((try? stage(zipped("0.4", corrupt: true), "0.4")) == nil, "a tampered app is refused")

// Where it can install.
check(AppUpdate.cannotInstallReason(at: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/PdfPuffin.app")) != nil,
      "won't install over a translocated copy")
let installedDir = root.appendingPathComponent("Applications")
try! fm.createDirectory(at: installedDir, withIntermediateDirectories: true)
let installed = makeApp(installedDir, version: "0.1")
check(AppUpdate.cannotInstallReason(at: installed) == nil, "can install into a writable folder")

// The installer waits for the app to quit, then swaps in the new copy.
let sleeper = Process()
sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
sleeper.arguments = ["1"]
try! sleeper.run()
AppUpdate.spawnInstaller(newApp: good!, replacing: installed, relaunch: false, waitingFor: sleeper.processIdentifier)
Thread.sleep(forTimeInterval: 0.4)
check(Bundle(url: installed)?.infoDictionary?["CFBundleShortVersionString"] as? String == "0.1", "nothing changes while the app is still running")
sleeper.waitUntilExit()
var version = ""
for _ in 0..<30 {
    Thread.sleep(forTimeInterval: 0.2)
    version = (NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? ""
    if version == "0.3" { break }
}
check(version == "0.3", "after quitting, the new version replaces the old one in place")
check(AppUpdate.run("/usr/bin/codesign", ["--verify", "--deep", installed.path]) == 0, "installed copy's signature is intact")
check(!fm.fileExists(atPath: installed.path + ".updating"), "no leftover temporary copy")
print("All passed")
