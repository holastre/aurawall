import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

struct VideoPreviewPlayerView: NSViewRepresentable {
    let url: URL
    let isPlaying: Bool
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PlayerContainerNSView {
        let view = PlayerContainerNSView()
        context.coordinator.attach(to: view, url: url, isPlaying: isPlaying, videoGravity: videoGravity)
        return view
    }

    func updateNSView(_ nsView: PlayerContainerNSView, context: Context) {
        context.coordinator.update(url: url, isPlaying: isPlaying, videoGravity: videoGravity)
    }

    static func dismantleNSView(_ nsView: PlayerContainerNSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        private var currentURL: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private weak var containerView: PlayerContainerNSView?

        func attach(
            to view: PlayerContainerNSView,
            url: URL,
            isPlaying: Bool,
            videoGravity: AVLayerVideoGravity
        ) {
            self.containerView = view
            configurePlayer(with: url, videoGravity: videoGravity)
            setPlaying(isPlaying)
        }

        func update(url: URL, isPlaying: Bool, videoGravity: AVLayerVideoGravity) {
            if currentURL != url {
                configurePlayer(with: url, videoGravity: videoGravity)
            } else {
                containerView?.playerLayer.videoGravity = videoGravity
            }
            setPlaying(isPlaying)
        }

        func teardown() {
            looper?.disableLooping()
            looper = nil
            player?.pause()
            player?.removeAllItems()
            player?.replaceCurrentItem(with: nil)
            player = nil
            containerView?.playerLayer.player = nil
            currentURL = nil
        }

        private func configurePlayer(with url: URL, videoGravity: AVLayerVideoGravity) {
            teardown()
            currentURL = url

            let asset = AVURLAsset(url: url)
            let templateItem = AVPlayerItem(asset: asset)
            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            queuePlayer.volume = 0.0
            queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
            queuePlayer.actionAtItemEnd = .none

            let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: templateItem)

            self.player = queuePlayer
            self.looper = playerLooper

            if let layer = containerView?.playerLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.player = queuePlayer
                layer.videoGravity = videoGravity
                CATransaction.commit()
            }
        }

        private func setPlaying(_ shouldPlay: Bool) {
            guard let player else { return }
            if shouldPlay {
                if player.timeControlStatus != .playing {
                    player.play()
                }
            } else {
                if player.timeControlStatus != .paused {
                    player.pause()
                }
            }
        }
    }
}

final class PlayerContainerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
