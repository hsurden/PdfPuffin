import AppKit

// Surface Objective-C exceptions as crashes instead of silently half-launching.
UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
