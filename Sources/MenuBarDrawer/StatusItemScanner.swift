import AppKit
import ApplicationServices

/// 他アプリがメニューバー右側に出しているステータスアイテム1個ぶん。
struct MenuBarItem: Identifiable, Equatable {
    let id: String
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let bundleID: String
    let icon: NSImage?
    let title: String
    let help: String
    let frame: CGRect

    /// ステータスアイテム固有の名前があればそれを、無ければアプリ名を出す
    var displayName: String {
        if !title.isEmpty { return title }
        return appName
    }

    /// Hidden Bar 等に画面外へ押し出されている（＝いまメニューバーから触れない）
    var isOffscreen: Bool { frame.origin.x < 0 }

    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool { lhs.id == rhs.id }
}

enum StatusItemScanner {

    /// いま存在するステータスアイテムを、メニューバー上の並び順で返す。
    ///
    /// アプリの素性では絞らない。「メニューバーに出ているか / 押し出されて隠れているか」だけで
    /// 引き出しに載せるかを決めるため（同じものがメニューバーと引き出しの両方に出る二重表示を防ぐ）。
    /// コントロールセンターは未使用モジュールぶんの 0x0 の空アイテムを大量に持つのでサイズで弾く。
    static func scan() -> [MenuBarItem] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var results: [MenuBarItem] = []

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid != selfPID else { continue }
            let bundleID = app.bundleIdentifier ?? ""

            let axApp = AXUIElementCreateApplication(pid)
            guard let extras = copyAttribute(axApp, "AXExtrasMenuBar"),
                  CFGetTypeID(extras) == AXUIElementGetTypeID(),
                  let children = copyAttribute(extras as! AXUIElement, kAXChildrenAttribute as String) as? [AXUIElement]
            else { continue }

            for (index, element) in children.enumerated() {
                let frame = frameOf(element)
                guard frame.width > 0, frame.height > 0 else { continue }

                results.append(
                    MenuBarItem(
                        id: "\(pid)-\(index)",
                        element: element,
                        pid: pid,
                        appName: app.localizedName ?? bundleID,
                        bundleID: bundleID,
                        icon: app.icon,
                        title: (copyAttribute(element, kAXTitleAttribute as String) as? String) ?? "",
                        help: (copyAttribute(element, kAXHelpAttribute as String) as? String) ?? "",
                        frame: frame
                    )
                )
            }
        }

        // メニューバー上の左右の並びを保つ（画面外に押し出されたぶんは負の x なので自然に先頭に来る）
        return results.sorted { $0.frame.origin.x < $1.frame.origin.x }
    }

    /// アイテムのいまの位置を取り直す（押し出しを緩めた直後は座標が動いているため）
    static func liveFrame(of item: MenuBarItem) -> CGRect {
        frameOf(item.element)
    }

    /// ステータスアイテムを押してメニューを開く。
    ///
    /// AX の `AXPress` は使わない。このアプリから呼ぶと常に -25204 (cannotComplete) を返し、
    /// しかも判明するまで約 1.5 秒ブロックする（メイン/別スレッドどちらでも同じ）。
    /// ユーザーが手で押すのと同じ実クリックを合成すれば即座に確実に開く。
    /// アイテムが画面内にいる必要があるので、呼ぶ側は先に押し出しを畳んでおくこと。
    @discardableResult
    static func click(_ item: MenuBarItem) -> Bool {
        let frame = frameOf(item.element)
        guard frame.width > 0, frame.origin.x >= 0 else { return false }

        // クリックの合成はカーソルごと動かしてしまう。ユーザーから見ると
        // 「勝手にマウスがメニューバーへ飛ぶ」ので、元の位置を覚えて即座に戻す
        let cursorBefore = CGEvent(source: nil)?.location

        let point = CGPoint(x: frame.midX, y: frame.midY)
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)

        if let cursorBefore {
            CGWarpMouseCursorPosition(cursorBefore)
            // warp 後もイベント座標は飛んだ先のままになることがあるので、関連付けを張り直す
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        return true
    }

    // MARK: - AX ヘルパ

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        if let value = copyAttribute(element, kAXPositionAttribute as String) {
            AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        }
        var size = CGSize.zero
        if let value = copyAttribute(element, kAXSizeAttribute as String) {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }
}
