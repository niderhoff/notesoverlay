import AppKit

// Menu-bar-only agent: no Dock icon, no app switcher entry. Info.plist also sets
// LSUIElement, but setting the policy here makes a bare `swift run` behave the same.
// A swallowed exception leaves a frozen window and a dead hotkey; a crash report is
// far more useful for a personal tool.
UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
