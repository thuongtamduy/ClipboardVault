import Testing
import Foundation
@testable import ClipboardVault

@Suite("SmartType detection")
struct SmartTypeTests {
    @Test func detectsHTTPSURL() {
        let entry = ClipboardEntry(kind: .text("https://example.com/path"))
        guard case .url(let url) = entry.smartType else {
            Issue.record("expected .url, got \(entry.smartType)")
            return
        }
        #expect(url.absoluteString == "https://example.com/path")
    }

    @Test func detectsHTTPURL() {
        let entry = ClipboardEntry(kind: .text("http://localhost:8080"))
        if case .url = entry.smartType { return }
        Issue.record("expected .url, got \(entry.smartType)")
    }

    @Test func ignoresPlainText() {
        let entry = ClipboardEntry(kind: .text("just some plain words"))
        #expect(entry.smartType == .none)
    }

    @Test func ignoresEmptyAndWhitespaceText() {
        #expect(ClipboardEntry(kind: .text("")).smartType == .none)
        #expect(ClipboardEntry(kind: .text("   ")).smartType == .none)
    }

    @Test func detectsHexColor() {
        let entry = ClipboardEntry(kind: .text("#FF8800"))
        if case .color = entry.smartType { return }
        Issue.record("expected .color, got \(entry.smartType)")
    }

    @Test func ignoresShortHex() {
        // Only 6-digit hex is accepted; #ABC should not match.
        #expect(ClipboardEntry(kind: .text("#ABC")).smartType == .none)
    }

    @Test func ignoresInvalidHexChars() {
        #expect(ClipboardEntry(kind: .text("#ZZZZZZ")).smartType == .none)
    }

    @Test func trimsWhitespaceBeforeDetecting() {
        let entry = ClipboardEntry(kind: .text("  https://trimmed.example  "))
        if case .url = entry.smartType { return }
        Issue.record("expected .url after trim, got \(entry.smartType)")
    }

    @Test func imageEntryAlwaysNone() {
        let entry = ClipboardEntry(kind: .image(id: UUID(), width: 100, height: 100))
        #expect(entry.smartType == .none)
    }

    @Test func smartTypeIsStableAcrossFavoriteToggle() {
        // smartType is set once at init; mutating isFavorite must not change it.
        var entry = ClipboardEntry(kind: .text("#00AAFF"))
        let originalType = entry.smartType
        entry.isFavorite = true
        #expect(entry.smartType == originalType)
    }
}
