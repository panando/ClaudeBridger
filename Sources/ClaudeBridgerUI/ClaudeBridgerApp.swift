import SwiftUI
import ClaudeBridgerCore

/// The app entry point.
///
/// macOS-only, window-based, with a Settings scene. No menu-bar item: this app is opened when a
/// backend changes, which is rarely, and a permanently running agent for a task that takes two
/// minutes would be the wrong shape.
public struct ClaudeBridgerApp: App {
    @StateObject private var model: AppModel

    public init() {
        _model = StateObject(wrappedValue: AppModel())
    }

    public var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { model.refreshSnapshot() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("重新读取配置文件") {
                    model.refreshSnapshot()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
