import SwiftUI
import AppKit
import Carbon.HIToolbox
import SQLite3
import ServiceManagement
import OSLog

private enum Log {
    static let subsystem = "com.thuongtamduy.ClipboardVault"
    static let db       = Logger(subsystem: subsystem, category: "db")
    static let hotkey   = Logger(subsystem: subsystem, category: "hotkey")
    static let installer = Logger(subsystem: subsystem, category: "installer")
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ClipboardKind: Equatable {
    case text(String)
    case image(id: UUID, width: Double, height: Double)
}

struct ClipboardEntry: Identifiable, Equatable {
    enum SmartType: Equatable {
        case url(URL)
        case color(Color)
        case none
    }

    let id: UUID
    let createdAt: Date
    let kind: ClipboardKind
    var isFavorite: Bool
    let smartType: SmartType

    init(id: UUID = UUID(), createdAt: Date = Date(), kind: ClipboardKind, isFavorite: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.isFavorite = isFavorite
        self.smartType = Self.detectSmartType(kind: kind)
    }

    private static func detectSmartType(kind: ClipboardKind) -> SmartType {
        guard case .text(let text) = kind else { return .none }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("#") {
            let hex = trimmed.dropFirst()
            if hex.count == 6 {
                let scanner = Scanner(string: String(hex))
                var hexNumber: UInt64 = 0
                if scanner.scanHexInt64(&hexNumber) {
                    let r = Double((hexNumber & 0xff0000) >> 16) / 255.0
                    let g = Double((hexNumber & 0x00ff00) >> 8) / 255.0
                    let b = Double(hexNumber & 0x0000ff) / 255.0
                    return .color(Color(red: r, green: g, blue: b))
                }
            }
        }

        if let url = URL(string: trimmed), url.scheme != nil {
            return .url(url)
        }

        return .none
    }
}

enum SidebarFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case text = "Text"
    case images = "Images"
    case favorites = "Favorites"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .text: return "doc.text"
        case .images: return "photo"
        case .favorites: return "star.fill"
        }
    }
}

final class ClipboardPersistence {
    private var db: OpaquePointer?
    private let explicitPath: String?

    /// `path` is for tests; production callers use the default which lives in
    /// Application Support.
    init(path: String? = nil) {
        self.explicitPath = path
        openDatabase()
        runMigrations()
    }

    deinit {
        sqlite3_close(db)
    }

    func loadEntries() -> [ClipboardEntry] {
        guard let db else { return [] }
        let sql = "SELECT id, created_at, kind, text_value, is_favorite, image_width, image_height FROM clipboard_entries ORDER BY is_favorite DESC, created_at DESC;"
        var stmt: OpaquePointer?
        var entries: [ClipboardEntry] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idC = sqlite3_column_text(stmt, 0),
                let kindC = sqlite3_column_text(stmt, 2)
            else {
                continue
            }

            let idStr = String(cString: idC)
            let kindStr = String(cString: kindC)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let isFavorite = sqlite3_column_int(stmt, 4) == 1

            guard let uuid = UUID(uuidString: idStr) else { continue }

            if kindStr == "text" {
                let text = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                entries.append(ClipboardEntry(id: uuid, createdAt: createdAt, kind: .text(text), isFavorite: isFavorite))
            } else if kindStr == "image" {
                let width = sqlite3_column_double(stmt, 5)
                let height = sqlite3_column_double(stmt, 6)
                entries.append(ClipboardEntry(id: uuid, createdAt: createdAt, kind: .image(id: uuid, width: width, height: height), isFavorite: isFavorite))
            }
        }

        return entries
    }

    func upsert(_ entry: ClipboardEntry, imageData: Data? = nil) {
        guard let db else { return }
        let sql = "INSERT OR REPLACE INTO clipboard_entries (id, created_at, kind, text_value, image_data, image_width, image_height, is_favorite) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, entry.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, entry.createdAt.timeIntervalSince1970)

        switch entry.kind {
        case .text(let text):
            sqlite3_bind_text(stmt, 3, "text", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_null(stmt, 5)
            sqlite3_bind_null(stmt, 6)
            sqlite3_bind_null(stmt, 7)
        case .image(_, let width, let height):
            sqlite3_bind_text(stmt, 3, "image", -1, SQLITE_TRANSIENT)
            sqlite3_bind_null(stmt, 4)
            if let imageData {
                _ = imageData.withUnsafeBytes { rawBuffer in
                    sqlite3_bind_blob(stmt, 5, rawBuffer.baseAddress, Int32(imageData.count), SQLITE_TRANSIENT)
                }
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_double(stmt, 6, width)
            sqlite3_bind_double(stmt, 7, height)
        }

        sqlite3_bind_int(stmt, 8, entry.isFavorite ? 1 : 0)
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            Log.db.error("Upsert failed: \(errorMsg, privacy: .public)")
        }
    }

    func loadImageData(id: UUID) -> Data? {
        guard let db else { return nil }
        let sql = "SELECT image_data FROM clipboard_entries WHERE LOWER(id) = LOWER(?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(stmt, 0) {
                let length = Int(sqlite3_column_bytes(stmt, 0))
                return Data(bytes: bytes, count: length)
            }
        }
        return nil
    }

    func updateFavorite(id: UUID, isFavorite: Bool) {
        guard let db else { return }
                let sql = "UPDATE clipboard_entries SET is_favorite = ? WHERE LOWER(id) = LOWER(?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, isFavorite ? 1 : 0)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func delete(id: UUID) {
        guard let db else { return }
                let sql = "DELETE FROM clipboard_entries WHERE LOWER(id) = LOWER(?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func trimToMax(_ max: Int) {
        guard let db else { return }
        let sql = "DELETE FROM clipboard_entries WHERE id NOT IN (SELECT id FROM clipboard_entries ORDER BY is_favorite DESC, created_at DESC LIMIT ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(max))
        sqlite3_step(stmt)
    }

    func clearAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM clipboard_entries;", nil, nil, nil)
    }

    private func openDatabase() {
        let path: String
        if let explicitPath {
            path = explicitPath
        } else {
            let fm = FileManager.default
            guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let dir = appSupport.appendingPathComponent("ClipboardVault", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            path = dir.appendingPathComponent("clipboard.sqlite").path
        }
        // FULLMUTEX serializes all calls on this connection so it is safe to use
        // from both the @MainActor store (writes) and the EntryCard background
        // Task that lazily loads image BLOBs.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            Log.db.error("Failed to open database at: \(path, privacy: .public)")
        } else {
            Log.db.debug("Database opened at: \(path, privacy: .public)")
            // Enable WAL mode for better concurrency
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        }
    }

    private func runMigrations() {
        guard let db else { return }
        let current = readUserVersion()

        if current < 1 {
            // Baseline schema. Idempotent: CREATE … IF NOT EXISTS handles fresh
            // installs; the two ALTERs below cover users upgrading from an even
            // older build that pre-dated image_width/image_height.
            sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS clipboard_entries (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                kind TEXT NOT NULL,
                text_value TEXT,
                image_data BLOB,
                image_width REAL,
                image_height REAL,
                is_favorite INTEGER NOT NULL DEFAULT 0
            );
            """, nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE clipboard_entries ADD COLUMN image_width REAL;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE clipboard_entries ADD COLUMN image_height REAL;", nil, nil, nil)
            writeUserVersion(1)
        }

        // Future migrations append here as: if current < 2 { … writeUserVersion(2) }
    }

    private func readUserVersion() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    private func writeUserVersion(_ version: Int) {
        guard let db else { return }
        // PRAGMA does not accept bound parameters, but version is internal so
        // string interpolation is safe here.
        sqlite3_exec(db, "PRAGMA user_version = \(version);", nil, nil, nil)
    }
}

final class ImageCache {
    private let cache = NSCache<NSUUID, NSImage>()
    private let persistence: ClipboardPersistence

    init(persistence: ClipboardPersistence) {
        self.persistence = persistence
        // Hold up to the full default history so scroll-back doesn't re-decode;
        // bounded by ~100MB total so a few huge screenshots can't blow memory.
        cache.countLimit = 200
        cache.totalCostLimit = 100 * 1024 * 1024
    }

    /// Synchronous: returns the cached image if present, otherwise reads it
    /// from SQLite, decodes, and caches.
    func image(for id: UUID) -> NSImage? {
        let key = id as NSUUID
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let data = persistence.loadImageData(id: id),
              let image = NSImage(data: data) else { return nil }
        // PNG byte count is a reasonable proxy for the decoded image's memory
        // footprint (decoded bitmap is larger, but the relative cost ordering
        // is what matters for NSCache eviction).
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    /// Non-loading peek — returns nil on miss instead of hitting the DB. Used
    /// by EntryCard at init time to avoid a one-frame ProgressView flash for
    /// images that are already in memory.
    func cachedImage(for id: UUID) -> NSImage? {
        cache.object(forKey: id as NSUUID)
    }

    func invalidate(id: UUID) {
        cache.removeObject(forKey: id as NSUUID)
    }

    func invalidateAll() {
        cache.removeAllObjects()
    }
}

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published var enabled: Bool = false
    @Published var lastError: String?

    init() {
        enabled = (SMAppService.mainApp.status == .enabled)
    }

    func setEnabled(_ newValue: Bool) {
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            enabled = newValue
            lastError = nil
        } catch {
            enabled = (SMAppService.mainApp.status == .enabled)
            lastError = error.localizedDescription
        }
    }
}

@MainActor
final class ClipboardStore: ObservableObject {
    @Published var entries: [ClipboardEntry] = []
    @Published var searchText: String = ""
    @Published var selectedFilter: SidebarFilter = .all

    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var lastSignature: String = ""
    static let defaultMaxEntries = 200
    static let defaultPollInterval: TimeInterval = 1.0

    private var maxEntries: Int {
        let stored = UserDefaults.standard.integer(forKey: "maxEntries")
        return stored > 0 ? stored : Self.defaultMaxEntries
    }
    private var pollInterval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "pollInterval")
        return stored > 0 ? stored : Self.defaultPollInterval
    }
    let persistence = ClipboardPersistence()
    let imageCache: ImageCache

    init() {
        let p = persistence
        self.imageCache = ImageCache(persistence: p)
        // One-shot trim in case a previous app version stored more than the
        // current cap; keeps the in-memory and on-disk views consistent.
        p.trimToMax(maxEntries)
        entries = p.loadEntries()
        startMonitoring()
    }

    var filteredEntries: [ClipboardEntry] {
        let sorted = entries.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite && !rhs.isFavorite }
            return lhs.createdAt > rhs.createdAt
        }

        let byType = sorted.filter { entry in
            switch selectedFilter {
            case .all:
                return true
            case .text:
                if case .text = entry.kind { return true }
                return false
            case .images:
                if case .image = entry.kind { return true }
                return false
            case .favorites:
                return entry.isFavorite
            }
        }

        let key = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return byType }
        // range(of:options:) defers to CFString comparison: no per-entry
        // String allocation, unlike `lhs.lowercased().contains(rhs.lowercased())`.
        return byType.filter { entry in
            switch entry.kind {
            case .text(let text):
                return text.range(of: key, options: .caseInsensitive) != nil
            case .image:
                return "image photo screenshot".range(of: key, options: .caseInsensitive) != nil
            }
        }
    }

    var quickEntries: [ClipboardEntry] {
        let sortedByDate = entries.sorted { $0.createdAt > $1.createdAt }
        return Array(sortedByDate.prefix(20))
    }

    func startMonitoring() {
        lastChangeCount = pasteboard.changeCount
        // Schedule on .common so the timer keeps firing during scroll/menu
        // tracking — otherwise we miss clipboard changes for as long as the
        // user holds a scroll gesture anywhere on the system.
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Returns true if something was actually written to the pasteboard.
    @discardableResult
    func copyBack(_ entry: ClipboardEntry) -> Bool {
        switch entry.kind {
        case .text(let value):
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            // Pre-match the signature so that if the user then externally
            // re-copies the same text within the polling window we still dedup.
            lastSignature = "text:\(value)"
        case .image(let id, _, _):
            guard let image = imageCache.image(for: id) else {
                // BLOB missing / corrupt — don't clobber whatever the user
                // had on the clipboard before.
                Log.db.error("copyBack: image data missing for entry \(id.uuidString, privacy: .public)")
                return false
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }
        // Our own write bumped changeCount; absorb it so the next poll doesn't
        // treat it as a fresh external copy and re-insert a duplicate entry.
        lastChangeCount = pasteboard.changeCount
        return true
    }

    func clearAll() {
        entries.removeAll()
        persistence.clearAll()
        imageCache.invalidateAll()
    }

    func remove(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        persistence.delete(id: entry.id)
        if case .image = entry.kind {
            imageCache.invalidate(id: entry.id)
        }
    }

    func toggleFavorite(_ entry: ClipboardEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx].isFavorite.toggle()
        persistence.updateFavorite(id: entries[idx].id, isFavorite: entries[idx].isFavorite)
    }

    // Sentinel UTIs / private types declared by sources we should not record.
    // Standard for password managers / OTP apps; see nspasteboard.org.
    private static let sensitivePasteboardTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword"),
    ]

    private func checkClipboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Drop anything tagged as a secret / one-shot value before we touch
        // string() or data() — we bumped lastChangeCount above so we won't
        // re-test the same pasteboard generation.
        let types = pasteboard.types ?? []
        if Self.sensitivePasteboardTypes.contains(where: { types.contains($0) }) {
            return
        }

        if let text = pasteboard.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let signature = "text:\(text)"
            guard signature != lastSignature else { return }
            lastSignature = signature
            insert(.text(text))
            return
        }

        if let tiffData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiffData) {
            // PNG is ~5-10× smaller than raw TIFF for typical screenshots; fall
            // back to TIFF only if PNG encoding fails for some reason.
            let storedData: Data = {
                guard let bitmap = NSBitmapImageRep(data: tiffData),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    return tiffData
                }
                return png
            }()
            // Use byte count + a small stable prefix slice for the signature so
            // identical images dedup reliably within a session.
            let prefix = storedData.prefix(64)
            let signature = "image:\(storedData.count):\(prefix.hashValue)"
            guard signature != lastSignature else { return }
            lastSignature = signature

            let id = UUID()
            insert(.image(id: id, width: image.size.width, height: image.size.height), imageData: storedData)
        }
    }

    private func insert(_ kind: ClipboardKind, imageData: Data? = nil) {
        let id: UUID
        if case .image(let imgId, _, _) = kind {
            id = imgId
        } else {
            id = UUID()
        }
        
        let entry = ClipboardEntry(id: id, kind: kind)
        entries.insert(entry, at: 0)
        persistence.upsert(entry, imageData: imageData)

        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
            persistence.trimToMax(maxEntries)
        }
    }
}

@MainActor
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var activationHandler: (() -> Void)?

    func register(activation: @escaping () -> Void) {
        activationHandler = activation
        let hotKeyID = EventHotKeyID(signature: OSType(0x43564C54), id: 1)
        let modifierFlags: UInt32 = UInt32(cmdKey) | UInt32(shiftKey)

        RegisterEventHotKey(UInt32(kVK_ANSI_V), modifierFlags, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()

            var hkID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)

            if hkID.id == 1 {
                Log.hotkey.debug("Cmd+Shift+V triggered")
                DispatchQueue.main.async {
                    manager.activationHandler?()
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &eventHandlerRef)
    }
}

struct SidebarView: View {
    @ObservedObject var store: ClipboardStore

    var body: some View {
        List(SidebarFilter.allCases, selection: $store.selectedFilter) { filter in
            Label(filter.rawValue, systemImage: filter.icon)
                .tag(filter)
        }
        .listStyle(.sidebar)
    }
}

struct EntryCard: View {
    @ObservedObject var store: ClipboardStore
    let entry: ClipboardEntry
    let isSelected: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onToggleFavorite: () -> Void

    @State private var hovering = false
    @State private var loadedImage: NSImage?
    @Environment(\.colorScheme) var colorScheme

    init(store: ClipboardStore,
         entry: ClipboardEntry,
         isSelected: Bool,
         onCopy: @escaping () -> Void,
         onDelete: @escaping () -> Void,
         onToggleFavorite: @escaping () -> Void) {
        self.store = store
        self.entry = entry
        self.isSelected = isSelected
        self.onCopy = onCopy
        self.onDelete = onDelete
        self.onToggleFavorite = onToggleFavorite
        // Pre-seed loadedImage from the in-memory cache so a card scrolling
        // back into view paints the image on its first frame; cache misses
        // still fall through to the .onAppear loader below.
        if case .image(let id, _, _) = entry.kind {
            _loadedImage = State(initialValue: store.imageCache.cachedImage(for: id))
        }
    }

    var body: some View {
        Button(action: onCopy) {
            HStack(alignment: .top, spacing: 12) {
                switch entry.kind {
                case .text(let text):
                    switch entry.smartType {
                    case .color(let color):
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color)
                            .frame(width: 24, height: 24)
                            .shadow(color: .black.opacity(0.1), radius: 2)
                    case .url:
                        Image(systemName: "link")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                    case .none:
                        Image(systemName: "doc.on.clipboard")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                    }

                    Text(text)
                        .lineLimit(4)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .image(let id, let width, let height):
                    if let image = loadedImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 88, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.08), lineWidth: 1)
                            }
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.gray.opacity(0.1))
                            .frame(width: 88, height: 64)
                            .overlay {
                                ProgressView()
                                    .scaleEffect(0.5)
                            }
                            .onAppear {
                                if loadedImage == nil {
                                    loadedImage = store.imageCache.image(for: id)
                                }
                            }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Image", systemImage: "photo.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("\(Int(width)) x \(Int(height))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .trailing, spacing: 8) {
                    Text(entry.createdAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if hovering {
                        HStack(spacing: 8) {
                            Button(action: onToggleFavorite) {
                                Image(systemName: entry.isFavorite ? "star.fill" : "star")
                            }
                            .buttonStyle(.bordered)
                            
                            if case .url(let url) = entry.smartType {
                                Button("Open") {
                                    NSWorkspace.shared.open(url)
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            Button("Copy", action: onCopy)
                                .buttonStyle(.borderedProminent)
                            Button("Delete", role: .destructive, action: onDelete)
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark ? [Color.white.opacity(0.08), Color.white.opacity(0.02)] : [Color.white.opacity(0.95), Color.gray.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                let highlighted = hovering || isSelected
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor :
                            (colorScheme == .dark
                                ? (highlighted ? Color.blue.opacity(0.4) : Color.white.opacity(0.1))
                                : (highlighted ? Color.blue.opacity(0.25) : Color.black.opacity(0.07))),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 12 : 6, y: 3)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

@MainActor
final class AutoPaster {
    static let shared = AutoPaster()
    private(set) var previousApp: NSRunningApplication?

    /// Must be called BEFORE ClipboardVault activates itself so frontmostApplication
    /// still points to the user's editor / browser / etc.
    func capturePreviousApp() {
        let me = NSRunningApplication.current
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != me.processIdentifier {
            previousApp = front
        }
    }

    func pasteToPreviousApp() {
        guard AXIsProcessTrusted() else { return }
        guard let prev = previousApp else { return }
        // Consume the capture so a later menubar-driven selection (no fresh
        // capturePreviousApp call) doesn't auto-paste into the stale app.
        previousApp = nil
        prev.activate()
        // Small delay so the OS finishes the activation hand-off before we
        // synthesise the keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.sendCmdV()
        }
    }

    /// Pops the standard macOS "grant Accessibility" dialog if the user has
    /// not yet authorised us. Safe to call repeatedly; the dialog only shows
    /// when permission is missing.
    @discardableResult
    static func ensureAccessibility() -> Bool {
        // Hard-coded value of kAXTrustedCheckOptionPrompt; the imported global
        // is `var` and trips Swift 6's concurrency-safety check.
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static func sendCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

@MainActor
enum WindowController {
    static let mainWindowTitle = "ClipboardVault"

    static func mainWindow() -> NSWindow? {
        NSApplication.shared.windows.first(where: { $0.title == mainWindowTitle })
    }

    static func hideMainWindow() {
        mainWindow()?.orderOut(nil)
    }

    static func showMainWindow() {
        if let window = mainWindow() {
            window.makeKeyAndOrderFront(nil)
        }
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }
}

struct AppInstaller {
    static func isBundle() -> Bool {
        return Bundle.main.bundleURL.path.hasSuffix(".app")
    }

    static func isRunningFromApplications() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let appsURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        guard let appsURL else { return false }
        return bundleURL.path.hasPrefix(appsURL.path)
    }
    
    static func moveToApplications() {
        let bundleURL = Bundle.main.bundleURL
        let appsURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        guard let appsURL else { return }
        
        let destinationURL = appsURL.appendingPathComponent(bundleURL.lastPathComponent)
        
        if bundleURL.path == destinationURL.path { return }
        
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.copyItem(at: bundleURL, to: destinationURL)
            
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: destinationURL, configuration: config) { _, error in
                if let error {
                    Log.installer.error("Failed to launch moved app: \(error.localizedDescription, privacy: .public)")
                } else {
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        } catch {
            Log.installer.error("Failed to move app to Applications: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct MainPanelView: View {
    @ObservedObject var store: ClipboardStore
    @Binding var toastText: String?

    @State private var selectedIndex: Int = 0
    @State private var keyMonitor: Any?
    @State private var toastTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled: Bool = false

    private func selectAndPaste(_ entry: ClipboardEntry) {
        guard store.copyBack(entry) else {
            showToast("Couldn't load that image")
            return
        }
        showToast("Copied to clipboard")
        WindowController.hideMainWindow()
        if autoPasteEnabled {
            AutoPaster.shared.pasteToPreviousApp()
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            if AppInstaller.isBundle() && !AppInstaller.isRunningFromApplications() {
                HStack {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("Di chuyển vào Applications")
                            .font(.headline)
                        Text("Để ứng dụng hoạt động ổn định và hỗ trợ khởi động cùng máy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Di chuyển") {
                        AppInstaller.moveToApplications()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color.yellow.opacity(0.15))
                .cornerRadius(10)
            }
            HStack {
                TextField("Search text...", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                Button("Clear All") {
                    store.clearAll()
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(store.filteredEntries.enumerated()), id: \.element.id) { idx, entry in
                            EntryCard(
                                store: store,
                                entry: entry,
                                isSelected: idx == selectedIndex,
                                onCopy: {
                                    selectAndPaste(entry)
                                },
                                onDelete: {
                                    store.remove(entry)
                                },
                                onToggleFavorite: {
                                    store.toggleFavorite(entry)
                                }
                            )
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selectedIndex) { newIndex in
                    let entries = store.filteredEntries
                    guard entries.indices.contains(newIndex) else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(entries[newIndex].id, anchor: .center)
                    }
                }
            }
        }
        .padding(18)
        .onAppear {
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: store.searchText) { _ in selectedIndex = 0 }
        .onChange(of: store.selectedFilter) { _ in selectedIndex = 0 }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // The local monitor fires for every window owned by our process
            // (including Settings). Without this guard, pressing Enter inside
            // a Settings text field would trigger paste-back, and Esc would
            // close the main window — neither makes sense from Settings.
            guard event.window === WindowController.mainWindow() else {
                return event
            }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// Returns true if the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        let entries = store.filteredEntries

        // Escape always closes window — works even from inside search field.
        if event.keyCode == 53 {
            WindowController.hideMainWindow()
            return true
        }

        // While typing in search box, only swallow nav keys; let characters through.
        let searchHasFocus = searchFocused
        let isNav = [125, 126, 36, 76].contains(event.keyCode) // ↓ ↑ Return KeypadEnter

        // Cmd+1..4 is reserved for filter switching (toolbar bindings); ignore
        // here so SwiftUI's toolbar shortcut wins.
        if event.modifierFlags.contains(.command) { return false }

        if searchHasFocus && !isNav { return false }

        switch event.keyCode {
        case 125: // down
            if !entries.isEmpty {
                selectedIndex = min(selectedIndex + 1, entries.count - 1)
            }
            return true
        case 126: // up
            selectedIndex = max(0, selectedIndex - 1)
            return true
        case 36, 76: // return / keypad enter
            if entries.indices.contains(selectedIndex) {
                selectAndPaste(entries[selectedIndex])
            }
            return true
        default:
            // Any other printable char while NOT focused on search → focus the
            // search field and forward the keystroke (type-to-search). Use
            // Character-level Unicode classification so Vietnamese diacritics
            // ("đ", "ă", "ư"…) and other non-ASCII letters work too.
            if !searchHasFocus,
               let chars = event.characters,
               !chars.isEmpty,
               chars.allSatisfy({ $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " " }) {
                searchFocused = true
                store.searchText.append(chars)
                return true
            }
            return false
        }
    }

    private func showToast(_ message: String) {
        // Cancel any in-flight dismiss task so it can't clear a toast that
        // belongs to a later showToast call.
        toastTask?.cancel()
        withAnimation {
            toastText = message
        }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation {
                    toastText = nil
                }
            }
        }
    }
}

struct QuickPanelView: View {
    @ObservedObject var store: ClipboardStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Quick Clipboard")
                    .font(.headline)
                Spacer()
                
                Button(action: {
                    store.clearAll()
                }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    if WindowController.mainWindow() == nil {
                        openWindow(id: "main")
                    }
                    WindowController.showMainWindow()
                }) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "power")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            ForEach(store.quickEntries) { entry in
                Button {
                    store.copyBack(entry)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: entry.isFavorite ? "star.fill" : "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(entry.isFavorite ? .yellow : .blue.opacity(0.45))
                        switch entry.kind {
                        case .text(let text):
                            Text(text)
                                .lineLimit(1)
                        case .image(_, let width, let height):
                            Text("Image \(Int(width))x\(Int(height))")
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}



struct ContentView: View {
    @ObservedObject var store: ClipboardStore

    @State private var toastText: String?
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: colorScheme == .dark ? [Color(red: 0.1, green: 0.11, blue: 0.15), Color(red: 0.07, green: 0.08, blue: 0.1)] : [Color(red: 0.95, green: 0.97, blue: 1.0), Color.white],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                MainPanelView(store: store, toastText: $toastText)

                if let toastText {
                    Text(toastText)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay {
                            Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1)
                        }
                        .padding(.top, 12)
                        .padding(.trailing, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: store.filteredEntries.count)
        .toolbar {
            ToolbarItemGroup {
                Button("All") { store.selectedFilter = .all }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Text") { store.selectedFilter = .text }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Images") { store.selectedFilter = .images }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Fav") { store.selectedFilter = .favorites }
                    .keyboardShortcut("4", modifiers: .command)
            }
        }
    }
}

struct SettingsView: View {
    @StateObject private var loginManager = LaunchAtLoginManager()
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled: Bool = false
    @AppStorage("maxEntries") private var maxEntries: Int = ClipboardStore.defaultMaxEntries
    @AppStorage("pollInterval") private var pollInterval: Double = ClipboardStore.defaultPollInterval

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            storageTab
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 320)
    }

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginManager.enabled },
                    set: { loginManager.setEnabled($0) }
                ))
                if let error = loginManager.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Paste behaviour") {
                Toggle("Auto-paste into previous app after selecting an entry",
                       isOn: $autoPasteEnabled)
                if autoPasteEnabled {
                    Button("Grant Accessibility permission…") {
                        AutoPaster.ensureAccessibility()
                    }
                    Text("Auto-paste needs Accessibility access in System Settings → Privacy & Security.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Text("Items copied from password managers and other apps that mark the clipboard as concealed or transient are automatically skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var storageTab: some View {
        Form {
            Section("History size") {
                Stepper("Maximum entries: \(maxEntries)", value: $maxEntries, in: 50...2000, step: 50)
            }
            Section("Capture") {
                VStack(alignment: .leading) {
                    Text("Polling interval: \(String(format: "%.1f", pollInterval))s")
                    Slider(value: $pollInterval, in: 0.3...5.0, step: 0.1)
                }
                Text("Lower = clipboard changes detected sooner; higher = less CPU. Takes effect after restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("ClipboardVault").font(.title2.bold())
            Text("Global hotkey: ⌘⇧V")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Filter shortcuts: ⌘1–4")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Navigate: ↑/↓ • Enter to paste • Esc to hide")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

@main
struct ClipboardVaultApp: App {
    @StateObject private var store = ClipboardStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("ClipboardVault", id: "main") {
            ContentView(store: store)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.accessory)
                    GlobalHotKeyManager.shared.register {
                        // Capture the user's app BEFORE we steal focus so we
                        // can auto-paste back into it later.
                        AutoPaster.shared.capturePreviousApp()
                        if WindowController.mainWindow() == nil {
                            openWindow(id: "main")
                        }
                        WindowController.showMainWindow()
                    }
                    // When launched from /Applications the user has already
                    // onboarded, so don't pop the main window — they expect a
                    // silent menubar app. Outside /Applications we keep the
                    // window visible so the "Move to Applications" banner is
                    // discoverable.
                    if AppInstaller.isBundle() && AppInstaller.isRunningFromApplications() {
                        DispatchQueue.main.async {
                            WindowController.hideMainWindow()
                        }
                    }
                }

        }

        Settings {
            SettingsView()
        }

        MenuBarExtra("ClipboardVault", systemImage: "clipboard") {
            QuickPanelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
