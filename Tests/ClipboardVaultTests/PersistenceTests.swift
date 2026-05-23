import Testing
import Foundation
@testable import ClipboardVault

@Suite("Persistence round-trip")
struct PersistenceTests {

    /// Creates a fresh on-disk DB under the temp dir and returns a persistence
    /// pointed at it. Uses a unique filename per test so they can run in parallel.
    private func makePersistence(file: StaticString = #file, line: UInt = #line) -> (ClipboardPersistence, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardVaultTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("clipboard.sqlite")
        return (ClipboardPersistence(path: path.path), dir)
    }

    @Test func storesAndLoadsTextEntry() throws {
        let (db, dir) = makePersistence()
        defer { try? FileManager.default.removeItem(at: dir) }

        let entry = ClipboardEntry(kind: .text("hello world"))
        db.upsert(entry, imageData: nil)

        let loaded = db.loadEntries()
        #expect(loaded.count == 1)
        if case .text(let value) = loaded.first?.kind {
            #expect(value == "hello world")
        } else {
            Issue.record("expected text kind")
        }
        #expect(loaded.first?.id == entry.id)
    }

    @Test func favoritesSortAboveOlderEntries() throws {
        let (db, dir) = makePersistence()
        defer { try? FileManager.default.removeItem(at: dir) }

        let older = ClipboardEntry(createdAt: Date().addingTimeInterval(-100),
                                   kind: .text("older"),
                                   isFavorite: true)
        let newer = ClipboardEntry(kind: .text("newer"))
        db.upsert(older, imageData: nil)
        db.upsert(newer, imageData: nil)

        let loaded = db.loadEntries()
        #expect(loaded.count == 2)
        #expect(loaded.first?.isFavorite == true)
    }

    @Test func updateFavoritePersists() throws {
        let (db, dir) = makePersistence()
        defer { try? FileManager.default.removeItem(at: dir) }

        let entry = ClipboardEntry(kind: .text("toggle me"))
        db.upsert(entry, imageData: nil)
        db.updateFavorite(id: entry.id, isFavorite: true)

        let loaded = db.loadEntries()
        #expect(loaded.first?.isFavorite == true)
    }

    @Test func deleteRemovesEntry() throws {
        let (db, dir) = makePersistence()
        defer { try? FileManager.default.removeItem(at: dir) }

        let entry = ClipboardEntry(kind: .text("ephemeral"))
        db.upsert(entry, imageData: nil)
        db.delete(id: entry.id)
        #expect(db.loadEntries().isEmpty)
    }

    @Test func trimToMaxKeepsNewest() throws {
        let (db, dir) = makePersistence()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<10 {
            let e = ClipboardEntry(
                createdAt: Date().addingTimeInterval(TimeInterval(i)),
                kind: .text("entry \(i)")
            )
            db.upsert(e, imageData: nil)
        }
        db.trimToMax(3)
        let loaded = db.loadEntries()
        #expect(loaded.count == 3)
        // Newest (entry 9) should be on top.
        if case .text(let v) = loaded.first?.kind {
            #expect(v == "entry 9")
        }
    }

    @Test func imageBlobRoundTrip() throws {
        let (db, dir) = makePersistence()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data((0..<256).map { UInt8($0 % 256) })
        let entry = ClipboardEntry(kind: .image(id: UUID(), width: 12, height: 34))
        db.upsert(entry, imageData: payload)

        let loadedData = db.loadImageData(id: entry.id)
        #expect(loadedData == payload)
    }

    @Test func clearAllEmptiesDatabase() throws {
        let (db, dir) = makePersistence()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<5 {
            db.upsert(ClipboardEntry(kind: .text("\(i)")), imageData: nil)
        }
        db.clearAll()
        #expect(db.loadEntries().isEmpty)
    }
}
