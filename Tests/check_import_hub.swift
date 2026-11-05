// Production UI stores against a deterministic API double; no user data/keychain.
import Foundation

actor HubTestAPI: ImportHubNetworking {
    private var history = (0..<25).map { _ in MacJobInfo(id: UUID(), status: "completed", counts: ["completed": 1], total_items: 1) }
    private var offsets: [Int] = []
    private var infoCalls = 0
    private var sourceCalls = 0
    private var failJobs = false
    private var failInfo = false
    private var cancelled = false
    let jobID = UUID()
    private let entries = (1...45).map { MacJobItem(id: UUID(), position: $0, status: "pending", title: "Fixture \($0)",
        progress: .init(phase: "queued", fraction: 0), error: nil, result: nil) }
    func calls() -> (jobs: [Int], info: Int, sources: Int) { (offsets, infoCalls, sourceCalls) }
    func failNextJobs() { failJobs = true }
    func failNextInfo() { failInfo = true }
    func prependJob() { history.insert(MacJobInfo(id: UUID(), status: "queued", counts: ["pending": 1], total_items: 1), at: 0) }
    func jobs(_ credentials: MacCredentials, offset: Int) async throws -> [MacJobInfo] {
        offsets.append(offset)
        try await Task.sleep(nanoseconds: 60_000_000)
        if failJobs { failJobs = false; throw MacConnectionError.unavailable }
        return Array(history.dropFirst(offset).prefix(20))
    }
    func sources(_ credentials: MacCredentials, offset: Int) async throws -> MacSourcePage {
        sourceCalls += 1
        try await Task.sleep(nanoseconds: 60_000_000)
        return MacSourcePage(assets: [MacImportSource(id: UUID(), title: "Fixture", format: "WAV", size: 100, available: true, can_import: true)], next_offset: nil)
    }
    func jobInfo(_ credentials: MacCredentials, jobID: UUID) async throws -> MacJobInfo {
        infoCalls += 1
        try await Task.sleep(nanoseconds: 60_000_000)
        if failInfo { failInfo = false; throw MacConnectionError.unavailable }
        return MacJobInfo(id: jobID, status: cancelled ? "cancelled" : "running", counts: [cancelled ? "cancelled" : "pending": 45], total_items: 45)
    }
    func jobItems(_ credentials: MacCredentials, jobID: UUID, offset: Int) async throws -> MacJobPage {
        MacJobPage(id: jobID, items: Array(entries.dropFirst(offset).prefix(20)), next_offset: offset + 20 < entries.count ? offset + 20 : nil)
    }
    func submit(_ credentials: MacCredentials, sources: [MacImportSource], quality: String, requestID: UUID) async throws -> MacJobInfo { throw MacConnectionError.invalidResponse }
    func cancelJob(_ credentials: MacCredentials, jobID: UUID) async throws { cancelled = true }
    func retryJob(_ credentials: MacCredentials, jobID: UUID) async throws { cancelled = false }
}

@MainActor func checkImportHubStores(_ credentials: MacCredentials) async throws {
    let api = HubTestAPI()
    let hub = ImportHubStore(api: api)
    hub.connect(credentials)
    await hub.loadJobs()
    precondition(hub.jobs.count == 20 && hub.moreJobs)
    await hub.loadJobs(more: true)
    precondition(hub.jobs.count == 25 && !hub.moreJobs)
    await hub.loadJobs()
    precondition(hub.jobs.count == 25 && !hub.moreJobs, "Polling page one must preserve the exhausted history")
    await api.prependJob(); await hub.loadJobs()
    precondition(hub.jobs.count == 26 && !hub.moreJobs)
    await hub.loadJobs(more: true)
    let lastOffset = await api.calls().jobs.last
    precondition(lastOffset == 26, "New arrivals must shift the next history offset")
    await api.failNextJobs(); await hub.loadJobs()
    precondition(hub.message != nil)
    await hub.loadJobs()
    precondition(hub.message == nil, "Recovered network errors must disappear")
    let before = await api.calls().jobs.count
    let first = Task { await hub.loadJobs() }
    while await api.calls().jobs.count == before { await Task.yield() }
    await hub.loadJobs(); await first.value
    let after = await api.calls().jobs.count
    precondition(after == before + 1, "Polling and manual refresh must not duplicate requests")

    let sources = Task { await hub.loadSources() }
    while await api.calls().sources == 0 { await Task.yield() }
    hub.connect(nil); await sources.value
    precondition(hub.sources.isEmpty && hub.jobs.isEmpty, "Old-device responses must never populate a removed connection")

    let info = try await api.jobInfo(credentials, jobID: api.jobID)
    let details = MacJobDetailsStore(job: info, credentials: credentials, api: api)
    await details.refresh()
    precondition(details.items.count == 20 && details.nextOffset == 20)
    await details.more(); await details.more()
    precondition(details.items.map(\.position) == Array(1...45) && details.nextOffset == nil)
    details.visible(details.items.last!); await details.refresh()
    precondition(details.items.count == 45 && details.nextOffset == nil)
    await api.failNextInfo(); await details.refresh()
    precondition(details.message != nil)
    await details.refresh()
    precondition(details.message == nil)
    let infoBefore = await api.calls().info
    let refreshing = Task { await details.refresh() }
    while await api.calls().info == infoBefore { await Task.yield() }
    await details.refresh(); await refreshing.value
    let infoAfter = await api.calls().info
    precondition(infoAfter == infoBefore + 1)
    await details.cancel(); precondition(details.info.status == "cancelled")
    await details.retry(); precondition(details.info.isRunning)
    print("PASS: import UI history pagination/new arrivals, cleared network errors, coalesced refreshes, stale-device rejection, title pagination and cancel/retry")
}
