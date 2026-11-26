import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import os
import QuartzCore

@MainActor
public final class DesktopVideoWindow {
    private struct UncheckedObserver: @unchecked Sendable {
        let kvo: NSKeyValueObservation?
        let notification: NSObjectProtocol?
    }

    private final class ObserverStore: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[UncheckedObserver]>(initialState: [])

        func add(_ kvo: NSKeyValueObservation) {
            let wrapped = UncheckedObserver(kvo: kvo, notification: nil)
            lock.withLock { $0.append(wrapped) }
        }

        func add(_ notification: NSObjectProtocol) {
            let wrapped = UncheckedObserver(kvo: nil, notification: notification)
            lock.withLock { $0.append(wrapped) }
        }

        func invalidateAll() {
            let items = lock.withLock { current -> [UncheckedObserver] in
                let copy = current
                current = []
                return copy
            }
            for item in items {
                item.kvo?.invalidate()
                if let token = item.notification {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }
    }

    public let displayID: UInt32
    public let videoURL: URL
    public private(set) var scalingMode: WallpaperScalingMode
    public private(set) var isPlaying: Bool = false
    public private(set) var isTornDown: Bool = false
    public private(set) var hasFailed: Bool = false
    public var onFailure: ((Error?) -> Void)?

    private let window: NSWindow
    private let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    private let playerLayer: AVPlayerLayer
    private let observerStore = ObserverStore()

    public init(
        displayID: UInt32,
        frame: NSRect,
        videoURL: URL,
        scalingMode: WallpaperScalingMode = .fill
    ) {
        _ = NSApplication.shared

        self.displayID = displayID
        self.videoURL = videoURL
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

        let asset = AVURLAsset(url: videoURL)
        let templateItem = AVPlayerItem(asset: asset)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        queuePlayer.volume = 0.0
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        queuePlayer.actionAtItemEnd = .none

        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: templateItem)

        let layer = AVPlayerLayer(player: queuePlayer)
        layer.frame = contentView.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = Self.videoGravity(for: scalingMode)
        layer.backgroundColor = Self.layerBackgroundColor(for: scalingMode)
        contentView.layer?.addSublayer(layer)

        self.window = window
        self.player = queuePlayer
        self.looper = playerLooper
        self.playerLayer = layer

        observePlaybackFailures(looper: playerLooper, templateItem: templateItem)
    }

    deinit {
        observerStore.invalidateAll()
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

    public func play(fadeDuration: TimeInterval = 0.25) {
        guard !isTornDown, !hasFailed else { return }

        isPlaying = true
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
        player.play()
    }

    public func pause() {
        guard !isTornDown else { return }
        isPlaying = false
        player.pause()
    }

    public func updateFrame(_ frame: NSRect) {
        guard !isTornDown else { return }
        window.setFrame(frame, display: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let bounds = window.contentView?.bounds {
            playerLayer.frame = bounds
        }
        CATransaction.commit()
    }

    public func updateScaling(_ scalingMode: WallpaperScalingMode) {
        guard !isTornDown else { return }
        self.scalingMode = scalingMode
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.videoGravity = Self.videoGravity(for: scalingMode)
        playerLayer.backgroundColor = Self.layerBackgroundColor(for: scalingMode)
        CATransaction.commit()
    }

    public func teardown(fadeDuration: TimeInterval = 0.0) {
        guard !isTornDown else { return }
        _ = fadeDuration
        isTornDown = true
        isPlaying = false

        observerStore.invalidateAll()

        looper?.disableLooping()
        looper = nil

        player.pause()
        player.removeAllItems()
        player.replaceCurrentItem(with: nil)

        playerLayer.player = nil
        playerLayer.removeFromSuperlayer()

        window.orderOut(nil)
        window.close()
    }

    private func observePlaybackFailures(looper: AVPlayerLooper, templateItem: AVPlayerItem) {
        let looperKVO = looper.observe(\.status, options: [.new]) { [weak self] observedLooper, _ in
            guard observedLooper.status == .failed else { return }
            let err = observedLooper.error
            Task { @MainActor [weak self] in
                self?.handleFailure(error: err)
            }
        }
        observerStore.add(looperKVO)

        let itemKVO = templateItem.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard observedItem.status == .failed else { return }
            let err = observedItem.error
            Task { @MainActor [weak self] in
                self?.handleFailure(error: err)
            }
        }
        observerStore.add(itemKVO)

        let failedNotification = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let failedItem = note.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self, !self.isTornDown else { return }
                if failedItem == nil || failedItem === self.player.currentItem {
                    self.handleFailure(error: err)
                }
            }
        }
        observerStore.add(failedNotification)
    }

    private func handleFailure(error: Error?) {
        guard !isTornDown, !hasFailed else { return }
        hasFailed = true
        isPlaying = false
        player.pause()
        onFailure?(error)
    }

    private static func videoGravity(for scalingMode: WallpaperScalingMode) -> AVLayerVideoGravity {
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
