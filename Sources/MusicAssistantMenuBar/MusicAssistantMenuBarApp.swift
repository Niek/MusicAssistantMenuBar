import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct MusicAssistantMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PlayerStore()

    var body: some Scene {
        MenuBarExtra("Music Assistant", systemImage: store.statusSymbolName) {
            MenuPanelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
