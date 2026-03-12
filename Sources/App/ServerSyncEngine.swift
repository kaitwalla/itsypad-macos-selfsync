import Foundation
import os.log

final class ServerSyncEngine: ObservableObject {
    static let shared = ServerSyncEngine()

    enum State: Equatable {
        case disabled
        case syncing
        case idle
        case error(String)
    }

    @Published private(set) var state: State = .disabled

    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.nickustinov.itsypad", category: "ServerSync")

    private static let urlKey = "serverSyncURL"
    private static let tokenKey = "serverSyncToken"
    private static let lastSyncKey = "serverSyncLastSync"

    var serverURL: String {
        get { defaults.string(forKey: Self.urlKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.urlKey) }
    }

    var serverToken: String {
        get { defaults.string(forKey: Self.tokenKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.tokenKey) }
    }

    private var lastSyncTime: String? {
        get { defaults.string(forKey: Self.lastSyncKey) }
        set { defaults.set(newValue, forKey: Self.lastSyncKey) }
    }

    private var syncTimer: Timer?
    private var pushDebounceWork: DispatchWorkItem?
    private var pendingUpsertIDs: Set<UUID> = []
    private var pendingDeleteIDs: Set<UUID> = []
    private var pendingClipboardUpsertIDs: Set<UUID> = []
    private var pendingClipboardDeleteIDs: Set<UUID> = []
    private var isRunning = false

    // MARK: - Public API

    func startIfEnabled() {
        guard SettingsStore.shared.serverSyncEnabled else { return }
        start()
    }

    func start() {
        guard !serverURL.isEmpty, !serverToken.isEmpty else {
            state = .error("Missing URL or token")
            return
        }
        isRunning = true
        state = .idle
        startSyncTimer()
        Task { await performSync() }
        logger.info("ServerSyncEngine started")
    }

    func stop() {
        isRunning = false
        syncTimer?.invalidate()
        syncTimer = nil
        pushDebounceWork?.cancel()
        pushDebounceWork = nil
        pendingUpsertIDs.removeAll()
        pendingDeleteIDs.removeAll()
        pendingClipboardUpsertIDs.removeAll()
        pendingClipboardDeleteIDs.removeAll()
        state = .disabled
        logger.info("ServerSyncEngine stopped")
    }

    func recordChanged(_ id: UUID) {
        guard isRunning else { return }
        pendingDeleteIDs.remove(id)
        pendingUpsertIDs.insert(id)
        scheduleFlush()
    }

    func recordDeleted(_ id: UUID) {
        guard isRunning else { return }
        pendingUpsertIDs.remove(id)
        pendingDeleteIDs.insert(id)
        scheduleFlush()
    }

    func clipboardChanged(_ id: UUID) {
        guard isRunning else { return }
        pendingClipboardDeleteIDs.remove(id)
        pendingClipboardUpsertIDs.insert(id)
        scheduleFlush()
    }

    func clipboardDeleted(_ id: UUID) {
        guard isRunning else { return }
        pendingClipboardUpsertIDs.remove(id)
        pendingClipboardDeleteIDs.insert(id)
        scheduleFlush()
    }

    func fetchChanges() {
        guard isRunning else { return }
        Task { await performSync() }
    }

    /// Test connection to the server. Returns nil on success, or an error message.
    func testConnection() async -> String? {
        guard !serverURL.isEmpty else { return "No server URL" }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        guard let url = URL(string: "\(base)/api/ping") else { return "Invalid URL" }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "Invalid response" }
            guard http.statusCode == 200 else { return "HTTP \(http.statusCode)" }

            struct PingResponse: Decodable { let ok: Bool }
            let ping = try JSONDecoder().decode(PingResponse.self, from: data)
            return ping.ok ? nil : "Server returned ok=false"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Private

    private func scheduleFlush() {
        pushDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.performSync() }
        }
        pushDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.performSync() }
        }
    }

    private func performSync() async {
        guard isRunning else { return }

        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        guard let url = URL(string: "\(base)/api/sync") else {
            await MainActor.run { state = .error("Invalid URL") }
            return
        }

        await MainActor.run { state = .syncing }

        // Gather pending changes
        let tabUpsertIDs = await MainActor.run { () -> Set<UUID> in
            let ids = pendingUpsertIDs
            pendingUpsertIDs.removeAll()
            return ids
        }
        let tabDeleteIDs = await MainActor.run { () -> Set<UUID> in
            let ids = pendingDeleteIDs
            pendingDeleteIDs.removeAll()
            return ids
        }
        let clipUpsertIDs = await MainActor.run { () -> Set<UUID> in
            let ids = pendingClipboardUpsertIDs
            pendingClipboardUpsertIDs.removeAll()
            return ids
        }
        let clipDeleteIDs = await MainActor.run { () -> Set<UUID> in
            let ids = pendingClipboardDeleteIDs
            pendingClipboardDeleteIDs.removeAll()
            return ids
        }

        // Build tab upserts
        let formatter = ISO8601DateFormatter()
        let tabUpserts: [[String: Any]] = await MainActor.run {
            tabUpsertIDs.compactMap { id in
                guard let tab = TabStore.shared.tabs.first(where: { $0.id == id && $0.fileURL == nil }) else { return nil }
                return [
                    "id": tab.id.uuidString,
                    "name": tab.name,
                    "content": tab.content,
                    "language": tab.language,
                    "languageLocked": tab.languageLocked,
                    "lastModified": formatter.string(from: tab.lastModified),
                ] as [String: Any]
            }
        }

        // Build clipboard upserts
        let clipUpserts: [[String: Any]] = await MainActor.run {
            clipUpsertIDs.compactMap { id in
                guard let entry = ClipboardStore.shared.entries.first(where: { $0.id == id && $0.kind == .text }),
                      let text = entry.text else { return nil }
                return [
                    "id": entry.id.uuidString,
                    "text": text,
                    "timestamp": formatter.string(from: entry.timestamp),
                ] as [String: Any]
            }
        }

        let body: [String: Any] = [
            "since": lastSyncTime ?? "1970-01-01T00:00:00Z",
            "changes": [
                "tabs": [
                    "upsert": tabUpserts,
                    "delete": tabDeleteIDs.map { $0.uuidString },
                ],
                "clipboard": [
                    "upsert": clipUpserts,
                    "delete": clipDeleteIDs.map { $0.uuidString },
                ],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                await handleSyncError("Invalid response", tabUpsertIDs: tabUpsertIDs, tabDeleteIDs: tabDeleteIDs, clipUpsertIDs: clipUpsertIDs, clipDeleteIDs: clipDeleteIDs)
                return
            }
            guard http.statusCode == 200 else {
                await handleSyncError("HTTP \(http.statusCode)", tabUpsertIDs: tabUpsertIDs, tabDeleteIDs: tabDeleteIDs, clipUpsertIDs: clipUpsertIDs, clipDeleteIDs: clipDeleteIDs)
                return
            }

            let syncResponse = try JSONDecoder().decode(SyncResponse.self, from: data)
            await applySyncResponse(syncResponse)
            logger.info("Sync complete: \(syncResponse.changes.tabs.upsert.count) tabs, \(syncResponse.changes.clipboard.upsert.count) clipboard")
        } catch {
            await handleSyncError(error.localizedDescription, tabUpsertIDs: tabUpsertIDs, tabDeleteIDs: tabDeleteIDs, clipUpsertIDs: clipUpsertIDs, clipDeleteIDs: clipDeleteIDs)
        }
    }

    private func handleSyncError(_ message: String, tabUpsertIDs: Set<UUID>, tabDeleteIDs: Set<UUID>, clipUpsertIDs: Set<UUID>, clipDeleteIDs: Set<UUID>) async {
        logger.error("Sync failed: \(message)")
        // Put pending changes back so they retry next cycle
        await MainActor.run {
            pendingUpsertIDs.formUnion(tabUpsertIDs)
            pendingDeleteIDs.formUnion(tabDeleteIDs)
            pendingClipboardUpsertIDs.formUnion(clipUpsertIDs)
            pendingClipboardDeleteIDs.formUnion(clipDeleteIDs)
            state = .error(message)
        }
    }

    private func applySyncResponse(_ response: SyncResponse) async {
        let formatter = ISO8601DateFormatter()

        await MainActor.run {
            // Apply tab upserts from server
            for tab in response.changes.tabs.upsert {
                let lastModified = formatter.date(from: tab.last_modified) ?? Date()
                let record = CloudTabRecord(
                    id: UUID(uuidString: tab.id) ?? UUID(),
                    name: tab.name,
                    content: tab.content,
                    language: tab.language,
                    languageLocked: tab.language_locked != 0,
                    lastModified: lastModified
                )
                TabStore.shared.applyCloudTab(record)
            }

            // Apply tab deletes from server
            for idString in response.changes.tabs.delete {
                if let uuid = UUID(uuidString: idString) {
                    TabStore.shared.removeCloudTab(id: uuid)
                }
            }

            // Apply clipboard upserts from server
            for entry in response.changes.clipboard.upsert {
                let timestamp = formatter.date(from: entry.timestamp) ?? Date()
                let record = CloudClipboardRecord(
                    id: UUID(uuidString: entry.id) ?? UUID(),
                    text: entry.text,
                    timestamp: timestamp
                )
                ClipboardStore.shared.applyCloudClipboardEntry(record)
            }

            // Apply clipboard deletes from server
            for idString in response.changes.clipboard.delete {
                if let uuid = UUID(uuidString: idString) {
                    ClipboardStore.shared.removeCloudClipboardEntry(id: uuid)
                }
            }

            lastSyncTime = response.serverTime
            TabStore.shared.lastICloudSync = Date()
            state = .idle
        }
    }
}

// MARK: - Response types

private struct SyncResponse: Decodable {
    let serverTime: String
    let changes: SyncChanges
}

private struct SyncChanges: Decodable {
    let tabs: TabChanges
    let clipboard: ClipboardChanges
}

private struct TabChanges: Decodable {
    let upsert: [TabRecord]
    let delete: [String]
}

private struct ClipboardChanges: Decodable {
    let upsert: [ClipboardRecord]
    let delete: [String]
}

private struct TabRecord: Decodable {
    let id: String
    let name: String
    let content: String
    let language: String
    let language_locked: Int
    let last_modified: String
}

private struct ClipboardRecord: Decodable {
    let id: String
    let text: String
    let timestamp: String
}
