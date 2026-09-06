#!/usr/bin/env swift

import AppKit

private enum BrandLayout {
    static let canvasSize = NSSize(width: 317, height: 268)
    static let tileFrame = NSRect(x: 92.5, y: 0, width: 132, height: 132)
    static let symbolBounds = NSRect(x: 121.5, y: 29, width: 74, height: 74)
}

private func makeRunnerImage() -> NSImage {
    let scale = 4
    let size = BrandLayout.symbolBounds.size
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("The runner bitmap could not be created")
    }
    bitmap.size = size

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap),
          let symbol = NSImage(systemSymbolName: "figure.run", accessibilityDescription: nil) else {
        fatalError("The figure.run SF Symbol could not be rendered")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(NSRect(origin: .zero, size: size))
    symbol.draw(in: NSRect(origin: .zero, size: size))
    context.cgContext.setBlendMode(.sourceAtop)
    context.cgContext.setFillColor(NSColor.white.cgColor)
    context.cgContext.fill(NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: size)
    image.addRepresentation(bitmap)
    return image
}

private final class SplashBrandArtwork: NSView {
    private let runnerImage: NSImage

    init(frame: NSRect, runnerImage: NSImage) {
        self.runnerImage = runnerImage
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawTile()
        drawRunner()
        drawCenteredText("天天打卡", top: 154, size: 42, weight: .bold, color: inkColor)
        drawCenteredText("中小学生体测训练记录", top: 215, size: 20, weight: .medium, color: NSColor(white: 0.52, alpha: 1))
        drawCenteredText("每一秒，每一次，都看得见。", top: 250, size: 15, weight: .regular, color: NSColor(white: 0.65, alpha: 1))
    }

    private var inkColor: NSColor {
        NSColor(srgbRed: 0.06, green: 0.10, blue: 0.08, alpha: 1)
    }

    private func drawTile() {
        let path = NSBezierPath(roundedRect: BrandLayout.tileFrame, xRadius: 34, yRadius: 34)
        let gradient = NSGradient(
            starting: NSColor(srgbRed: 0.102, green: 0.729, blue: 0.380, alpha: 1),
            ending: NSColor(srgbRed: 0.039, green: 0.580, blue: 0.298, alpha: 1)
        )
        gradient?.draw(in: path, angle: -45)
    }

    private func drawRunner() {
        runnerImage.draw(
            in: BrandLayout.symbolBounds,
            from: NSRect(origin: .zero, size: runnerImage.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func drawCenteredText(
        _ text: String,
        top: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let artwork = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
        let height = ceil(artwork.size().height)
        artwork.draw(in: NSRect(x: 0, y: top, width: BrandLayout.canvasSize.width, height: height))
    }
}

private let defaultOutput = "TianTianCheckIn/Assets.xcassets/SplashBrand.imageset/SplashBrand.pdf"
private let outputPath = CommandLine.arguments.dropFirst().first ?? defaultOutput
private let view = SplashBrandArtwork(
    frame: NSRect(origin: .zero, size: BrandLayout.canvasSize),
    runnerImage: makeRunnerImage()
)
private let data = view.dataWithPDF(inside: view.bounds)
try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
print("Generated \(outputPath)")
