import Cocoa
import Carbon.HIToolbox

/// One parsed shortcut: the same binding expressed for Carbon (global hot key) and
/// for AppKit (the local monitor that catches keys the web view would swallow).
struct Shortcut {
    let keyCode: UInt32
    let carbonMods: UInt32
    let nsFlags: NSEvent.ModifierFlags
    let text: String
}

enum Keys {
    static let byName: [String: UInt32] = {
        var m: [String: UInt32] = [
            "f1": 122, "f2": 120, "f3": 99,  "f4": 118, "f5": 96,  "f6": 97,
            "f7": 98,  "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
            "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        ]
        let letters: [(String, UInt32)] = [
            ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3), ("g", 5),
            ("h", 4), ("i", 34), ("j", 38), ("k", 40), ("l", 37), ("m", 46), ("n", 45),
            ("o", 31), ("p", 35), ("q", 12), ("r", 15), ("s", 1), ("t", 17), ("u", 32),
            ("v", 9), ("w", 13), ("x", 7), ("y", 16), ("z", 6),
        ]
        for (k, v) in letters { m[k] = v }
        return m
    }()

    /// Parses "F9", "cmd+F8", "ctrl+alt+I" - case and spacing insensitive.
    static func parse(_ raw: String) -> Shortcut? {
        let parts = raw.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyPart = parts.last, let code = byName[keyPart] else { return nil }

        var carbon: UInt32 = 0
        var ns: NSEvent.ModifierFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command", "⌘":            carbon |= UInt32(cmdKey);     ns.insert(.command)
            case "ctrl", "control", "⌃":           carbon |= UInt32(controlKey); ns.insert(.control)
            case "alt", "opt", "option", "⌥":      carbon |= UInt32(optionKey);  ns.insert(.option)
            case "shift", "⇧":                     carbon |= UInt32(shiftKey);   ns.insert(.shift)
            default: return nil
            }
        }
        return Shortcut(keyCode: code, carbonMods: carbon, nsFlags: ns, text: raw)
    }

    /// True for a bare (unmodified) F-key, which needs the hidutil remap on a Mac
    /// where the function keys send media actions.
    static func isBareFKey(_ s: Shortcut) -> Bool {
        return s.carbonMods == 0 && s.keyCode >= 96 && s.keyCode <= 122
    }
}

/// Everything the user can change without rebuilding. Lives as JSON next to the app's
/// own data so it can be edited in any text editor; changes apply within ~2 seconds.
struct Config {
    var keys: [String: String]
    var width: CGFloat
    var height: CGFloat
    var zoom: CGFloat
    var startMuted: Bool

    static let actions = ["next", "like", "save", "showHide", "startStop", "savedMode"]

    static let defaults: [String: String] = [
        "next": "F9", "like": "F7", "save": "F8",
        "showHide": "ctrl+alt+I", "startStop": "cmd+F9", "savedMode": "cmd+F8",
    ]

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReelCorner")
    }
    static var url: URL { directory.appendingPathComponent("config.json") }

    static let template = """
    {
      "_comment": "Edit and save - ReelCorner picks up changes within 2 seconds, no restart.",
      "_keyFormat": "F1-F12, a letter, or a digit. Combine with cmd / ctrl / alt / shift, e.g. \\"cmd+F8\\".",
      "_note": "A BARE F-key needs the key remap that install.sh sets up. Re-run install.sh after changing one.",

      "keys": {
        "next":      "F9",
        "like":      "F7",
        "save":      "F8",
        "showHide":  "ctrl+alt+I",
        "startStop": "cmd+F9",
        "savedMode": "cmd+F8"
      },

      "panel": { "width": 380, "height": 660, "zoom": 0.75 },
      "startMuted": true
    }

    """

    /// Reads the config, writing the commented template first if it is missing.
    /// Any unreadable or partial file falls back to defaults rather than failing to start.
    static func load() -> Config {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Missing, empty or unparseable all get the commented template back. Silently
        // running on defaults forever would leave someone editing a file that is not
        // being read, with no clue why nothing changes.
        var needsTemplate = !fm.fileExists(atPath: url.path)
        if !needsTemplate {
            let data = (try? Data(contentsOf: url)) ?? Data()
            let ok = !data.isEmpty && (try? JSONSerialization.jsonObject(with: data)) != nil
            if !ok {
                needsTemplate = true
                if !data.isEmpty {
                    let backup = url.deletingLastPathComponent().appendingPathComponent("config.broken.json")
                    try? data.write(to: backup)
                    rcLog("config: could not read config.json - kept a copy as config.broken.json")
                }
            }
        }
        if needsTemplate {
            try? template.data(using: .utf8)?.write(to: url)
            rcLog("config: wrote a fresh config.json at \(url.path)")
        }

        var keys = defaults
        var w: CGFloat = 380, h: CGFloat = 660, z: CGFloat = 0.75, muted = true

        if let data = try? Data(contentsOf: url),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let k = root["keys"] as? [String: String] {
                for a in actions { if let v = k[a], !v.isEmpty { keys[a] = v } }
            }
            if let p = root["panel"] as? [String: Any] {
                if let v = p["width"] as? Double  { w = CGFloat(v) }
                if let v = p["height"] as? Double { h = CGFloat(v) }
                if let v = p["zoom"] as? Double   { z = CGFloat(v) }
            }
            if let m = root["startMuted"] as? Bool { muted = m }
        } else {
            rcLog("config: could not parse \(url.path) - using defaults")
        }

        return Config(keys: keys, width: w, height: h, zoom: z, startMuted: muted)
    }

    static func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
