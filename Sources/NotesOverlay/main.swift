import AppKit

// Menu-bar-only agent: no Dock icon, no app switcher entry. Info.plist also sets
// LSUIElement, but setting the policy here makes a bare `swift run` behave the same.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
