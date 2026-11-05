import Foundation
import Combine

@MainActor final class ImportHubStore: ObservableObject {
    @Published private(set) var sources: [MacImportSource] = []
    @Published private(set) var jobs: [MacJobInfo] = []
    @Published private(set) var selectedIDs = Set<UUID>()
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var moreSources = false
    @Published private(set) var moreJobs = false
    @Published private(set) var message: String?
    @Published private(set) var submittedJob: MacJobInfo?
    private var sourceOffset = 0
    private var jobOffset = 0
    private var loadingJobs = false
    private var credentials: MacCredentials?
    private var generation = UUID()
    private var draftID = UUID()
    private var draftSignature = ""
    private let api: any ImportHubNetworking
    init(api: any ImportHubNetworking = MacCompanionAPI()) { self.api = api }
    var selection: [MacImportSource] { sources.filter { selectedIDs.contains($0.id) && $0.importable } }
    func connect(_ credentials: MacCredentials?) {
        guard self.credentials != credentials else { return }
        generation = UUID(); self.credentials = credentials
        sources = []; jobs = []; selectedIDs = []; sourceOffset = 0; jobOffset = 0
        moreSources = false; moreJobs = false; isLoading = false; loadingJobs = false; isSubmitting = false; message = nil; submittedJob = nil
        draftSignature = ""; draftID = UUID()
    }
    func toggle(_ source: MacImportSource) {
        guard source.importable else { return }
        if selectedIDs.contains(source.id) { selectedIDs.remove(source.id) } else { selectedIDs.insert(source.id) }
    }
    func deselectAll() { selectedIDs = [] }
    func loadSources(reset: Bool = true, selectAll: Bool = false) async {
        guard let credentials, !isLoading else { return }
        let generation = generation
        isLoading = true; message = nil
        defer { if self.generation == generation { isLoading = false } }
        do {
            var offset = reset ? 0 : sourceOffset
            if reset { sources = []; selectedIDs = [] }
            repeat {
                let page = try await api.sources(credentials, offset: offset)
                guard !Task.isCancelled, self.generation == generation else { return }
                var seen = Set(sources.map(\.id))
                sources += page.assets.filter { seen.insert($0.id).inserted }
                sourceOffset = page.next_offset ?? sources.count
                moreSources = page.next_offset != nil
                if selectAll { selectedIDs.formUnion(page.assets.filter(\.importable).map(\.id)) }
                if sources.count >= 1000 {
                    moreSources = false
                    if page.next_offset != nil { message = "Pro Auftrag sind bis zu 1.000 bereitgestellte Dateien möglich." }
                    break
                }
                guard selectAll, let next = page.next_offset, next > offset else { break }
                offset = next
            } while !Task.isCancelled
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            message = describe(error)
        }
    }
    func selectAll() async {
        selectedIDs = Set(sources.filter(\.importable).map(\.id))
        if moreSources { await loadSources(reset: false, selectAll: true) }
    }
    func loadJobs(more: Bool = false) async {
        guard let credentials, !loadingJobs else { return }
        let generation = generation
        let offset = more ? jobOffset : 0
        loadingJobs = true
        defer { if self.generation == generation { loadingJobs = false } }
        do {
            let page = try await api.jobs(credentials, offset: offset)
            guard !Task.isCancelled, self.generation == generation else { return }
            if more {
                var seen = Set(jobs.map(\.id)); jobs += page.filter { seen.insert($0.id).inserted }
                jobOffset = offset + page.count; moreJobs = page.count == 20
            } else {
                let previousIDs = Set(jobs.map(\.id))
                let ids = Set(page.map(\.id)); jobs = page + jobs.filter { !ids.contains($0.id) }
                if jobOffset <= 20 { jobOffset = page.count; moreJobs = page.count == 20 }
                else {
                    // New jobs shift the existing history offset. Refreshing
                    // page one must not reopen an already exhausted history.
                    jobOffset += page.filter { !previousIDs.contains($0.id) }.count
                }
            }
            message = nil
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            message = describe(error)
        }
    }
    func submit(quality: String, target: MacImportTarget, importer: MacImportCoordinator) async {
        guard let credentials, !isSubmitting, !selection.isEmpty else { return }
        let selected = selection
        let signature = selected.map { $0.id.uuidString }.joined(separator: ",") + ":" + quality + ":" + String(describing: target)
        if draftSignature != signature { draftSignature = signature; draftID = UUID() }
        let generation = generation
        isSubmitting = true; message = nil; submittedJob = nil
        defer { if self.generation == generation { isSubmitting = false } }
        do {
            try importer.prepareSubmission(draftID, target: target)
            let job = try await api.submit(credentials, sources: selected, quality: quality, requestID: draftID)
            guard !Task.isCancelled, self.generation == generation else { return }
            submittedJob = job; jobs.removeAll { $0.id == job.id }; jobs.insert(job, at: 0)
            selectedIDs = []; draftSignature = ""; draftID = UUID()
            importer.refresh()
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            message = describe(error) + " Prüfe auch die Auftragsliste; ein erneuter Versuch mit derselben Auswahl verwendet dieselbe Auftragsanfrage."
        }
    }
    private func describe(_ error: Error) -> String {
        if error as? MacConnectionError == .server(404) { return "Aktualisiere den Companion auf dem Mac und starte ihn neu." }
        if error as? MacConnectionError == .server(409) { return "Die Quelle oder der Auftrag ist nicht mehr verfügbar. Aktualisiere die Liste." }
        return error.localizedDescription
    }
}

@MainActor final class MacJobDetailsStore: ObservableObject {
    @Published private(set) var items: [MacJobItem] = []
    @Published private(set) var nextOffset: Int?
    @Published private(set) var info: MacJobInfo
    @Published private(set) var message: String?
    @Published private(set) var isBusy = false
    private var visibleOffset = 0
    private var refreshing = false
    private let credentials: MacCredentials
    private let api: any ImportHubNetworking
    init(job: MacJobInfo, credentials: MacCredentials, api: any ImportHubNetworking = MacCompanionAPI()) {
        info = job; self.credentials = credentials; self.api = api
    }
    func visible(_ item: MacJobItem) { visibleOffset = max(0, (item.position - 1) / 20 * 20) }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let data = try await api.jobInfo(credentials, jobID: info.id)
            guard !Task.isCancelled else { return }; info = data
            try await load(offset: 0)
            if visibleOffset > 0 { try await load(offset: visibleOffset) }
            message = nil
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
    private func load(offset: Int) async throws {
        let page = try await api.jobItems(credentials, jobID: info.id, offset: offset)
        guard !Task.isCancelled else { return }
        let ids = Set(page.items.map(\.id)); items.removeAll { ids.contains($0.id) }; items += page.items
        items.sort { $0.position < $1.position }
        if offset == 0, items.count <= 20 { nextOffset = page.next_offset }
        else if offset >= items.count - page.items.count { nextOffset = page.next_offset }
    }
    func more() async {
        guard let offset = nextOffset, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { try await load(offset: offset); message = nil } catch { message = error.localizedDescription }
    }
    func cancel() async {
        guard !isBusy else { return }; isBusy = true; defer { isBusy = false }
        do { try await api.cancelJob(credentials, jobID: info.id); await refresh() } catch { message = error.localizedDescription }
    }
    func retry() async {
        guard !isBusy else { return }; isBusy = true; defer { isBusy = false }
        do { try await api.retryJob(credentials, jobID: info.id); await refresh() } catch { message = error.localizedDescription }
    }
}
