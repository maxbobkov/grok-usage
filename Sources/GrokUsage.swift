import AppKit
import Foundation

@main
enum GrokUsageApp {
    static func main() {
        if CommandLine.arguments.contains("--once") {
            runOnce()
            return
        }
        let app = NSApplication.shared
        let runtime = Runtime.shared
        app.delegate = runtime.delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func runOnce() {
        do {
            let token = try AuthStore.validAccessToken()
            let snapshot = try BillingClient.fetch(accessToken: token)
            let end: String
            if let periodEnd = snapshot.periodEnd {
                end = ISO8601DateFormatter().string(from: periodEnd)
            } else {
                end = ""
            }
            FileHandle.standardOutput.write(Data("\(snapshot.percent)% resets=\(end)\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private final class Runtime {
    static let shared = Runtime()
    let delegate = AppDelegate()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private let work = DispatchQueue(label: "com.local.grokusage.work")
    private var inFlight = false

    private var lastSnapshot: UsageSnapshot?
    private var lastError: String?

    private var summaryItem: NSMenuItem!
    private var resetsItem: NSMenuItem!
    private var updatedItem: NSMenuItem!
    private var errorItem: NSMenuItem!
    private var refreshItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        let t = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.refresh(forceTokenRefresh: false)
        }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh(forceTokenRefresh: false)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.font = Self.statusFont
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        summaryItem = NSMenuItem(title: "Grok Build  …", action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)

        resetsItem = NSMenuItem(title: "Resets  —", action: nil, keyEquivalent: "")
        resetsItem.isEnabled = false
        menu.addItem(resetsItem)

        updatedItem = NSMenuItem(title: "Updated  —", action: nil, keyEquivalent: "")
        updatedItem.isEnabled = false
        menu.addItem(updatedItem)

        errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.addItem(errorItem)

        menu.addItem(.separator())

        refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(onRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "Open Usage", action: #selector(onOpenUsage), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        applyTitle(percent: nil, stale: false)
    }

    @objc private func onRefresh() {
        refresh(forceTokenRefresh: false)
    }

    @objc private func onWake() {
        refresh(forceTokenRefresh: false)
    }

    @objc private func onOpenUsage() {
        if let url = URL(string: "https://grok.com/?_s=usage") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refresh(forceTokenRefresh: Bool) {
        work.async { [weak self] in
            guard let self else { return }
            if self.inFlight { return }
            self.inFlight = true
            DispatchQueue.main.async { self.refreshItem.isEnabled = false }

            do {
                let token = try self.token(force: forceTokenRefresh)
                let snapshot = try BillingClient.fetch(accessToken: token)
                NSLog("GrokUsage fetched %d%%", snapshot.percent)
                DispatchQueue.main.async {
                    self.lastSnapshot = snapshot
                    self.lastError = nil
                    self.render()
                }
            } catch BillingError.unauthorized where !forceTokenRefresh {
                self.inFlight = false
                self.refresh(forceTokenRefresh: true)
                return
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.render()
                }
            }

            DispatchQueue.main.async { self.refreshItem.isEnabled = true }
            self.inFlight = false
        }
    }

    private func token(force: Bool) throws -> String {
        if force {
            return try AuthStore.forceRefresh()
        }
        return try AuthStore.validAccessToken()
    }

    private func render() {
        let snapshot = lastSnapshot
        let err = lastError
        applyTitle(percent: snapshot?.percent, stale: snapshot != nil && err != nil)

        if let snapshot {
            summaryItem.title = "Grok Build  \(snapshot.percent)%"
            if let end = snapshot.periodEnd {
                resetsItem.title = "Resets  \(Self.resetsFormatter.string(from: end))"
            } else {
                resetsItem.title = "Resets  —"
            }
            updatedItem.title = "Updated  \(Self.updatedFormatter.string(from: snapshot.fetchedAt))"
        } else {
            summaryItem.title = "Grok Build  ?"
            resetsItem.title = "Resets  —"
            updatedItem.title = "Updated  —"
        }

        if let err, !err.isEmpty {
            errorItem.title = err
            errorItem.isHidden = false
        } else {
            errorItem.title = ""
            errorItem.isHidden = true
        }

        var tooltip = "Grok Build weekly usage"
        if let snapshot {
            tooltip += " — \(snapshot.percent)%"
        }
        if let err {
            tooltip += "\n\(err)"
        }
        statusItem?.button?.toolTip = tooltip
    }

    private func applyTitle(percent: Int?, stale: Bool) {
        guard let button = statusItem?.button else { return }
        let text: String
        let color: NSColor
        if let percent {
            text = "\(percent)%"
            if percent >= 90 {
                color = .systemRed
            } else if percent >= 70 {
                color = .systemOrange
            } else {
                color = .labelColor
            }
        } else {
            text = "?"
            color = .secondaryLabelColor
        }

        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = Self.makeStatusImage(text: text, color: color, stale: stale)
        button.imageScaling = .scaleNone
        button.imagePosition = .imageOnly
    }

    private static func makeStatusImage(text: String, color: NSColor, stale: Bool) -> NSImage {
        let font = statusFont
        let iconSize: CGFloat = 12
        let gap: CGFloat = 4
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if stale {
            attrs[.obliqueness] = 0.15
        }

        let textSize = (text as NSString).size(withAttributes: attrs)
        let lineHeight = ceil(font.ascender - font.descender)
        let height = max(16, iconSize, lineHeight, ceil(textSize.height))
        let width = iconSize + gap + ceil(textSize.width)
        let size = NSSize(width: width, height: height)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        let mid = height / 2
        let iconRect = NSRect(
            x: 0,
            y: mid - iconSize / 2 + 0.5,
            width: iconSize,
            height: iconSize
        )
        grokMark(size: iconSize, color: color).draw(in: iconRect)

        // Baseline so the cap-height box shares the same vertical center as the mark.
        let baseline = mid - font.capHeight / 2
        let textOrigin = NSPoint(x: iconSize + gap, y: baseline + font.descender)
        (text as NSString).draw(at: textOrigin, withAttributes: attrs)

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    private static func grokMark(size: CGFloat, color: NSColor) -> NSImage {
        let base = grokMarkTemplate
        let scaled = NSSize(width: size, height: size)
        let out = NSImage(size: scaled)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        base.draw(in: NSRect(origin: .zero, size: scaled), from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: scaled).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    private static let grokMarkTemplate: NSImage = {
        let candidates = [
            Bundle.main.url(forResource: "GrokMark", withExtension: "svg"),
            URL(fileURLWithPath: "Resources/GrokMark.svg"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 24, height: 24)
                image.isTemplate = true
                return image
            }
        }
        return NSImage(size: NSSize(width: 24, height: 24))
    }()

    private static let resetsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    private static let updatedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
