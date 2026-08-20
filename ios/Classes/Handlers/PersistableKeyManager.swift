import AVFoundation
import Foundation

/// FairPlay persistable content keys for offline downloads.
///
/// One instance per download task and per offline playback item (instances
/// each own their `AVContentKeySession`, so concurrent downloads with
/// different license tokens can never answer each other's key requests):
///
/// - `.download` mode runs the full SPC → CKC flow against the license server
///   (offline/persistent token in the config headers), converts the response
///   into a persistable key via `persistableContentKey(fromKeyVendorResponse:)`
///   and stores the blob under `Application Support/bnvp_offline_keys/`
///   (file-protected, excluded from iCloud backup). Key material never leaves
///   the native side.
/// - `.playback` mode answers every key request from the persisted blob and
///   never touches the network.
final class PersistableKeyManager: NSObject {
    enum Mode {
        /// Downloading/renewing: full license flow, persist resulting keys.
        case download(config: [String: Any])
        /// Offline playback: answer exclusively from persisted key blobs.
        case playback
    }

    private let mode: Mode
    private let session: AVContentKeySession
    private let queue = DispatchQueue(label: "com.better_native_video_player.offline_keys")

    private var certificateData: Data?
    private var certificateError: Error?
    private var certificateRequestInFlight = false
    private var pendingKeyRequests: [AVPersistableContentKeyRequest] = []

    /// Called (on the key queue) after a persistable key blob was written.
    var onKeyPersisted: ((_ keyId: String) -> Void)?
    /// Called (on the key queue) when a key request fails terminally.
    var onKeyError: ((_ keyId: String?, _ error: Error) -> Void)?

    init(mode: Mode) {
        self.mode = mode
        self.session = AVContentKeySession(keySystem: .fairPlayStreaming)
        super.init()
        session.setDelegate(self, queue: queue)
    }

    /// Registers [asset] with the key session so its key requests are routed
    /// through this manager. Must be called before the asset is used by an
    /// AVAssetDownloadTask (download) or AVPlayerItem (playback).
    func attach(to asset: AVURLAsset) {
        session.addContentKeyRecipient(asset)
    }

    /// Requests (or re-requests) the persistable key for [keyId] without any
    /// asset — used for license renewal. Results arrive via `onKeyPersisted`
    /// / `onKeyError`.
    func requestPersistableKey(keyId: String) {
        session.processContentKeyRequest(
            withIdentifier: keyId,
            initializationData: nil,
            options: nil
        )
    }

    // MARK: - Persisted key store

    /// `Application Support/bnvp_offline_keys`, created on demand and excluded
    /// from backup (offline licenses are device-bound; restoring them to
    /// another device would only produce undecryptable blobs).
    static func keysDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var directory = base.appendingPathComponent("bnvp_offline_keys", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        return directory
    }

    static func keyFileURL(for keyId: String) throws -> URL {
        let safeName = keyId
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? keyId
        return try keysDirectory().appendingPathComponent("\(safeName).key")
    }

    static func hasPersistedKey(for keyId: String) -> Bool {
        guard let url = try? keyFileURL(for: keyId) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func removePersistedKey(for keyId: String) {
        guard let url = try? keyFileURL(for: keyId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Config accessors (same keys as the streaming drmConfig)

    private var config: [String: Any] {
        if case .download(let config) = mode { return config }
        return [:]
    }

    private var licenseUrl: URL? {
        (config["licenseUrl"] as? String).flatMap(URL.init(string:))
    }

    private var certificateUrl: URL? {
        (config["certificateUrl"] as? String).flatMap(URL.init(string:))
    }

    private var licenseHeaders: [String: String]? {
        config["headers"] as? [String: String]
    }

    private var certificateEncoding: String {
        (config["certificateEncoding"] as? String)?.lowercased() ?? "binary"
    }

    private var licenseRequestFormat: String {
        (config["licenseRequestFormat"] as? String)?.lowercased() ?? "binary"
    }

    private var licenseResponseEncoding: String {
        (config["licenseResponseEncoding"] as? String)?.lowercased() ?? "binary"
    }

    // MARK: - Identifier helpers

    private func keyIdentifierString(for keyRequest: AVContentKeyRequest) -> String? {
        if let value = keyRequest.identifier as? String { return value }
        if let url = keyRequest.identifier as? URL { return url.absoluteString }
        if let data = keyRequest.identifier as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// SPC content identifier: the `skd://` identifier with the scheme
    /// stripped, UTF-8 encoded (same convention as the streaming handler).
    private func contentIdentifierData(from keyId: String) -> Data? {
        let skdPrefix = "skd://"
        let contentIdentifier: String
        if keyId.lowercased().hasPrefix(skdPrefix) {
            contentIdentifier = String(keyId.dropFirst(skdPrefix.count))
        } else {
            contentIdentifier = keyId
        }
        guard !contentIdentifier.isEmpty else { return nil }
        return contentIdentifier.data(using: .utf8)
    }

    private func keyError(_ message: String) -> NSError {
        NSError(
            domain: "PersistableKeyManager",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

// MARK: - AVContentKeySessionDelegate

extension PersistableKeyManager: AVContentKeySessionDelegate {
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        // Both modes escalate to a persistable request: downloads to create
        // the blob, playback to be allowed to answer with the stored blob.
        do {
            try keyRequest.respondByRequestingPersistableContentKeyRequestAndReturnError()
        } catch {
            npLog("🔐 Offline DRM: cannot escalate to persistable key request: \(error.localizedDescription)")
            keyRequest.processContentKeyResponseError(error)
            onKeyError?(keyIdentifierString(for: keyRequest), error)
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequest: AVPersistableContentKeyRequest
    ) {
        guard let keyId = keyIdentifierString(for: keyRequest) else {
            let error = keyError("FairPlay key request has no usable identifier")
            keyRequest.processContentKeyResponseError(error)
            onKeyError?(nil, error)
            return
        }

        switch mode {
        case .playback:
            respondFromPersistedKey(keyId: keyId, keyRequest: keyRequest)
        case .download:
            createAndPersistKey(keyId: keyId, keyRequest: keyRequest)
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didUpdatePersistableContentKey persistableContentKey: Data,
        forContentKeyIdentifier keyIdentifier: Any
    ) {
        // The system can hand back an updated (e.g. expiry-refreshed) blob
        // during playback; persist it so the newest key survives.
        let keyId: String?
        if let value = keyIdentifier as? String {
            keyId = value
        } else if let url = keyIdentifier as? URL {
            keyId = url.absoluteString
        } else {
            keyId = nil
        }
        guard let keyId, let fileURL = try? Self.keyFileURL(for: keyId) else { return }
        do {
            try persistableContentKey.write(to: fileURL, options: .atomic)
            npLog("🔐 Offline DRM: updated persisted key for \(keyId)")
        } catch {
            npLog("🔐 Offline DRM: failed to update persisted key: \(error.localizedDescription)")
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        contentKeyRequest keyRequest: AVContentKeyRequest,
        didFailWithError err: Error
    ) {
        npLog("🔐 Offline DRM: key request failed: \(err.localizedDescription)")
        onKeyError?(keyIdentifierString(for: keyRequest), err)
    }

    // MARK: - Playback

    private func respondFromPersistedKey(keyId: String, keyRequest: AVPersistableContentKeyRequest) {
        guard let fileURL = try? Self.keyFileURL(for: keyId),
              let keyData = try? Data(contentsOf: fileURL) else {
            let error = keyError("No persisted offline key for \(keyId)")
            npLog("🔐 Offline DRM: \(error.localizedDescription)")
            keyRequest.processContentKeyResponseError(error)
            onKeyError?(keyId, error)
            return
        }
        let response = AVContentKeyResponse(fairPlayStreamingKeyResponseData: keyData)
        keyRequest.processContentKeyResponse(response)
        npLog("🔐 Offline DRM: answered key request for \(keyId) from persisted blob")
    }

    // MARK: - Download

    private func createAndPersistKey(keyId: String, keyRequest: AVPersistableContentKeyRequest) {
        if let certificateError = certificateError {
            keyRequest.processContentKeyResponseError(certificateError)
            onKeyError?(keyId, certificateError)
            return
        }
        guard let certificateData = certificateData else {
            pendingKeyRequests.append(keyRequest)
            ensureCertificate()
            return
        }
        guard let contentIdentifier = contentIdentifierData(from: keyId) else {
            let error = keyError("FairPlay key identifier is empty")
            keyRequest.processContentKeyResponseError(error)
            onKeyError?(keyId, error)
            return
        }

        keyRequest.makeStreamingContentKeyRequestData(
            forApp: certificateData,
            contentIdentifier: contentIdentifier,
            options: nil
        ) { [weak self] spcData, error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    keyRequest.processContentKeyResponseError(error)
                    self.onKeyError?(keyId, error)
                    return
                }
                guard let spcData = spcData else {
                    let error = self.keyError("SPC generation returned no data")
                    keyRequest.processContentKeyResponseError(error)
                    self.onKeyError?(keyId, error)
                    return
                }
                self.requestLicense(spcData: spcData, keyId: keyId, keyRequest: keyRequest)
            }
        }
    }

    private func requestLicense(
        spcData: Data,
        keyId: String,
        keyRequest: AVPersistableContentKeyRequest
    ) {
        guard let licenseUrl = licenseUrl else {
            let error = keyError("License URL is required for offline FairPlay")
            keyRequest.processContentKeyResponseError(error)
            onKeyError?(keyId, error)
            return
        }

        var request = URLRequest(url: licenseUrl)
        request.httpMethod = "POST"
        switch licenseRequestFormat {
        case "base64form":
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            guard let encodedSpc = spcData.base64EncodedString()
                .addingPercentEncoding(withAllowedCharacters: allowed),
                let body = "spc=\(encodedSpc)".data(using: .utf8) else {
                let error = keyError("Could not encode FairPlay SPC form body")
                keyRequest.processContentKeyResponseError(error)
                onKeyError?(keyId, error)
                return
            }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        default:
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = spcData
        }
        licenseHeaders?.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    keyRequest.processContentKeyResponseError(error)
                    self.onKeyError?(keyId, error)
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let data = data, !data.isEmpty else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let error = self.keyError("Offline license request failed (status \(statusCode))")
                    keyRequest.processContentKeyResponseError(error)
                    self.onKeyError?(keyId, error)
                    return
                }
                do {
                    let ckcData = try self.decode(
                        data,
                        encoding: self.licenseResponseEncoding,
                        label: "FairPlay CKC"
                    )
                    // The CKC of an offline scenario embeds the offline key
                    // expiry; converting it produces the device-bound blob we
                    // persist and later answer playback requests from.
                    let persistableKeyData = try keyRequest.persistableContentKey(
                        fromKeyVendorResponse: ckcData,
                        options: nil
                    )
                    let fileURL = try Self.keyFileURL(for: keyId)
                    try persistableKeyData.write(to: fileURL, options: .atomic)
                    try? FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: fileURL.path
                    )
                    npLog("🔐 Offline DRM: persisted key for \(keyId)")
                    self.onKeyPersisted?(keyId)
                    let response = AVContentKeyResponse(
                        fairPlayStreamingKeyResponseData: persistableKeyData
                    )
                    keyRequest.processContentKeyResponse(response)
                } catch {
                    npLog("🔐 Offline DRM: persisting key failed: \(error.localizedDescription)")
                    keyRequest.processContentKeyResponseError(error)
                    self.onKeyError?(keyId, error)
                }
            }
        }.resume()
    }

    // MARK: - Certificate

    private func ensureCertificate() {
        guard !certificateRequestInFlight else { return }
        guard let certificateUrl = certificateUrl else {
            finishCertificateFetch(.failure(keyError("Certificate URL is required for offline FairPlay")))
            return
        }
        certificateRequestInFlight = true

        var request = URLRequest(url: certificateUrl)
        request.httpMethod = "GET"
        licenseHeaders?.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            self.queue.async {
                self.certificateRequestInFlight = false
                if let error = error {
                    self.finishCertificateFetch(.failure(error))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let data = data, !data.isEmpty else {
                    self.finishCertificateFetch(
                        .failure(self.keyError("Failed to fetch FairPlay certificate"))
                    )
                    return
                }
                do {
                    let decoded = try self.decode(
                        data,
                        encoding: self.certificateEncoding,
                        label: "FairPlay certificate"
                    )
                    self.finishCertificateFetch(.success(decoded))
                } catch {
                    self.finishCertificateFetch(.failure(error))
                }
            }
        }.resume()
    }

    private func finishCertificateFetch(_ result: Result<Data, Error>) {
        let pending = pendingKeyRequests
        pendingKeyRequests.removeAll()
        switch result {
        case .success(let data):
            certificateData = data
            certificateError = nil
            for request in pending {
                if let keyId = keyIdentifierString(for: request) {
                    createAndPersistKey(keyId: keyId, keyRequest: request)
                }
            }
        case .failure(let error):
            certificateError = error
            for request in pending {
                request.processContentKeyResponseError(error)
                onKeyError?(keyIdentifierString(for: request), error)
            }
        }
    }

    private func decode(_ data: Data, encoding: String, label: String) throws -> Data {
        guard encoding == "base64" else { return data }
        guard let encodedValue = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let decodedData = Data(base64Encoded: encodedValue),
              !decodedData.isEmpty else {
            throw keyError("Invalid Base64-encoded \(label) response")
        }
        return decodedData
    }
}
