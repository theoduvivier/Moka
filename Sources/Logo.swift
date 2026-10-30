import SwiftUI
import AppKit

/// A pixel-aligned silhouette for the menu bar. Eye apertures carry the state,
/// while the body stays solid and readable on either menu-bar appearance.
enum MenuBarIcon {
    static func drawRobot(in rect: CGRect, openness: Double, scale: Double = 1,
                          ink: NSColor = .black, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: rect.width / 20 * scale, y: -rect.height / 22 * scale)
        context.translateBy(x: -10, y: -11)
        context.setFillColor(ink.cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 2, y: 2, width: 16, height: 15), cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.addPath(CGPath(roundedRect: CGRect(x: 4, y: 18, width: 4, height: 2), cornerWidth: 0.65, cornerHeight: 0.65, transform: nil))
        context.addPath(CGPath(roundedRect: CGRect(x: 12, y: 18, width: 4, height: 2), cornerWidth: 0.65, cornerHeight: 0.65, transform: nil))
        context.fillPath()
        let p = min(1, max(0, openness))
        context.setBlendMode(.destinationOut)
        for x in [5.0, 12.0] {
            if p > 0 {
                context.setFillColor(NSColor.black.withAlphaComponent(p).cgColor)
                context.addPath(CGPath(roundedRect: CGRect(x: x, y: 7, width: 3, height: 4.8), cornerWidth: 1.35, cornerHeight: 1.35, transform: nil))
                context.fillPath()
            }
            if p < 1 {
                context.setStrokeColor(NSColor.black.withAlphaComponent(1 - p).cgColor)
                context.setLineWidth(1.2)
                context.setLineCap(.round)
                context.move(to: CGPoint(x: x - 0.15, y: 9))
                context.addCurve(to: CGPoint(x: x + 3.15, y: 9), control1: CGPoint(x: x + 0.5, y: 11.5), control2: CGPoint(x: x + 2.5, y: 11.5))
                context.strokePath()
            }
        }
    }
    static func image(fill: Double, scale: Double = 1) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 22), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            drawRobot(in: CGRect(x: 1, y: 0, width: 20, height: 22), openness: fill, scale: scale, context: context)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Advanced protection gets a short red baseline, not a halo over the glyph.
final class StatusLidIndicator: NSView {
    var iconScale: Double = 1 { didSet { if iconScale != oldValue { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var allowsVibrancy: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let width = 19 * iconScale
        let path = NSBezierPath(roundedRect: CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: 1.5), xRadius: 1, yRadius: 1)
        NSColor.systemRed.setFill()
        path.fill()
    }
}

/// Loaded once. No image decoding or background animation on timer updates.
enum RobotAssets {
    static let awake = load("Robot-awake")
    static let rest = load("Robot-rest")
    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct RobotAvatar: View {
    var awake: Bool
    var size: CGFloat = 92
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        RobotPose(wake: awake ? 1 : 0, size: size, reduceMotion: reduceMotion)
            // One reversible gesture. No scheduled steps, repeat loop or idle timer.
            .animation(reduceMotion ? .easeInOut(duration: 0.15)
                : .timingCurve(0.32, 0, 0.2, 1, duration: 0.72), value: awake)
            .accessibilityHidden(true)
    }
}

/// The entire pose shares one interpolated value, so rapid toggles reverse from
/// the current frame instead of leaving delayed bounces or eye changes queued.
struct RobotPose: View, Animatable {
    var wake: Double
    var size: CGFloat
    var reduceMotion: Bool
    var animatableData: Double {
        get { wake }
        set { wake = newValue }
    }
    var body: some View {
        let p = min(1, max(0, wake))
        let arc = reduceMotion ? 0 : sin(.pi * p)
        let eye = min(1, max(0, (p - 0.18) / 0.64))
        let open = eye * eye * (3 - 2 * eye)
        let settle = reduceMotion ? 0 : sin(2 * .pi * p)
        ZStack {
            if let rest = RobotAssets.rest, let active = RobotAssets.awake {
                Image(nsImage: rest).resizable().interpolation(.high).scaledToFit().opacity(1 - open)
                Image(nsImage: active).resizable().interpolation(.high).scaledToFit().opacity(open)
            } else {
                Image(nsImage: MenuBarIcon.image(fill: p)).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(x: 1 + 0.025 * settle, y: 1 - 0.025 * settle, anchor: .bottom)
        .rotation3DEffect(.degrees(-7 * arc), axis: (x: 0, y: 1, z: 0), perspective: 0.25)
        .rotationEffect(.degrees(reduceMotion ? 0 : -2 * (1 - p) + 3 * arc))
        .offset(y: reduceMotion ? 0 : size * (0.02 * (1 - p) - 0.065 * arc))
    }
}
