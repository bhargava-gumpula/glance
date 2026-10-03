import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsController {
    private var window: NSWindow?
    private let model = SettingsModel()

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Glance Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
        }
        model.load()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var providerID = Config.provider
    @Published var model = ""
    @Published var baseURL = ""
    @Published var supportsImages = true
    @Published var keyInput = ""
    @Published var hasKey = false
    @Published var saved = ""

    var preset: Config.ProviderPreset { Config.preset(providerID) }

    func load() {
        model = Config.model(for: providerID)
        baseURL = Config.baseURL(for: providerID)
        supportsImages = Config.supportsImages(for: providerID)
        keyInput = ""
        hasKey = Keychain.has(providerID)
        saved = ""
    }

    func select(_ id: String) {
        providerID = id
        UserDefaults.standard.set(id, forKey: "provider")
        load()
    }

    func save() {
        let d = UserDefaults.standard
        d.set(model.trimmingCharacters(in: .whitespaces), forKey: "model.\(providerID)")
        d.set(Config.normalizedBaseURL(baseURL), forKey: "baseURL.\(providerID)")
        d.set(supportsImages, forKey: "supportsImages.\(providerID)")
        if !keyInput.isEmpty { Keychain.set(providerID, keyInput) }
        keyInput = ""
        hasKey = Keychain.has(providerID)
        saved = "Saved."
    }

    func removeKey() {
        Keychain.set(providerID, "")
        hasKey = false
        saved = "Key removed."
    }

    func resetDefaults() {
        for key in ["model.", "baseURL.", "supportsImages."] { UserDefaults.standard.removeObject(forKey: key + providerID) }
        load()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Picker("AI provider", selection: Binding(get: { model.providerID }, set: { model.select($0) })) {
                ForEach(Config.providerPresets, id: \.id) { Text($0.name).tag($0.id) }
            }
            TextField("Model", text: $model.model)
            TextField("Address (not the key)", text: $model.baseURL)
            Toggle("Model can see images (otherwise sends on-screen text)", isOn: $model.supportsImages)
            if model.preset.needsKey {
                HStack {
                    SecureField(model.hasKey ? "Key saved in Keychain. Type to replace" : "API key", text: $model.keyInput)
                    if model.hasKey { Button("Remove") { model.removeKey() } }
                }
            }
            HStack {
                Button("Reset to defaults") { model.resetDefaults() }
                Spacer()
                Text(model.saved).foregroundStyle(.secondary)
                Button("Save") { model.save() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }
}
