import AppKit
import ApplicationServices
import os.log

private let termLog = Logger(subsystem: "com.dadiani.halen", category: "terminal")

/// Shared AppleScript helpers for Terminal.app / iTerm2 interaction.
enum TerminalHelper {
    /// Escape a string for safe embedding in AppleScript double-quoted strings.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Send a keystroke message to the terminal tab running `processName`.
    /// Tries Terminal.app first, falls back to iTerm2.
    static func sendInput(_ message: String, processName: String) {
        guard AXIsProcessTrusted() else { return }
        let escaped = escape(message)

        let terminalScript = """
        tell application "Terminal"
            set targetTab to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    if busy of t then
                        if processes of t contains "\(processName)" then
                            set targetTab to t
                            set frontmost of w to true
                            exit repeat
                        end if
                    end if
                end repeat
                if targetTab is not missing value then exit repeat
            end repeat
            if targetTab is not missing value then
                tell application "System Events" to tell process "Terminal"
                    keystroke "\(escaped)"
                    keystroke return
                end tell
            end if
        end tell
        """

        var error: NSDictionary?
        NSAppleScript(source: terminalScript)?.executeAndReturnError(&error)
        if error == nil { return }

        let iTermScript = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if is processing of s then
                            tell s to write text "\(escaped)"
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        var iTermError: NSDictionary?
        NSAppleScript(source: iTermScript)?.executeAndReturnError(&iTermError)
        if iTermError == nil { return }

        // Try Warp — uses keystroke approach like Terminal.app
        let warpScript = """
        tell application "Warp"
            activate
            tell application "System Events" to tell process "Warp"
                keystroke "\(escaped)"
                keystroke return
            end tell
        end tell
        """
        var warpError: NSDictionary?
        NSAppleScript(source: warpScript)?.executeAndReturnError(&warpError)
        if warpError != nil {
            termLog.warning("Terminal.app, iTerm2, and Warp all failed for sendInput")
        }
    }

    /// Focus the terminal app running a claude process (without sending input).
    static func focusTerminal() {
        // Try Terminal.app
        let termScript = """
        tell application "Terminal"
            activate
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: termScript)?.executeAndReturnError(&error)
        if error == nil { return }

        // Try iTerm2
        let iTermScript = """
        tell application "iTerm2"
            activate
        end tell
        """
        var iTermError: NSDictionary?
        NSAppleScript(source: iTermScript)?.executeAndReturnError(&iTermError)
        if iTermError == nil { return }

        // Try Warp
        let warpScript = """
        tell application "Warp"
            activate
        end tell
        """
        var warpError: NSDictionary?
        NSAppleScript(source: warpScript)?.executeAndReturnError(&warpError)
        if warpError != nil {
            termLog.warning("Could not focus any terminal app")
        }
    }

    /// Open a new terminal tab and run a command.
    /// Tries Terminal.app first, falls back to iTerm2.
    static func runCommand(_ command: String) {
        let escaped = escape(command)
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error == nil { return }

        let iTermScript = """
        tell application "iTerm2"
            activate
            tell current window
                create tab with default profile
                tell current session
                    write text "\(escaped)"
                end tell
            end tell
        end tell
        """
        var iTermError2: NSDictionary?
        NSAppleScript(source: iTermScript)?.executeAndReturnError(&iTermError2)
        if iTermError2 == nil { return }

        // Try Warp
        let warpScript = """
        tell application "Warp"
            activate
            tell application "System Events" to tell process "Warp"
                keystroke "\(escaped)"
                keystroke return
            end tell
        end tell
        """
        var warpError: NSDictionary?
        NSAppleScript(source: warpScript)?.executeAndReturnError(&warpError)
        if warpError != nil {
            termLog.warning("Terminal.app, iTerm2, and Warp all failed for runCommand")
        }
    }
}
