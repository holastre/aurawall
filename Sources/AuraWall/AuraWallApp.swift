import SwiftUI

@main
struct AuraWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("AuraWall", id: "main") {
            MainWindowView(
                coordinator: appDelegate.coordinator,
                onWindowResolved: { window in
                    appDelegate.registerMainWindow(window)
                }
            )
            .frame(minWidth: 980, minHeight: 640)
            .onAppear {
                appDelegate.openMainWindowAction = { [openWindow] in
                    openWindow(id: "main")
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
