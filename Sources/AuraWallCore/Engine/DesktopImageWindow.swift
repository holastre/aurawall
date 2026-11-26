import AppKit
import CoreGraphics
import Foundation
import QuartzCore

@MainActor
public final class DesktopImageWindow {
    public let displayID: UInt32
    public let imageURL: URL
    public private(set) var scalingMode: WallpaperScalingMode
    public private(set) var isTornDown: Bool = false

    private let window: NSWindow
    private let imageLayer: CALayer

    public init?(
        displayID: UInt32,
        frame: NSRect,
        imageURL: URL,
        scalingMode: WallpaperScalingMode = .fill
    ) {
        _ = NSApplication.shared

        guard let image = NSImage(contentsOf: imageURL), !image.representations.isEmpty else {
            return nil
        }

        self.displayID = displayID
        self.imageURL = imageURL
        self.scalingMode = scalingMode

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.ignoresMouseEvents = true
        window.canHide = false
        window.hasShadow = false
        window.isRestorable = false
        window.animationBehavior = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        let contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.wantsLayer = true
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        let layer = CALayer()
        layer.frame = contentView.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.masksToBounds = true
        layer.contents = image
        layer.contentsGravity = Self.contentsGravity(for: scalingMode)
        layer.backgroundColor = Self.layerBackgroundColor(for: scalingMode)
        contentView.layer?.addSublayer(layer)

        self.window = window
        self.imageLayer = layer
    }

    public var windowFrame: NSRect {
        window.frame
    }

    public var windowLevelRawValue: Int {
        window.level.rawValue
    }

    public var isVisible: Bool {
        window.isVisible
    }

    public func show(fadeDuration: TimeInterval = 0.2) {
        guard !isTornDown else { return }

        if !window.isVisible || window.alphaValue < 1.0 {
            if fadeDuration > 0 {
                window.alphaValue = 0.0
                window.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = fadeDuration
                    context.allowsImplicitAnimation = true
                    window.animator().alphaValue = 1.0
                }
            } else {
                window.alphaValue = 1.0
                window.orderFrontRegardless()
            }
        }
    }

    public func updateFrame(_ frame: NSRect) {
        guard !isTornDown else { return }
        window.setFrame(frame, display: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let bounds = window.contentView?.bounds {
            imageLayer.frame = bounds
        }
        CATransaction.commit()
    }

    public func updateScaling(_ scalingMode: WallpaperScalingMode) {
        guard !isTornDown else { return }
        self.scalingMode = scalingMode
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contentsGravity = Self.contentsGravity(for: scalingMode)
        imageLayer.backgroundColor = Self.layerBackgroundColor(for: scalingMode)
        CATransaction.commit()
    }

    public func teardown(fadeDuration: TimeInterval = 0.0) {
        guard !isTornDown else { return }
        _ = fadeDuration
        isTornDown = true

        imageLayer.contents = nil
        imageLayer.removeFromSuperlayer()

        window.orderOut(nil)
        window.close()
    }

    private static func contentsGravity(for scalingMode: WallpaperScalingMode) -> CALayerContentsGravity {
        switch scalingMode {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        }
    }

    private static func layerBackgroundColor(for scalingMode: WallpaperScalingMode) -> CGColor {
        switch scalingMode {
        case .fill: NSColor.clear.cgColor
        case .fit: NSColor.black.cgColor
        }
    }
}
