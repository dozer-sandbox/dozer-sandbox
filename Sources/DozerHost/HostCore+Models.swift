import Foundation
import DozerKit

/// 618: the host's `models` op — each model source's list (`ModelLists`). A gateway's public list is read here, on the
/// Mac, when it is due (a day old, not right after a failure) or asked for; one read per gateway at a time; a failure
/// keeps the last list and is recorded, never said to a person (offline is normal).
extension HostCore {
    func modelLists(source: String?, refresh: Bool, now: Date = Date()) async throws -> [ModelList] {
        let sources: [String]
        if let s = source {
            guard ModelSources.ids.contains(s) else { throw HostError(.invalid, "models: \(s) is not a provider or gateway (\(ModelSources.ids.joined(separator: ", ")))") }
            sources = [s]
        } else {
            sources = ModelSources.ids
        }
        if modelListFetcher.read != nil {
            let records = ModelLists.all(store)
            for s in sources where ModelLists.fetched(s) && ModelLists.due(records[s], now: now, force: refresh) {
                await readModelList(s)
            }
        }
        let records = ModelLists.all(store)
        return sources.map { ModelLists.list($0, record: records[$0]) }
    }

    /// Read one gateway's list (joined when a read is under way) and keep it.
    func readModelList(_ source: String) async {
        if let t = modelListReads[source] { await t.value; return }
        guard let read = modelListFetcher.read else { return }
        let store = self.store
        let t = Task.detached {
            let now = Date()
            var all = ModelLists.all(store)
            var r = all[source] ?? ModelListRecord()
            do {
                let models = try ModelLists.parse(try await read(source), source: source)
                guard !models.isEmpty else { throw HostError(.failed, "\(ModelSources.title(source))'s model list is empty") }
                r.models = models
                r.fetchedAt = now
                r.failedAt = nil
                r.lastError = nil
            } catch {
                r.failedAt = now
                r.lastError = String(HostError.from(error).message.prefix(200))
            }
            all = ModelLists.all(store)          // another source's read may have been saved meanwhile
            all[source] = r
            ModelLists.save(all, store)
        }
        modelListReads[source] = t
        await t.value
        modelListReads[source] = nil
    }
}
