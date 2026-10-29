import AppKit

/// The standard macOS About panel. A menu bar app has no app menu to open it from.
@MainActor
enum AboutPanel {
    static let repositoryURL = URL(string: "https://github.com/OrbeApp/cursito")!

    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Cursito",
            .applicationIcon: icon,
            .credits: credits,
        ])
    }

    private static var icon: NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
            .applying(.init(paletteColors: [.white, .controlAccentColor]))
        return NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle.fill", accessibilityDescription: "Cursito")?
            .withSymbolConfiguration(configuration) ?? NSApp.applicationIconImage
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let note = body.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }

        let text = NSMutableAttributedString(
            string: "Syncs your Cursor setup between Macs, shows your Cursor usage and keeps your git repos up to date.\n\n",
            attributes: body
        )
        text.append(NSAttributedString(
            string: "github.com/OrbeApp/cursito",
            attributes: body.merging([.link: repositoryURL]) { $1 }
        ))
        text.append(NSAttributedString(string: "\n\nNot affiliated with Anysphere or Cursor.", attributes: note))
        return text
    }
}
