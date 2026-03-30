// Plugin.swift — ChorographGeminiCLIPlugin
// Entry point for the Gemini CLI Chorograph plugin.
// Registers GeminiCLIProvider as an AI provider and a settings panel.

import ChorographPluginSDK
import SwiftUI

public final class GeminiCLIPlugin: ChorographPlugin, @unchecked Sendable {

    public let manifest = PluginManifest(
        id: "com.chorograph.plugin.gemini-cli",
        displayName: "Gemini CLI",
        description: "Drives the Gemini CLI subprocess and streams JSONL events.",
        version: "1.1.4",
        capabilities: [.aiProvider, .settingsPanel]
    )

    public init() {}

    public func bootstrap(context: any PluginContextProviding) async throws {
        context.registerProvider(GeminiCLIProvider())
        context.registerSettingsPanel(title: "Gemini CLI", AnyView(GeminiCLISettingsView()))
    }
}

// MARK: - C-ABI factory (required for dlopen-based loading)

@_cdecl("chorograph_plugin_create")
public func chorographPluginCreate() -> UnsafeMutableRawPointer {
    let plugin = GeminiCLIPlugin()
    return Unmanaged.passRetained(plugin as AnyObject).toOpaque()
}
