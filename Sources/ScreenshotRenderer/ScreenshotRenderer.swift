//
//  ScreenshotRenderer.swift
//
//  Renders the interface to PNG for the README, without a screen-recording permission and without
//  a visible window.
//
//  `screencapture` needs the Screen Recording entitlement, and SwiftUI's `ImageRenderer` refuses
//  `NavigationSplitView` and `List` with a "not supported" placeholder. Hosting the view in an
//  offscreen `NSWindow` and asking it for its bitmap sidesteps both: it is the real view hierarchy,
//  laid out by the real AppKit, just never ordered on screen.
//
//  It seeds a throwaway configuration through the same `ConfigurationStore` the app uses, so the
//  JSON cannot drift from the real format. Point `CLAUDE_CONFIG_DIR` at an empty directory before
//  running it; scripts/render-screenshots.sh does that.
//
//  One known infidelity: a switch that is on draws its knob on the right but keeps a grey track,
//  where the real app tints that track with the accent colour. A control in a window that is never
//  ordered on screen gets the inactive drawing path, and forcing the window key broke the layout
//  outright. The knob position still states the value, and the section badge counts the same set
//  the switches read, so the image is not misleading — just less colourful than the app.
//
//  Not part of the shipped app.
//

import AppKit
import SwiftUI
import ClaudeBridgerCore
import ClaudeBridgerUI

@MainActor
func render(view: some View, size: CGSize, to path: String) throws {
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(origin: .zero, size: size)

    let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.contentView = host
    // A control that is in a non-key window draws its inactive appearance, which turns an enabled
    // switch grey and reads as disabled. Marking the window key fixes the tint without ever
    // ordering it on screen.
    window.isReleasedWhenClosed = false
    window.makeKey()

    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    // Settle in two passes: the switch control animates its knob, and a single cacheDisplay can
    // catch it mid-flight and freeze the wrong state into the image.
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    host.displayIfNeeded()
    host.layoutSubtreeIfNeeded()

    defer { window.orderOut(nil) }

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw NSError(domain: "render", code: 1, userInfo: [NSLocalizedDescriptionKey: "no bitmap rep"])
    }
    rep.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render", code: 2, userInfo: [NSLocalizedDescriptionKey: "no png data"])
    }
    try data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  (\(Int(size.width))x\(Int(size.height))")
}

/// Two profiles, so the sidebar shows a list rather than a single row, and the selected one has
/// every new option group populated.
func sampleProfiles() -> [BackendProfile] {
    var deepseek = BackendProfile(
        id: "deepseek",
        name: "DeepSeek 直连",
        baseURL: "https://api.deepseek.com/anthropic"
    )
    deepseek.category = "国产大模型"
    deepseek.credentialMode = .authToken
    for tier in [ModelTier.primary, .sonnet, .haiku] {
        deepseek.setModel("deepseek-v4.1-flash[1m]", for: tier)
    }
    deepseek.setModel("glm-5.3-flash[1m]", for: .opus)
    deepseek.setModel("mimo-v2.6-pro[1m]", for: .fable)
    deepseek.contextWindow = 1000000
    deepseek.setDisplayName("glm-5.3-flash", for: .opus)
    deepseek.setDisplayName("deepseek-v4.1-flash", for: .sonnet)
    deepseek.setFlag(.disableNonessentialTraffic, on: true)
    deepseek.setFlag(.omitAttributionHeader, on: true)
    deepseek.setFlag(.disableExtraUsageCommand, on: true)
    deepseek.setChoice(.toolSearch, value: "true")
    deepseek.setNumeric(.maxOutputTokens, value: "64000")
    deepseek.effortLevel = .max

    var kimi = BackendProfile(
        id: "kimi",
        name: "Kimi 中转",
        baseURL: "https://relay.example.com/anthropic"
    )
    kimi.category = "第三方中转"
    kimi.credentialMode = .apiKey
    kimi.setModel("kimi-k2-thinking[1m]", for: .primary)
    kimi.setFlag(.disableNonessentialTraffic, on: true)

    return [deepseek, kimi]
}

/// Writes the sample configuration and a matching settings.json, using the real stores.
func seedConfiguration(paths: ClaudePaths) throws {
    let profiles = sampleProfiles()
    var stored: [StoredProfile] = []
    for profile in profiles {
        stored.append(StoredProfile(profile))
    }
    let configuration = ClaudeBridgerConfiguration(
        profiles: stored,
        activeProfileID: profiles.first?.id,
        publishedProfile: stored.first
    )
    try ConfigurationStore(paths: paths).save(configuration)

    // A settings.json that matches the first profile, so the sidebar's "current state" and the
    // activation bar show something true rather than "未写入".
    var active = profiles[0]
    active.credential = "sk-example-placeholder"
    _ = try ClaudeSettingsWriter(paths: paths).activate(
        profile: active, credential: active.credential, writeOnboardingFlag: false
    )
}

@main
struct ScreenshotRenderer {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let outputDirectory = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "docs/images"

        let paths = ClaudePaths()
        guard ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] != nil else {
            FileHandle.standardError.write(
                Data("set CLAUDE_CONFIG_DIR to an empty directory first\n".utf8)
            )
            exit(1)
        }

        try seedConfiguration(paths: paths)

        // Print the state the form will read, so a screenshot can be checked against the model
        // rather than against a guess about which row is which.
        let sample = sampleProfiles().first!
        for flag in EnvironmentFlag.allCases where sample.isOn(flag) {
            print("flag on: \(flag.key) = \(flag.onValue)")
        }

        let size = CGSize(width: 860, height: 880)
        let model = AppModel(paths: paths)
        model.refreshSnapshot()
        model.selectProfile("deepseek")

        try render(
            view: ContentView(model: model),
            size: size,
            to: outputDirectory + "/app-main.png"
        )

        // The option groups start collapsed for the app's own use, so that the endpoint and the
        // credential stay on the first screen. Opened here, because otherwise the headline of this
        // release would be invisible in its own screenshot. Animations are switched off so every
        // control has settled before the bitmap is taken.
        try render(
            view: ContentView(model: model)
                .environment(\.disclosureInitiallyExpanded, true)
                .transaction { $0.animation = nil },
            size: CGSize(width: 860, height: 2000),
            to: outputDirectory + "/app-options.png"
        )
    }
}
