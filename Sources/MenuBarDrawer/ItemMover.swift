import AppKit

/// ステータスアイテムをメニューバー上で移動させる。
///
/// macOS は他アプリのステータスアイテムの並び順を変える API を公開しておらず、
/// 並べ替えは「⌘を押しながらドラッグ」でしか受け付けない。そこでユーザーの手の動きを
/// そのまま合成する（Ice / Bartender も同じ手を使っている）。
enum ItemMover {

    /// 指定アイテムを targetX まで ⌘ドラッグする。
    /// アイテムが画面内にいる必要があるので、呼ぶ側は先に押し出しを畳んでおくこと。
    static func move(_ item: MenuBarItem, toX targetX: CGFloat, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 押し出しを畳んだ直後はメニューバーが再レイアウト中で、AX は移動途中の座標を返す。
            // 掴む位置を間違えると別のアイテムを動かしてしまうので、座標が止まるまで待つ
            var frame = StatusItemScanner.liveFrame(of: item)
            var lastX = CGFloat.infinity
            var waited = 0
            while (frame.origin.x < 0 || frame.origin.x != lastX), waited < 40 {
                lastX = frame.origin.x
                usleep(30_000)
                frame = StatusItemScanner.liveFrame(of: item)
                waited += 1
            }

            guard frame.width > 0, frame.origin.x >= 0 else {
                log.notice("move \(item.displayName, privacy: .public) 中止: 画面内に戻らなかった")
                DispatchQueue.main.async { completion(false) }
                return
            }
            log.notice("move \(item.displayName, privacy: .public) from=\(frame.midX) to=\(targetX) waited=\(waited)")

            let source = CGEventSource(stateID: .combinedSessionState)
            let from = CGPoint(x: frame.midX, y: frame.midY)
            let to = CGPoint(x: targetX, y: frame.midY)

            // ⌘ は flags だけでなく実キーとしても押す。メニューバーの並べ替えは
            // 修飾キーの実状態を見ているため、flags の偽装だけでは掴めないことがある
            postKey(source, down: true)
            postMouse(source, .leftMouseDown, from)

            let steps = 14
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                postMouse(source, .leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y))
                usleep(15_000)
            }

            postMouse(source, .leftMouseUp, to)
            postKey(source, down: false)
            usleep(150_000)

            let moved = StatusItemScanner.liveFrame(of: item)
            log.notice("move \(item.displayName, privacy: .public) 結果 newX=\(moved.midX)")
            DispatchQueue.main.async { completion(abs(moved.midX - targetX) < 120) }
        }
    }

    private static func postMouse(_ source: CGEventSource?, _ type: CGEventType, _ point: CGPoint) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = .maskCommand
        event?.post(tap: .cghidEventTap)
    }

    private static func postKey(_ source: CGEventSource?, down: Bool) {
        // 0x37 = ⌘（左）
        let event = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: down)
        event?.flags = down ? .maskCommand : []
        event?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}
