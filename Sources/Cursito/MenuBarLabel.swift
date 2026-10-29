import AppKit
import SwiftUI

/// The menu bar item: the sync icon (an arrow while exporting or importing), optionally
/// this cycle's spend, and a gauge with the percentage once on-demand spend nears the limit.
struct MenuBarLabel: View {
    static let showsSpendKey = "menuBarShowsSpend"

    let sync: SyncModel
    let usage: UsageModel
    @AppStorage(Self.showsSpendKey) private var showsSpend = false

    var body: some View {
        Image(nsImage: Self.render(symbol: symbol, text: text))
            .accessibilityLabel(["Cursito", text].compactMap(\.self).joined(separator: ", "))
    }

    private var symbol: String {
        guard sync.iconActivity == .idle, let fraction = usage.limitWarning else { return sync.menuBarSymbol }
        return fraction >= 1 ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.67percent"
    }

    private var text: String? {
        let spend = showsSpend ? usage.me?.totalCents.wholeDollarsText : nil
        let percent = usage.limitWarning?.formatted(.percent.precision(.fractionLength(0)).locale(.ui))
        let parts = [spend, percent].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Drawn into one template image so the menu bar tints icon and text together.
    static func render(symbol: String, text: String?) -> NSImage {
        let content = HStack(spacing: 4) {
            Image(systemName: symbol)
            if let text {
                Text(text).monospacedDigit()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.black)
        .fixedSize()

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}
