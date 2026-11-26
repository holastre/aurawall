import AppKit
import CoreGraphics
import Foundation
import os

public struct DisplayInfo: Identifiable, Equatable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    public let frame: CGRect
    public let cgBounds: CGRect
    public let backingScaleFactor: CGFloat
    public let isMain: Bool

    public init(
        id: UInt32,
        name: String,
        frame: CGRect,
        cgBounds: CGRect? = nil,
        backingScaleFactor: CGFloat = 2.0,
        isMain: Bool = false
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.cgBounds = cgBounds ?? frame
        self.backingScaleFactor = backingScaleFactor
        self.isMain = isMain
    }
}

public struct ResolvedDisplayAssignment: Equatable, Sendable {
    public let display: DisplayInfo
    public let assignment: DisplayAssignment

    public init(display: DisplayInfo, assignment: DisplayAssignment) {
        self.display = display
        self.assignment = assignment
    }
}

@MainActor
public final class DisplayManager {
    private struct ObserverToken: @unchecked Sendable {
        let token: NSObjectProtocol
    }

    private final class ObserverHolder: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<ObserverToken?>(initialState: nil)

        func replace(with token: NSObjectProtocol?) -> NSObjectProtocol? {
            let wrapped = token.map { ObserverToken(token: $0) }
            let previous = lock.withLock { current -> ObserverToken? in
                let prev = current
                current = wrapped
                return prev
            }
            return previous?.token
        }

        func take() -> NSObjectProtocol? {
            let previous = lock.withLock { current -> ObserverToken? in
                let prev = current
                current = nil
                return prev
            }
            return previous?.token
        }
    }

    public private(set) var displays: [DisplayInfo] = []
    public var onDisplaysChanged: (([DisplayInfo]) -> Void)?

    private let screensProvider: @MainActor () -> [NSScreen]
    private var screensByID: [UInt32: NSScreen] = [:]
    private let observerHolder = ObserverHolder()

    public init(screensProvider: (@MainActor () -> [NSScreen])? = nil) {
        self.screensProvider = screensProvider ?? { NSScreen.screens }
        refreshDisplays(notifyIfChanged: false)
    }

    deinit {
        if let token = observerHolder.take() {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public func startMonitoring() {
        let previous = observerHolder.replace(with: nil)
        if let previous {
            NotificationCenter.default.removeObserver(previous)
        }

        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDisplays()
            }
        }
        _ = observerHolder.replace(with: token)
        refreshDisplays()
    }

    public func stopMonitoring() {
        if let token = observerHolder.take() {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public func refreshDisplays() {
        refreshDisplays(notifyIfChanged: true)
    }

    private func refreshDisplays(notifyIfChanged: Bool) {
        let previous = displays
        let screens = screensProvider()
        let mainDisplayID = CGMainDisplayID()

        var nextDisplays: [DisplayInfo] = []
        var nextMap: [UInt32: NSScreen] = [:]
        var seenIDs: Set<UInt32> = []

        for screen in screens {
            guard let id = Self.displayID(for: screen),
                  seenIDs.insert(id).inserted else {
                continue
            }
            let info = DisplayInfo(
                id: id,
                name: screen.localizedName,
                frame: screen.frame,
                cgBounds: CGDisplayBounds(id),
                backingScaleFactor: screen.backingScaleFactor,
                isMain: id == mainDisplayID
            )
            nextDisplays.append(info)
            nextMap[id] = screen
        }

        displays = nextDisplays
        screensByID = nextMap

        if notifyIfChanged && nextDisplays != previous {
            onDisplaysChanged?(nextDisplays)
        }
    }

    public func screen(for displayID: UInt32) -> NSScreen? {
        screensByID[displayID]
    }

    public func displayInfo(for displayID: UInt32) -> DisplayInfo? {
        displays.first(where: { $0.id == displayID })
    }

    public static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    public static func resolveAssignments(
        config: DisplayConfig,
        connectedDisplays: [DisplayInfo]
    ) -> [ResolvedDisplayAssignment] {
        connectedDisplays.compactMap { display in
            guard let assignment = config.assignment(for: display.id) else {
                return nil
            }
            return ResolvedDisplayAssignment(display: display, assignment: assignment)
        }
    }
}
