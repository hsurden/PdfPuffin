import AppKit
import UniformTypeIdentifiers

// PdfPuffin ▸ Make PdfPuffin the Default PDF App: PDFs opened from Finder, Mail and
// browsers then open here. macOS asks the user to confirm the change.

enum DefaultPDFApp {
    /// The app that opens PDFs now.
    static var current: URL? { NSWorkspace.shared.urlForApplication(toOpen: .pdf) }

    static var isPdfPuffin: Bool {
        guard let current else { return false }
        if current.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { return true }
        return Bundle(url: current)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static var currentName: String {
        current.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "another app"
    }
}

extension AppDelegate: NSMenuItemValidation {
    @objc func makeDefaultPDFApp(_ sender: Any?) {
        let previous = DefaultPDFApp.currentName
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .pdf) { error in
            DispatchQueue.main.async {
                let a = NSAlert()
                if let error {
                    // Declining macOS's own confirmation also lands here.
                    a.messageText = "PDFs still open with \(DefaultPDFApp.currentName)"
                    a.informativeText = error.localizedDescription
                } else {
                    a.messageText = "PdfPuffin now opens your PDFs"
                    a.informativeText = "PDFs you open from Finder, Mail or a browser open in PdfPuffin instead of \(previous). "
                        + "To change it back, select a PDF in Finder, choose File ▸ Get Info, pick an app under “Open with”, and click Change All."
                }
                a.runModal()
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(makeDefaultPDFApp(_:)) {
            let isDefault = DefaultPDFApp.isPdfPuffin
            item.title = isDefault ? "PdfPuffin Is the Default PDF App" : "Make PdfPuffin the Default PDF App"
            item.state = isDefault ? .on : .off
            return !isDefault
        }
        return true
    }
}
