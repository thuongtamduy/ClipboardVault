import SwiftUI
import AppKit
import Carbon.HIToolbox
import SQLite3
import ServiceManagement

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ClipboardKind: Equatable {
    case text(String)
    case image(id: UUID, width: Double, height: Double)
}

struct ClipboardEntry: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let kind: ClipboardKind
    var isFavorite: Bool

    init(id: UUID = UUID(), createdAt: Date = Date(), kind: ClipboardKind, isFavorite: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.isFavorite = isFavorite
    }
}

extension ClipboardEntry {
    enum SmartType {
        case url(URL)
        case color(Color)
        case none
    }
    
    var smartType: SmartType {
        guard case .text(let text) = kind else { return .none }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Color check
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
        
        // URL check
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

    init() {
        openDatabase()
        createTableIfNeeded()
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
            print("Failed to upsert entry! Error: \(errorMsg)")
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
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("ClipboardVault", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("clipboard.sqlite").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            print("Failed to open database at: \(path)")
        } else {
            print("Database opened successfully at: \(path)")
            // Enable WAL mode for better concurrency
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        }
    }

    private func createTableIfNeeded() {
        guard let db else { return }
        let sql = """
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
        """
        sqlite3_exec(db, sql, nil, nil, nil)
        
        // Try to add columns if they don't exist (for existing databases)
        sqlite3_exec(db, "ALTER TABLE clipboard_entries ADD COLUMN image_width REAL;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE clipboard_entries ADD COLUMN image_height REAL;", nil, nil, nil)
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
    private let maxEntries = 200
    let persistence = ClipboardPersistence()

    init() {
        entries = persistence.loadEntries()
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

        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return byType
        }
        let key = searchText.lowercased()
        return byType.filter { entry in
            switch entry.kind {
            case .text(let text):
                return text.lowercased().contains(key)
            case .image:
                return "image photo screenshot".contains(key)
            }
        }
    }

    var quickEntries: [ClipboardEntry] {
        let sortedByDate = entries.sorted { $0.createdAt > $1.createdAt }
        return Array(sortedByDate.prefix(20))
    }

    func startMonitoring() {
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func copyBack(_ entry: ClipboardEntry) {
        pasteboard.clearContents()
        switch entry.kind {
        case .text(let value):
            pasteboard.setString(value, forType: .string)
        case .image(let id, _, _):
            if let data = persistence.loadImageData(id: id),
               let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        }
    }

    func clearAll() {
        entries.removeAll()
        persistence.clearAll()
    }

    func remove(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        persistence.delete(id: entry.id)
    }

    func toggleFavorite(_ entry: ClipboardEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx].isFavorite.toggle()
        persistence.updateFavorite(id: entries[idx].id, isFavorite: entries[idx].isFavorite)
    }

    private func checkClipboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

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
            let signature = "image:\(tiffData.hashValue)"
            guard signature != lastSignature else { return }
            lastSignature = signature
            
            let id = UUID()
            insert(.image(id: id, width: image.size.width, height: image.size.height), imageData: tiffData)
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
        }
        persistence.trimToMax(maxEntries)
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
                print("Hotkey Cmd+Shift+V triggered!")
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
    @ObservedObject var loginManager: LaunchAtLoginManager

    var body: some View {
        VStack(spacing: 10) {
            Toggle("Launch at Login", isOn: Binding(
                get: { loginManager.enabled },
                set: { loginManager.setEnabled($0) }
            ))
            .toggleStyle(.switch)

            if let error = loginManager.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            List(SidebarFilter.allCases, selection: $store.selectedFilter) { filter in
                Label(filter.rawValue, systemImage: filter.icon)
                    .tag(filter)
            }
            .listStyle(.sidebar)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }
}

struct EntryCard: View {
    @ObservedObject var store: ClipboardStore
    let entry: ClipboardEntry
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onToggleFavorite: () -> Void

    @State private var hovering = false
    @State private var loadedImage: NSImage?
    @Environment(\.colorScheme) var colorScheme

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
                                Task {
                                    if let data = store.persistence.loadImageData(id: id) {
                                        let img = NSImage(data: data)
                                        await MainActor.run {
                                            loadedImage = img
                                        }
                                    }
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
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(colorScheme == .dark ? (hovering ? Color.blue.opacity(0.4) : Color.white.opacity(0.1)) : (hovering ? Color.blue.opacity(0.25) : Color.black.opacity(0.07)), lineWidth: 1)
            }
            .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 12 : 6, y: 3)
            .animation(.easeOut(duration: 0.18), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
                    print("Failed to launch moved app: \(error.localizedDescription)")
                } else {
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        } catch {
            print("Failed to move app to Applications: \(error.localizedDescription)")
        }
    }
}

struct MainPanelView: View {
    @ObservedObject var store: ClipboardStore
    @Binding var toastText: String?

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
                Button("Clear All") {
                    store.clearAll()
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.filteredEntries) { entry in
                        EntryCard(
                            store: store,
                            entry: entry,
                            onCopy: {
                                store.copyBack(entry)
                                showToast("Copied to clipboard")
                            },
                            onDelete: {
                                store.remove(entry)
                            },
                            onToggleFavorite: {
                                store.toggleFavorite(entry)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
    }

    private func showToast(_ message: String) {
        withAnimation {
            toastText = message
        }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
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
                    if let window = NSApplication.shared.windows.first(where: { $0.title == "ClipboardVault" }) {
                        window.makeKeyAndOrderFront(nil)
                        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                    } else {
                        openWindow(id: "main")
                        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                    }
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
    @ObservedObject var loginManager: LaunchAtLoginManager

    @State private var toastText: String?
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, loginManager: loginManager)
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

@main
struct ClipboardVaultApp: App {
    @StateObject private var store = ClipboardStore()
    @StateObject private var loginManager = LaunchAtLoginManager()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("ClipboardVault", id: "main") {
            ContentView(store: store, loginManager: loginManager)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.accessory)
                    GlobalHotKeyManager.shared.register {
                        print("Activation handler called!")
                        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                        if let window = NSApplication.shared.windows.first(where: { $0.title == "ClipboardVault" }) {
                            print("Window found, bringing to front.")
                            window.makeKeyAndOrderFront(nil)
                            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                        } else {
                            print("No window found! Opening window.")
                            openWindow(id: "main")
                            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                        }
                    }
                }

        }

        MenuBarExtra("ClipboardVault", systemImage: "clipboard") {
            QuickPanelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
