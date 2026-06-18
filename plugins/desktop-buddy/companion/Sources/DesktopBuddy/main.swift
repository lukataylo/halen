import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory keeps us out of the Dock + Cmd-Tab switcher while still allowing
// us to draw windows and receive mouse / keyboard events on key windows.
app.setActivationPolicy(.accessory)
app.run()
