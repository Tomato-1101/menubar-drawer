// 技術スパイク8（検証B）:
// Spotlight のステータスアイテムは AXPress を無視する（0 が返るのに何も開かない＝スパイク6で実測）。
// 唯一開くのがキーボードショートカットなので、その設定を
// com.apple.symbolichotkeys のキー 64（Spotlight 検索）から読み、
// CGEvent で合成して本当に開くかを確かめる。
//
// 実行: swift spike/spotlight_hotkey.swift

import AppKit

// MARK: - ショートカットの読み取り

/// symbolichotkeys の parameters は [ASCII, 仮想キーコード, 修飾キー(Cocoa の modifier mask)]。
/// 修飾キーのビットは NSEvent.ModifierFlags と CGEventFlags で同じ値なのでそのまま使える。
struct Hotkey {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

func readSpotlightHotkey() -> Hotkey? {
    guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
          let all = defaults.dictionary(forKey: "AppleSymbolicHotKeys"),
          let entry = all["64"] as? [String: Any]
    else {
        print("  symbolichotkeys が読めない")
        return nil
    }

    let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? NSNumber)?.boolValue ?? false)
    print("  key64 enabled=\(enabled)")
    guard enabled,
          let value = entry["value"] as? [String: Any],
          let params = value["parameters"] as? [NSNumber], params.count >= 3
    else { return nil }

    let mask: UInt64 = 0x00100000 | 0x00080000 | 0x00040000 | 0x00020000  // cmd/option/control/shift
    let hk = Hotkey(keyCode: CGKeyCode(params[1].intValue),
                    flags: CGEventFlags(rawValue: UInt64(params[2].uint32Value) & mask))
    print("  parameters=\(params.map(\.intValue)) → keyCode=\(hk.keyCode) flags=0x\(String(hk.flags.rawValue, radix: 16))")
    return hk
}

// MARK: - ウィンドウ観測

func cgWindows() -> [(number: Int, owner: String, bounds: CGRect, name: String)] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return list.compactMap { info in
        guard let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let num = info[kCGWindowNumber as String] as? Int else { return nil }
        return (num,
                info[kCGWindowOwnerName as String] as? String ?? "",
                CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0),
                info[kCGWindowName as String] as? String ?? "")
    }
}

func rectString(_ r: CGRect) -> String {
    "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height)))"
}

// MARK: - 実行

print("--- Spotlight ショートカットの読み取り ---")
guard let hk = readSpotlightHotkey() else {
    print("  → 無効 or 読めない（本実装ではメニューバー展開へフォールバック）")
    exit(1)
}

let before = Set(cgWindows().map(\.number))

let source = CGEventSource(stateID: .combinedSessionState)
let down = CGEvent(keyboardEventSource: source, virtualKey: hk.keyCode, keyDown: true)
down?.flags = hk.flags
down?.post(tap: .cghidEventTap)
let up = CGEvent(keyboardEventSource: source, virtualKey: hk.keyCode, keyDown: false)
up?.flags = hk.flags
up?.post(tap: .cghidEventTap)

Thread.sleep(forTimeInterval: 1.0)

let newWindows = cgWindows().filter { !before.contains($0.number) }
print("--- 送信後 ---")
print("  新規ウィンドウ \(newWindows.count)件")
for w in newWindows {
    print("    #\(w.number) [\(w.owner)] \(rectString(w.bounds)) '\(w.name)'")
}

let shotPath = "\(NSHomeDirectory())/Project/menubar-drawer/shots/spotlight-hotkey.png"
let shot = Process()
shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
shot.arguments = ["-x", "-t", "png", shotPath]
try? shot.run()
shot.waitUntilExit()
print("  screenshot: \(shotPath)")

// 後始末
CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.5)
print("  Esc 後に残っている新規ウィンドウ: \(cgWindows().filter { !before.contains($0.number) }.count)件")
print("終了")
