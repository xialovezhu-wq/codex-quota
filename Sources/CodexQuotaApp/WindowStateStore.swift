import AppKit
import CoreGraphics
import Foundation

@MainActor
final class WindowStateStore {
    private let defaults: UserDefaults
    private let key = "window.frame.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restoreFrame(defaultSize: NSSize = NSSize(width: 228, height: 72)) -> NSRect {
        let screens = NSScreen.screens
        let fallbackScreen = NSScreen.main ?? screens.first
        guard let fallbackScreen else {
            return NSRect(origin: .zero, size: defaultSize)
        }

        guard
            let data = defaults.data(forKey: key),
            let stored = try? JSONDecoder().decode(StoredFrame.self, from: data)
        else {
            return defaultFrame(on: fallbackScreen, size: defaultSize)
        }

        let screen = screens.first { screenIdentifier($0) == stored.screenID } ?? fallbackScreen
        let visible = screen.visibleFrame
        let width = min(max(stored.width, 168), min(420, visible.width))
        let height = min(max(stored.height, 56), min(144, visible.height))
        let xTravel = max(0, visible.width - width)
        let yTravel = max(0, visible.height - height)
        let x = visible.minX + min(1, max(0, stored.normalizedX)) * xTravel
        let y = visible.minY + min(1, max(0, stored.normalizedY)) * yTravel
        return clamp(NSRect(x: x, y: y, width: width, height: height), to: visible)
    }

    func save(frame: NSRect, screen: NSScreen?) {
        guard let screen = screen ?? screenContaining(frame: frame) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let clamped = clamp(frame, to: visible)
        let xTravel = max(1, visible.width - clamped.width)
        let yTravel = max(1, visible.height - clamped.height)
        let stored = StoredFrame(
            screenID: screenIdentifier(screen),
            normalizedX: (clamped.minX - visible.minX) / xTravel,
            normalizedY: (clamped.minY - visible.minY) / yTravel,
            width: clamped.width,
            height: clamped.height
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: key)
        }
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }

    func clampToVisibleScreens(_ frame: NSRect) -> NSRect {
        if let screen = screenContaining(frame: frame) {
            return clamp(frame, to: screen.visibleFrame)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return frame }
        return defaultFrame(on: screen, size: frame.size)
    }

    func defaultFrame(on screen: NSScreen? = NSScreen.main, size: NSSize = NSSize(width: 228, height: 72)) -> NSRect {
        guard let screen = screen ?? NSScreen.screens.first else {
            return NSRect(origin: .zero, size: size)
        }
        let visible = screen.visibleFrame
        return clamp(
            NSRect(
                x: visible.maxX - size.width - 24,
                y: visible.maxY - size.height - 42,
                width: size.width,
                height: size.height
            ),
            to: visible
        )
    }

    private func screenContaining(frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { first, second in
                first.frame.intersection(frame).area < second.frame.intersection(frame).area
            }
    }

    private func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        let width = min(max(frame.width, 168), min(420, visible.width))
        let height = min(max(frame.height, 56), min(144, visible.height))
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func screenIdentifier(_ screen: NSScreen) -> String {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue()
        else {
            return screen.localizedName
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

private struct StoredFrame: Codable {
    let screenID: String
    let normalizedX: Double
    let normalizedY: Double
    let width: Double
    let height: Double
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
