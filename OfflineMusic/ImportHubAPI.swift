import Foundation

struct MacImportSource: Decodable, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let format: String
    let size: Int64?
    let available: Bool
    let can_import: Bool
    var importable: Bool { available && can_import && (size ?? 0) > 0 }
}
struct MacSourcePage: Decodable, Sendable { let assets: [MacImportSource]; let next_offset: Int? }
struct MacJobItem: Decodable, Identifiable, Sendable {
    struct Progress: Decodable, Sendable { let phase: String?; let fraction: Double? }
    struct Failure: Decodable, Sendable { let code: String }
    let id: UUID
    let position: Int
    let status: String
    let title: String?
    let progress: Progress
    let error: Failure?
    let result: MacAudioManifest?
    var retryable: Bool { ["failed", "cancelled", "interrupted", "unavailable"].contains(status) }
    var errorMessage: String? {
        guard let code = error?.code else { return nil }
        switch code {
        case "protected_media": return "Geschützte Medien werden nicht unterstützt."
        case "dependency_error": return "Auf dem Mac fehlt ein benötigtes Konvertierungswerkzeug."
        case "timeout": return "Das Zeitlimit wurde erreicht. Versuche es erneut."
        case "playlist_limit", "duration_limit": return "Die Quelle überschreitet die Verarbeitungsgrenzen des Companions."
        case "unavailable_entry": return "Dieser Titel ist nicht verfügbar."
        case "cancelled": return "Die Verarbeitung wurde abgebrochen."
        default: return "Die Quelle konnte auf dem Mac nicht vollständig verarbeitet werden (\(code))."
        }
    }
    var statusTitle: String {
        switch status {
        case "pending": return "Wartet"
        case "downloading": return "Quelle prüfen"
        case "converting": return "Konvertieren"
        case "validating": return "Datei prüfen"
        case "completed", "reused": return "Bereit zum Import"
        case "cancelled": return "Abgebrochen"
        case "failed", "interrupted", "unavailable": return "Nicht verarbeitet"
        default: return status
        }
    }
}
struct MacJobPage: Decodable, Sendable { let id: UUID; let items: [MacJobItem]; let next_offset: Int? }

protocol ImportHubNetworking: Sendable {
    func jobInfo(_ credentials: MacCredentials, jobID: UUID) async throws -> MacJobInfo
    func sources(_ credentials: MacCredentials, offset: Int) async throws -> MacSourcePage
    func jobs(_ credentials: MacCredentials, offset: Int) async throws -> [MacJobInfo]
    func jobItems(_ credentials: MacCredentials, jobID: UUID, offset: Int) async throws -> MacJobPage
    func submit(_ credentials: MacCredentials, sources: [MacImportSource], quality: String, requestID: UUID) async throws -> MacJobInfo
    func cancelJob(_ credentials: MacCredentials, jobID: UUID) async throws
    func retryJob(_ credentials: MacCredentials, jobID: UUID) async throws
}

extension MacCompanionAPI: ImportHubNetworking {
    func sources(_ credentials: MacCredentials, offset: Int) async throws -> MacSourcePage {
        let data = try await request(credentials.endpoint, fingerprint: credentials.fingerprint, path: "v1/assets", token: credentials.token,
            query: [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: String(offset))])
        guard let page = try? JSONDecoder().decode(MacSourcePage.self, from: data), page.assets.count <= 100 else { throw MacImportError.invalidManifest }
        return page
    }
    func jobs(_ credentials: MacCredentials, offset: Int) async throws -> [MacJobInfo] {
        struct Response: Decodable { let jobs: [MacJobInfo] }
        let data = try await request(credentials.endpoint, fingerprint: credentials.fingerprint, path: "v1/jobs", token: credentials.token,
            query: [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "offset", value: String(offset))])
        guard let page = try? JSONDecoder().decode(Response.self, from: data), page.jobs.count <= 20 else { throw MacImportError.invalidManifest }
        return page.jobs
    }
    func jobItems(_ credentials: MacCredentials, jobID: UUID, offset: Int) async throws -> MacJobPage {
        let data = try await request(credentials.endpoint, fingerprint: credentials.fingerprint, path: "v1/jobs/\(jobID.uuidString)", token: credentials.token, maximumBytes: 262144,
            query: [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "offset", value: String(offset))])
        guard let page = try? JSONDecoder().decode(MacJobPage.self, from: data), page.id == jobID, page.items.count <= 20 else { throw MacImportError.invalidManifest }
        return page
    }
    func submit(_ credentials: MacCredentials, sources: [MacImportSource], quality: String, requestID: UUID) async throws -> MacJobInfo {
        // This UI API accepts only operator-registered, device-owned file IDs.
        // YouTube search results/URLs have no conversion into this source type.
        guard !sources.isEmpty, sources.count <= 1000, sources.allSatisfy(\.importable), ["128K", "192K", "256K", "320K"].contains(quality) else { throw MacImportError.invalidManifest }
        struct Source: Encodable { let kind = "asset"; let id: UUID; let authorized = true }
        struct Submission: Encodable { let sources: [Source]; let quality: String; let request_id: UUID }
        let body = try JSONEncoder().encode(Submission(sources: sources.map { Source(id: $0.id) }, quality: quality, request_id: requestID))
        let data = try await request(credentials.endpoint, fingerprint: credentials.fingerprint, path: "v1/jobs", method: "POST", token: credentials.token,
            body: body, query: [URLQueryItem(name: "limit", value: "1")])
        guard let job = try? JSONDecoder().decode(MacJobInfo.self, from: data) else { throw MacImportError.invalidManifest }
        return job
    }
    func cancelJob(_ credentials: MacCredentials, jobID: UUID) async throws {
        _ = try await request(credentials.endpoint, fingerprint: credentials.fingerprint, path: "v1/jobs/\(jobID.uuidString)/cancel", method: "POST", token: credentials.token,
                              query: [URLQueryItem(name: "limit", value: "1")])
    }
    func retryJob(_ credentials: MacCredentials, jobID: UUID) async throws {
        _ = try await request(credentials.endpoint, fingerprint: credentials.fingerprint, path: "v1/jobs/\(jobID.uuidString)/retry", method: "POST", token: credentials.token,
            body: Data("{}".utf8), query: [URLQueryItem(name: "limit", value: "1")])
    }
}
