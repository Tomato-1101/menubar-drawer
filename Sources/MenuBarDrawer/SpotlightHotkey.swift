import AppKit

/// Spotlight を開くためのキーボードショートカット。
///
/// Spotlight のステータスアイテムは AXPress に success を返すのに何も開かない（実測）。
/// 画面内にいても開かないので、位置の問題ではなくアイテムが押下を無視している。
/// 開く手段はキーボードショートカットだけなので、利用者の設定を読んでそれを合成する。
struct SpotlightHotkey {

    let keyCode: CGKeyCode
    let flags: CGEventFlags

    /// システム設定のショートカット（com.apple.symbolichotkeys のキー 64＝Spotlight 検索）を読む。
    /// 利用者が無効化していたら nil（呼び出し側は従来どおりメニューバーへ展開する）
    static func current() -> SpotlightHotkey? {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let hotkeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = hotkeys["64"] as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true,
              let value = entry["value"] as? [String: Any],
              // parameters は [ASCII, 仮想キーコード, 修飾キー]。ASCII は 65535（＝無し）のことがある
              let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3
        else { return nil }

        // 修飾キーのビット位置は NSEvent.ModifierFlags と CGEventFlags で同じ。
        // 余計なビット（デバイス依存フラグ等）を持ち込まないよう4つだけ通す
        let usable: UInt64 = 0x0010_0000 | 0x0008_0000 | 0x0004_0000 | 0x0002_0000  // cmd/option/control/shift
        return SpotlightHotkey(
            keyCode: CGKeyCode(parameters[1].intValue),
            flags: CGEventFlags(rawValue: UInt64(parameters[2].uint32Value) & usable)
        )
    }

    /// キーを合成して送る。カーソルは動かさない
    func post() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
