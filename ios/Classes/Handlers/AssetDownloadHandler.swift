import AVFoundation
import Flutter
import Foundation

/// Offline HLS downloads (encrypted .movpkg + persistent FairPlay keys).
///
/// Backed by a background `AVAssetDownloadURLSession`, so a started download
/// survives backgrounding and reattaches after a relaunch (tasks are matched
/// back by `taskDescription`). Delivered `.movpkg` bundles stay where the
/// system placed them; the index stores their path RELATIVE to the home
/// directory and re-anchors at read time, because the app container UUID (the
/// absolute prefix) changes across reinstalls/updates.
///
/// Exposed to Dart through the plugin-level channels
/// `better_native_video_player/downloads` (methods) and
/// `better_native_video_player/download_events` (events) — mirroring the
/// Android AssetDownloadManager. Key blobs are owned by
/// `PersistableKeyManager` and never cross the channel.
final class AssetDownloadHandler: NSObject {
    static let shared = AssetDownloadHandler()

    enum OfflineLicenseState {
        /// No DRM keys recorded for the download (clear content).
        case clear
        case valid
        case missing
        case expired
    }

    private struct DownloadEntry: Codable {
        var id: String
        var url: String
        /// Path of the delivered .movpkg relative to the home directory.
        var relativePath: String?
        /// "downloading" | "completed" | "failed"
        var state: String
        /// FairPlay key identifiers (skd://…) persisted for this download.
        var keyIds: [String]
        /// Backend-reported license expiry. AVFoundation only surfaces key
        /// expiry at key-use time, so expiry UX is driven from this value.
        var expiresAtMs: Int64?
        var sizeBytes: Int64?
    }

    private static let sessionIdentifier =
        "com.huddlecommunity.better_native_video_player.asset_downloads"

    private var index: [String: DownloadEntry] = [:]
    private var activeTasks: [String: AVAssetDownloadTask] = [:]
    private var keyManagers: [String: PersistableKeyManager] = [:]
    // Renewal key managers kept alive until every key was re-persisted.
    private var activeRenewals: [String: PersistableKeyManager] = [:]

    private var eventSink: FlutterEventSink?

    private lazy var downloadSession: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: .main
        )
    }()

    private override init() {
        super.init()
        loadIndex()
    }

    /// Reattaches to download tasks that survived a relaunch inside the
    /// background session. Called once from plugin registration.
    func restorePendingTasks() {
        downloadSession.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self = self else { return }
                for task in tasks {
                    guard let downloadTask = task as? AVAssetDownloadTask,
                          let id = downloadTask.taskDescription else { continue }
                    self.activeTasks[id] = downloadTask
                    npLog("📥 Offline: reattached to download task \(id)")
                }
            }
        }
    }

    // MARK: - Method channel

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "startDownload":
            handleStartDownload(args, result: result)
        case "cancelDownload", "removeDownload":
            // Cancel and remove are the same operation: stop the task, drop
            // the partial/complete movpkg, delete the persisted keys.
            handleRemoveDownload(args, result: result)
        case "getDownloads":
            result(index.values.map(downloadMap(for:)))
        case "getLicenseInfo":
            handleGetLicenseInfo(args, result: result)
        case "renewLicense":
            handleRenewLicense(args, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleStartDownload(_ args: [String: Any]?, result: @escaping FlutterResult) {
        guard let id = args?["id"] as? String,
              let urlString = args?["url"] as? String,
              let url = URL(string: urlString) else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "id and url are required", details: nil))
            return
        }

        if let entry = index[id], entry.state == "completed", resolvedLocation(for: entry) != nil {
            sendEvent(downloadMap(for: entry))
            result(nil)
            return
        }
        if activeTasks[id] != nil {
            // Already downloading; the original task's events cover this call.
            result(nil)
            return
        }

        var options: [String: Any] = [:]
        if let headers = args?["headers"] as? [String: String] {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)

        let drm = args?["drm"] as? [String: Any]
        if let drm = drm {
            let keyManager = PersistableKeyManager(mode: .download(config: drm))
            keyManager.onKeyPersisted = { [weak self] keyId in
                DispatchQueue.main.async { self?.recordPersistedKey(keyId, downloadId: id) }
            }
            keyManager.onKeyError = { [weak self] _, error in
                DispatchQueue.main.async { self?.failDownload(id: id, error: error) }
            }
            keyManager.attach(to: asset)
            keyManagers[id] = keyManager
        }

        guard let task = downloadSession.makeAssetDownloadTask(
            asset: asset,
            assetTitle: id,
            assetArtworkData: nil,
            options: nil
        ) else {
            keyManagers.removeValue(forKey: id)
            result(FlutterError(
                code: "DOWNLOAD_START_FAILED",
                message: "Could not create AVAssetDownloadTask (simulator has no download support)",
                details: nil
            ))
            return
        }

        task.taskDescription = id
        activeTasks[id] = task
        index[id] = DownloadEntry(
            id: id,
            url: urlString,
            relativePath: nil,
            state: "downloading",
            keyIds: [],
            expiresAtMs: (drm?["expiresAtMs"] as? NSNumber)?.int64Value,
            sizeBytes: nil
        )
        saveIndex()
        sendEvent(["id": id, "status": "queued", "bytesDownloaded": 0])
        task.resume()
        // The channel reply only acknowledges enqueueing; progress and the
        // terminal state stream over the event channel.
        result(nil)
    }

    private func handleRemoveDownload(_ args: [String: Any]?, result: @escaping FlutterResult) {
        guard let id = args?["id"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "id is required", details: nil))
            return
        }
        if let task = activeTasks.removeValue(forKey: id) {
            task.cancel()
        }
        keyManagers.removeValue(forKey: id)
        activeRenewals.removeValue(forKey: id)
        if let entry = index.removeValue(forKey: id) {
            deleteAssets(of: entry)
            saveIndex()
        }
        sendEvent(["id": id, "status": "removed", "bytesDownloaded": 0])
        result(nil)
    }

    private func handleGetLicenseInfo(_ args: [String: Any]?, result: @escaping FlutterResult) {
        guard let id = args?["id"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "id is required", details: nil))
            return
        }
        guard let entry = index[id] else {
            result(["valid": false])
            return
        }
        var response: [String: Any] = ["valid": licenseState(for: id) == .valid || licenseState(for: id) == .clear]
        if let expiresAtMs = entry.expiresAtMs {
            response["expiresAtMs"] = expiresAtMs
        }
        result(response)
    }

    private func handleRenewLicense(_ args: [String: Any]?, result: @escaping FlutterResult) {
        guard let id = args?["id"] as? String,
              let drm = args?["drm"] as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "id and drm are required", details: nil))
            return
        }
        guard let entry = index[id], !entry.keyIds.isEmpty else {
            result(FlutterError(code: "NO_LICENSE", message: "No offline license found for download \(id)", details: nil))
            return
        }
        if activeRenewals[id] != nil {
            result(FlutterError(code: "RENEW_IN_PROGRESS", message: "License renewal already running for \(id)", details: nil))
            return
        }

        let keyManager = PersistableKeyManager(mode: .download(config: drm))
        var remaining = Set(entry.keyIds)
        var completed = false
        let finish: (FlutterError?) -> Void = { [weak self] error in
            guard !completed else { return }
            completed = true
            self?.activeRenewals.removeValue(forKey: id)
            if let error = error {
                result(error)
            } else {
                self?.index[id]?.expiresAtMs = (drm["expiresAtMs"] as? NSNumber)?.int64Value
                self?.saveIndex()
                result(nil)
            }
        }
        keyManager.onKeyPersisted = { keyId in
            DispatchQueue.main.async {
                remaining.remove(keyId)
                if remaining.isEmpty { finish(nil) }
            }
        }
        keyManager.onKeyError = { _, error in
            DispatchQueue.main.async {
                finish(FlutterError(
                    code: "RENEW_FAILED",
                    message: "License renewal failed: \(error.localizedDescription)",
                    details: nil
                ))
            }
        }
        activeRenewals[id] = keyManager
        for keyId in entry.keyIds {
            keyManager.requestPersistableKey(keyId: keyId)
        }
    }

    // MARK: - Offline playback support

    /// The on-disk .movpkg URL of a completed download, or nil.
    func completedAssetURL(for id: String) -> URL? {
        guard let entry = index[id], entry.state == "completed" else { return nil }
        return resolvedLocation(for: entry)
    }

    func licenseState(for id: String) -> OfflineLicenseState {
        guard let entry = index[id] else { return .missing }
        if entry.keyIds.isEmpty { return .clear }
        for keyId in entry.keyIds where !PersistableKeyManager.hasPersistedKey(for: keyId) {
            return .missing
        }
        if let expiresAtMs = entry.expiresAtMs,
           expiresAtMs <= Int64(Date().timeIntervalSince1970 * 1000) {
            return .expired
        }
        return .valid
    }

    /// Whether the download carries FairPlay keys (playback then needs a
    /// `.playback`-mode PersistableKeyManager attached to its asset).
    func hasPersistedKeys(for id: String) -> Bool {
        !(index[id]?.keyIds.isEmpty ?? true)
    }

    // MARK: - Internals

    private func recordPersistedKey(_ keyId: String, downloadId: String) {
        guard var entry = index[downloadId] else { return }
        if !entry.keyIds.contains(keyId) {
            entry.keyIds.append(keyId)
            index[downloadId] = entry
            saveIndex()
        }
    }

    private func failDownload(id: String, error: Error) {
        guard let task = activeTasks.removeValue(forKey: id) else { return }
        task.cancel()
        keyManagers.removeValue(forKey: id)
        if let entry = index.removeValue(forKey: id) {
            deleteAssets(of: entry)
            saveIndex()
        }
        sendEvent([
            "id": id,
            "status": "failed",
            "bytesDownloaded": 0,
            "error": error.localizedDescription,
        ])
    }

    private func deleteAssets(of entry: DownloadEntry) {
        if let location = resolvedLocation(for: entry) {
            try? FileManager.default.removeItem(at: location)
        }
        for keyId in entry.keyIds {
            PersistableKeyManager.removePersistedKey(for: keyId)
        }
    }

    private func resolvedLocation(for entry: DownloadEntry) -> URL? {
        guard let relativePath = entry.relativePath else { return nil }
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func relativePath(for location: URL) -> String {
        let home = NSHomeDirectory()
        let path = location.path
        if path.hasPrefix(home) {
            return String(path.dropFirst(home.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        }
        return path
    }

    private func downloadMap(for entry: DownloadEntry) -> [String: Any] {
        var map: [String: Any] = [
            "id": entry.id,
            "status": entry.state,
            "bytesDownloaded": entry.sizeBytes ?? 0,
        ]
        if entry.state == "completed" { map["fraction"] = 1.0 }
        if let expiresAtMs = entry.expiresAtMs { map["licenseExpiresAtMs"] = expiresAtMs }
        return map
    }

    private func directorySize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            )
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Index persistence

    private static func indexFileURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("bnvp_offline_downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("index.json")
    }

    private func loadIndex() {
        guard let fileURL = try? Self.indexFileURL(),
              let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: DownloadEntry].self, from: data) else {
            return
        }
        index = entries
    }

    private func saveIndex() {
        guard let fileURL = try? Self.indexFileURL(),
              let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Events

    private func sendEvent(_ event: [String: Any]) {
        if Thread.isMainThread {
            eventSink?(event)
        } else {
            DispatchQueue.main.async { [weak self] in self?.eventSink?(event) }
        }
    }
}

// MARK: - FlutterStreamHandler

extension AssetDownloadHandler: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}

// MARK: - AVAssetDownloadDelegate

extension AssetDownloadHandler: AVAssetDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let loadedSeconds = loadedTimeRanges
            .map { CMTimeGetSeconds($0.timeRangeValue.duration) }
            .reduce(0, +)
        let expectedSeconds = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        var event: [String: Any] = [
            "id": id,
            "status": "downloading",
            "bytesDownloaded": assetDownloadTask.countOfBytesReceived,
        ]
        if expectedSeconds.isFinite, expectedSeconds > 0 {
            event["fraction"] = min(loadedSeconds / expectedSeconds, 1.0)
        }
        sendEvent(event)
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = assetDownloadTask.taskDescription else { return }
        guard index[id] != nil else {
            // Removed/canceled while the system was delivering the (partial)
            // movpkg — nothing references it, delete straight away.
            try? FileManager.default.removeItem(at: location)
            return
        }
        // Called before didCompleteWithError, including for failures (the
        // partial movpkg is delivered too); the entry only flips to completed
        // in didCompleteWithError.
        index[id]?.relativePath = relativePath(for: location)
        saveIndex()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let downloadTask = task as? AVAssetDownloadTask,
              let id = downloadTask.taskDescription else { return }
        activeTasks.removeValue(forKey: id)
        keyManagers.removeValue(forKey: id)

        guard var entry = index[id] else { return }

        if let error = error {
            let isCancellation = (error as NSError).code == NSURLErrorCancelled
            deleteAssets(of: entry)
            index.removeValue(forKey: id)
            saveIndex()
            if isCancellation {
                // handleRemoveDownload already emitted "removed"; a system
                // cancellation without one is close enough to removal too.
                sendEvent(["id": id, "status": "removed", "bytesDownloaded": 0])
            } else {
                sendEvent([
                    "id": id,
                    "status": "failed",
                    "bytesDownloaded": 0,
                    "error": error.localizedDescription,
                ])
            }
            return
        }

        guard let location = resolvedLocation(for: entry) else {
            index.removeValue(forKey: id)
            saveIndex()
            sendEvent([
                "id": id,
                "status": "failed",
                "bytesDownloaded": 0,
                "error": "Download finished but no asset was delivered",
            ])
            return
        }

        // Local media must never leak into iCloud backups.
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        var locationForBackupFlag = location
        try? locationForBackupFlag.setResourceValues(backupValues)

        entry.state = "completed"
        entry.sizeBytes = directorySize(of: location)
        index[id] = entry
        saveIndex()
        sendEvent([
            "id": id,
            "status": "completed",
            "fraction": 1.0,
            "bytesDownloaded": entry.sizeBytes ?? 0,
        ])
    }
}
