import Foundation

struct ProjectSummary: Codable, Identifiable {
    var id: UUID
    var title: String
    var updatedAt: Date
}
struct ProjectIndex: Codable {
    var activeID: UUID
    var projects: [ProjectSummary]
}
final class ProjectLibrary {
    let root: URL
    private(set) var index: ProjectIndex?
    init(root: URL) {self.root = root}
    var projects: [ProjectSummary] {index?.projects ?? []}
    var activeID: UUID? {index?.activeID}
    var indexURL: URL {root.appendingPathComponent("Projects.json")}
    func directory(for id: UUID) -> URL {root.appendingPathComponent("Projects").appendingPathComponent(id.uuidString)}
    func prepare(seed: Show) throws -> URL {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:indexURL.path) {
            let loaded = try jsonDecoder.decode(ProjectIndex.self,from:Data(contentsOf:indexURL))
            guard !loaded.projects.isEmpty, Set(loaded.projects.map(\.id)).count == loaded.projects.count,
                  loaded.projects.contains(where: {$0.id == loaded.activeID}) else {throw CueError.message("プロジェクト一覧が不正です。保存フォルダのProjects.jsonを確認してください。")}
            index = loaded
            let active = directory(for:loaded.activeID)
            _ = try readShow(at:active)
            return active
        }
        let legacy = root.appendingPathComponent("Show.json")
        var imported = seed
        if FileManager.default.fileExists(atPath:legacy.path) {
            imported = try readShow(at:root)
        }
        let id = UUID(), target = directory(for:id)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        try jsonEncoder.encode(imported).write(to:target.appendingPathComponent("Show.json"),options:.atomic)
        let runtime = root.appendingPathComponent("Runtime.json")
        if FileManager.default.fileExists(atPath:legacy.path), FileManager.default.fileExists(atPath:runtime.path) {
            try Data(contentsOf:runtime).write(to:target.appendingPathComponent("Runtime.json"),options:.atomic)
        }
        let migrated = ProjectIndex(activeID:id,projects:[ProjectSummary(id:id,title:imported.title,updatedAt:Date())])
        try persist(migrated)
        return target
    }
    func readShow(at directory: URL) throws -> Show {
        let show = try jsonDecoder.decode(Show.self,from:Data(contentsOf:directory.appendingPathComponent("Show.json")))
        try show.validate(); return show
    }
    private func persist(_ value: ProjectIndex) throws {
        try jsonEncoder.encode(value).write(to:indexURL,options:.atomic); index = value
    }
    func create(show: Show) throws -> UUID {
        try show.validate()
        guard var candidate = index else {throw CueError.message("プロジェクト一覧を開けません。")}
        let id = UUID(), folder = directory(for:id)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try jsonEncoder.encode(show).write(to:folder.appendingPathComponent("Show.json"),options:.atomic)
        candidate.projects.append(ProjectSummary(id:id,title:show.title,updatedAt:Date()))
        try persist(candidate)
        return id
    }
    func select(_ id: UUID) throws {
        guard var candidate = index, candidate.projects.contains(where: {$0.id == id}) else {throw CueError.message("プロジェクトが見つかりません。")}
        candidate.activeID = id
        try persist(candidate)
    }
    func updateActive(title: String) throws {
        guard var candidate = index, let i = candidate.projects.firstIndex(where: {$0.id == candidate.activeID}) else {throw CueError.message("プロジェクトが見つかりません。")}
        candidate.projects[i].title = title; candidate.projects[i].updatedAt = Date()
        try persist(candidate)
    }
}
func validateSnapshot(_ state: RuntimeSnapshot, for show: Show) throws {
    let ids = show.cues.map(\.id)
    let pending = state.replayIDs ?? []
    guard state.cueIDs == ids, state.elapsed.isFinite, state.elapsed >= -604800,
          Set(state.records.map(\.cueID)).count == state.records.count,
          state.records.allSatisfy({ids.contains($0.cueID) && $0.showTime.isFinite && $0.showTime >= -604800 && $0.showTime <= state.elapsed}),
          state.skipped.allSatisfy({ids.contains($0)}),
          Set(state.skipped).isDisjoint(with:state.records.map(\.cueID)),
          Set(pending).count == pending.count,
          pending.allSatisfy({id in ids.contains(id) && !state.records.contains(where: {$0.cueID == id}) && !state.skipped.contains(id)}) else {throw CueError.message("保存した進行状態がプロジェクトと一致しません。")}
}
