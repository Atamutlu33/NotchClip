// Presses ⌘⇧3 (the system "screenshot of the whole screen" shortcut). Used by CI.
import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)
let key: CGKeyCode = 20 // kVK_ANSI_3
let flags: CGEventFlags = [.maskCommand, .maskShift]
let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
down?.flags = flags
up?.flags = flags
down?.post(tap: .cghidEventTap)
usleep(50_000)
up?.post(tap: .cghidEventTap)
print("posted ⌘⇧3")
