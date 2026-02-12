import XCTest
@testable import VoiceToText

final class AIModePresetTests: XCTestCase {

    // MARK: - Built-in Presets

    func testBuiltInPresetsCount() {
        XCTAssertEqual(AIModePreset.builtInPresets.count, 6)
    }

    func testAllBuiltInPresetsAreMarkedBuiltIn() {
        for preset in AIModePreset.builtInPresets {
            XCTAssertTrue(preset.isBuiltIn, "\(preset.name) should be marked as built-in")
        }
    }

    // MARK: - Custom Preset Defaults

    func testCustomPresetDefaultIsNotBuiltIn() {
        let preset = AIModePreset(name: "My Custom", systemPrompt: "Do something")
        XCTAssertFalse(preset.isBuiltIn)
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() {
        let original = AIModePreset(name: "Round Trip", systemPrompt: "Test prompt")

        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(AIModePreset.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.systemPrompt, original.systemPrompt)
        XCTAssertEqual(decoded.isBuiltIn, original.isBuiltIn)
    }

    // MARK: - All Presets (UserDefaults)

    func testAllPresetsIncludesBuiltInAndCustom() {
        defer {
            UserDefaults.standard.removeObject(forKey: StorageKey.aiModePresets)
            UserDefaults.standard.removeObject(forKey: StorageKey.activeAIModePresetId)
        }

        let custom = AIModePreset(name: "Custom Test", systemPrompt: "Custom prompt")
        AIModePreset.saveCustomPresets([custom])

        let all = AIModePreset.allPresets()

        XCTAssertTrue(all.count >= 7, "Expected at least 6 built-in + 1 custom, got \(all.count)")
        XCTAssertTrue(all.contains(where: { $0.id == custom.id }), "Custom preset should appear in allPresets()")
        for builtIn in AIModePreset.builtInPresets {
            XCTAssertTrue(all.contains(where: { $0.id == builtIn.id }), "\(builtIn.name) should appear in allPresets()")
        }
    }

    // MARK: - Active Preset (UserDefaults)

    func testActivePresetRoundTrip() {
        defer {
            UserDefaults.standard.removeObject(forKey: StorageKey.aiModePresets)
            UserDefaults.standard.removeObject(forKey: StorageKey.activeAIModePresetId)
        }

        let custom = AIModePreset(name: "Active Test", systemPrompt: "Active prompt")
        AIModePreset.saveCustomPresets([custom])
        AIModePreset.setActivePreset(custom)

        let active = AIModePreset.activePreset()

        XCTAssertNotNil(active)
        XCTAssertEqual(active?.id, custom.id)
        XCTAssertEqual(active?.name, custom.name)
        XCTAssertEqual(active?.systemPrompt, custom.systemPrompt)
    }
}
