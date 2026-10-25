import Foundation
import Combine

@MainActor final class ShowEngine: ObservableObject {
    @Published var show: Show
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var running = false
    @Published private(set) var records: [FireRecord] = []
    @Published private(set) var skipped: Set<UUID> = []
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var outputArmed = false
    @Published private(set) var replayIDs: [UUID] = []
    var replayID: UUID? {replayIDs.first}
    @Published var banner = ""
    @Published var alert: String?
    @Published var selectedID: UUID?
    @Published var search = ""
    @Published var panel = "CUE編集"
    @Published var savedAt: Date?
    @Published var sheetUpdateBusy = false
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var activeProjectID: UUID?
    var cueEditPending = false
    var networkEditPending = false
    var hasPendingEdits: Bool { cueEditPending || networkEditPending }
    private var lastTick: Double?
    private var lastCheckpoint: Double = 0
    private var lastGO: Double = -.infinity
    private var directory: URL?
    private let projectLibrary: ProjectLibrary?
    private var storageError: String?
    var sender: (OSCMessage,Endpoint) throws -> Void = OSC.send

    var doneIDs: Set<UUID> { Set(records.map(\.cueID)).union(skipped) }
    var next: Cue? {
        if let replayID, let cue = show.cues.first(where: {$0.id == replayID && !doneIDs.contains($0.id)}) {return cue}
        return show.cues.first { !doneIDs.contains($0.id) }
    }
    var current: Cue? { records.last.flatMap { r in show.cues.first {$0.id == r.cueID} } }
    var cueElapsed: Double { max(0,elapsed - (records.last?.showTime ?? elapsed)) }
    var complete: Bool { next == nil }
    var selected: Cue? { show.cues.first {$0.id == selectedID} }
    var firedCount: Int { records.count }
    var dirtyDescription: String { savedAt.map {"保存 " + $0.formatted(date:.omitted,time:.shortened)} ?? "未保存" }

    init(seed: Show, directory: URL? = nil, restore: Bool = true, projectLibrary: ProjectLibrary? = nil) {
        self.show = seed; self.directory = directory; self.projectLibrary = projectLibrary
        elapsed = seed.initialElapsed
        if let projectLibrary {
            do {
                self.directory = try projectLibrary.prepare(seed:seed)
                projects = projectLibrary.projects; activeProjectID = projectLibrary.activeID
            } catch {
                self.directory = nil; storageError = error.localizedDescription
                banner = "プロジェクト保存先を開けません。元データは維持しています。\(error.localizedDescription)"
            }
        }
        if let directory = self.directory {
            do { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
            catch { banner = "保存フォルダを作成できません: \(error.localizedDescription)" }
            let showURL = directory.appendingPathComponent("Show.json")
            if restore && FileManager.default.fileExists(atPath:showURL.path) {
                do {
                    let data = try Data(contentsOf:showURL)
                    let loaded = try jsonDecoder.decode(Show.self,from:data); try loaded.validate()
                    self.show = loaded
                } catch {
                    self.banner = "保存データの読み込み失敗。元データを保護するため別名書き出しを使用してください。\(error.localizedDescription)"
                    if let previous = try? Data(contentsOf:directory.appendingPathComponent("Show.previous.json")), let loaded = try? jsonDecoder.decode(Show.self,from:previous), (try? loaded.validate()) != nil { self.show = loaded }
                }
            }
            elapsed = self.show.initialElapsed
            if restore, let data = try? Data(contentsOf:directory.appendingPathComponent("Runtime.json")) {
                do {
                    let state = try jsonDecoder.decode(RuntimeSnapshot.self,from:data)
                    try validateSnapshot(state,for:self.show)
                    applyProgress(state)
                    if !records.isEmpty || elapsed != self.show.initialElapsed {banner = "前回の進行をHOLDで復元しました。OSC出力はOFFです。"}
                } catch {banner = "進行状態を復元できません。時計と実行済みCUEを確認してください。\(error.localizedDescription)"}
            }
            savedAt = (try? FileManager.default.attributesOfItem(atPath:showURL.path)[.modificationDate]) as? Date
        }
        selectedID = next?.id ?? show.cues.first?.id
    }
    private func applyProgress(_ state: RuntimeSnapshot?) {
        elapsed = state?.elapsed ?? show.initialElapsed
        records = state?.records ?? []; skipped = Set(state?.skipped ?? [])
        logs = state?.logs ?? []; replayIDs = state?.replayIDs ?? []
        running = false; lastTick = nil; lastGO = -.infinity; outputArmed = false
    }
    private func refreshProjects() {
        projects = projectLibrary?.projects ?? []; activeProjectID = projectLibrary?.activeID
    }
    func switchProject(_ id: UUID) {
        guard !running, !hasPendingEdits, !sheetUpdateBusy else {alert = "HOLDにし、編集を保存してシート更新画面を閉じてから切り替えてください。"; return}
        guard id != activeProjectID, let projectLibrary else {return}
        do {
            let target = projectLibrary.directory(for:id)
            let candidate = try projectLibrary.readShow(at:target)
            let runtimeURL = target.appendingPathComponent("Runtime.json")
            var state: RuntimeSnapshot?
            if FileManager.default.fileExists(atPath:runtimeURL.path) {
                state = try jsonDecoder.decode(RuntimeSnapshot.self,from:Data(contentsOf:runtimeURL))
                try validateSnapshot(state!,for:candidate)
            }
            guard saveShow() else {return}
            try projectLibrary.select(id)
            directory = target; show = candidate; applyProgress(state)
            search = ""; selectedID = next?.id ?? show.cues.first?.id
            cueEditPending = false; networkEditPending = false; refreshProjects()
            banner = "「\(show.title)」に切り替えました。進行を保持 / HOLD / OSC出力OFF"
            log("プロジェクト切替"); _ = saveRuntime()
        } catch {alert = "切替に失敗しました。現在の作品を維持します。\(error.localizedDescription)"}
    }
    func createProject(name: String, from candidate: Show? = nil) {
        guard !running, !hasPendingEdits, !sheetUpdateBusy else {alert = "HOLDにし、編集を保存してシート更新画面を閉じてから作成してください。"; return}
        guard let projectLibrary else {alert = "プロジェクト保存先が設定されていません。"; return}
        do {
            var value = candidate ?? Show(title:name,cues:[],endpoints:[])
            value.title = name.trimmingCharacters(in:.whitespacesAndNewlines)
            try value.validate()
            guard saveShow() else {return}
            let id = try projectLibrary.create(show:value); refreshProjects(); switchProject(id)
        } catch {alert = error.localizedDescription}
    }
    var orderedPending: [Cue] {
        let replay = replayIDs.compactMap {id in show.cues.first {$0.id == id && !doneIDs.contains(id)}}
        return replay + show.cues.filter {!doneIDs.contains($0.id) && !replayIDs.contains($0.id)}
    }
    var stateDictionary: [String:String] {
        records.reduce(into:[:]) {state,record in
            guard let cue = show.cues.first(where: {$0.id == record.cueID}) else {return}
            state = StatePreview.merge(state,actions:cue.actions)
        }
    }
    var departmentPreviews: [DepartmentPreview] {StatePreview.make(current:stateDictionary,upcoming:orderedPending)}
    func log(_ text: String, level: String = "INFO") {
        logs.append(LogEntry(showTime:elapsed,level:level,text:text))
        if logs.count > 5000 { logs.removeFirst(logs.count-5000) }
    }
    @discardableResult func saveRuntime() -> Bool {
        if let storageError {banner = storageError; return false}
        guard let directory else { return true }
        do {
            let value = RuntimeSnapshot(cueIDs:show.cues.map(\.id),elapsed:elapsed,records:records,skipped:Array(skipped),logs:logs,replayIDs:replayIDs)
            try jsonEncoder.encode(value).write(to:directory.appendingPathComponent("Runtime.json"),options:.atomic)
            savedAt = Date(); lastCheckpoint = elapsed; return true
        } catch {
            running = false; lastTick = nil; outputArmed = false
            banner = "保存失敗。HOLD / OSC OFF: \(error.localizedDescription)"
            return false
        }
    }
    @discardableResult func saveShow() -> Bool {
        if let storageError {alert = storageError; return false}
        guard let directory else { return true }
        do {
            try show.validate()
            let url = directory.appendingPathComponent("Show.json")
            if FileManager.default.fileExists(atPath:url.path) {
                let old = try Data(contentsOf:url)
                try old.write(to:directory.appendingPathComponent("Show.previous.json"),options:.atomic)
            }
            try jsonEncoder.encode(show).write(to:url,options:.atomic)
            try projectLibrary?.updateActive(title:show.title); refreshProjects()
            savedAt = Date(); return saveRuntime()
        } catch { banner = "作品の保存に失敗しました: \(error.localizedDescription)"; alert = banner; return false }
    }
    func dueTime(_ cue: Cue) -> Double? {
        switch cue.trigger {
        case .manual: return nil
        case .showTime: return cue.planned
        case .afterCue: return records.first(where: {$0.cueID == cue.anchorID}).map {$0.showTime+cue.delay}
        }
    }
    func start(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard !running else { return }
        guard !hasPendingEdits, !sheetUpdateBusy else { alert = "編集を保存し、シート更新画面を閉じてから開始してください。"; return }
        do { try show.validate() } catch { alert = error.localizedDescription; return }
        guard saveShow() else { return }
        running = true; lastTick = now; banner = ""; log("上演時計 START / RESUME")
        _ = saveRuntime()
    }
    func hold(reason: String = "HOLD", now: Double = ProcessInfo.processInfo.systemUptime) {
        if running, let lastTick { elapsed += max(0,min(now-lastTick,2)) }
        running = false; lastTick = nil; log(reason); _ = saveRuntime()
    }
    func tick(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard running, let lastTick else { return }
        let delta = now-lastTick
        guard delta >= 0, delta <= 2 else {
            running = false; self.lastTick = nil
            banner = "時計の中断を検出してHOLDしました。中断時間は加算していません。時計とCUEを確認して再開してください。"
            log(banner,level:"HOLD"); _ = saveRuntime(); return
        }
        elapsed += delta; self.lastTick = now
        // Independent automatic cues can run while a manual cue is waiting.
        for _ in 0..<show.cues.count {
            guard let cue = show.cues.first(where: {!doneIDs.contains($0.id) && !replayIDs.contains($0.id) && (dueTime($0).map {$0 <= elapsed} ?? false)}) else { break }
            guard let due = dueTime(cue), elapsed-due <= 0.6 else {
                running = false; self.lastTick = nil
                banner = "自動CUE \(cue.number) の予定時刻を過ぎています。手動実行またはスキップしてから再開してください。"
                log(banner,level:"HOLD"); _ = saveRuntime(); return
            }
            fire(cue,origin:"AUTO")
            if !running { break }
        }
        if elapsed-lastCheckpoint >= 2 { _ = saveRuntime() }
    }
    func go(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard running, now-lastGO >= 0.35, let cue = next else { return }
        tick(now:now)
        guard running, !doneIDs.contains(cue.id) else { return }
        lastGO = now; fire(cue,origin:"GO")
    }
    func fire(_ cue: Cue, origin: String) {
        guard !doneIDs.contains(cue.id) else { return }
        // Validate the entire batch before committing any cue or sending any packet.
        do {
            for m in cue.messages {
                guard let e = show.endpoints.first(where: {$0.id == m.endpointID}) else { throw CueError.message("送信先がありません。") }
                try OSC.validate(e); _ = try OSC.encode(m)
            }
        } catch { running = false; lastTick = nil; banner = error.localizedDescription; log(banner,level:"ERROR"); _ = saveRuntime(); return }
        let entry = FireRecord(cueID:cue.id,showTime:elapsed,origin:origin)
        let previousReplay = replayIDs
        records.append(entry)
        replayIDs.removeAll {$0 == cue.id}
        log("\(origin)  \(cue.number)  \(cue.title.replacingOccurrences(of:"\n",with:" / "))")
        // Commit before UDP: a crash must never silently resend a cue on restore.
        guard saveRuntime() else { records.removeLast(); replayIDs = previousReplay; return }
        if outputArmed {
            for m in cue.messages {
                guard let e = show.endpoints.first(where: {$0.id == m.endpointID}) else { continue }
                do { try sender(m,e); log("UDP送信 \(e.name) \(e.host):\(e.port) \(m.address)（受信未確認）",level:"OSC") }
                catch {
                    running = false; lastTick = nil; outputArmed = false
                    banner = "OSC送信エラー。CUEは実行済みです。自動再送しません。\(error.localizedDescription)"
                    log(banner,level:"ERROR"); break
                }
            }
        } else if !cue.messages.isEmpty { log("OSC出力OFF: \(cue.messages.count)件を送信せず記録",level:"DRY") }
        _ = saveRuntime()
    }
    func arm(_ value: Bool) {
        guard !running else { alert = "OSC出力の切り替えはHOLD中に行ってください。"; return }
        outputArmed = value; log(value ? "OSC出力 ON" : "OSC出力 OFF"); _ = saveRuntime()
    }
    func testMessage(_ m: OSCMessage) {
        guard !running, outputArmed, let e = show.endpoints.first(where: {$0.id == m.endpointID}) else { alert = "HOLD中にOSC出力をONにするとテストできます。"; return }
        do { try sender(m,e); log("TEST UDP送信 \(e.name) \(m.address)（受信未確認）",level:"OSC"); _ = saveRuntime() }
        catch { alert = error.localizedDescription; log(error.localizedDescription,level:"ERROR"); _ = saveRuntime() }
    }
    func skipNext() {
        guard !running, let cue = next else { return }
        skipped.insert(cue.id); replayIDs.removeAll {$0 == cue.id}; log("SKIP \(cue.number) \(cue.title)"); _ = saveRuntime()
    }
    func manualSelected() {
        guard !running, let cue = selected, !doneIDs.contains(cue.id) else { return }
        fire(cue,origin:"HOLD GO")
    }
    func undoLastCue() {
        guard !hasPendingEdits else {alert = "先に編集を保存または破棄してください。"; return}
        guard !running, let last = records.last, let cue = show.cues.first(where: {$0.id == last.cueID}) else {return}
        guard archiveRun() else {return}
        records.removeLast()
        replayIDs.insert(cue.id,at:0); selectedID = cue.id; outputArmed = false; lastGO = -.infinity
        banner = "CUE \(cue.number) を実行前に戻しました。時計は維持 / OSC OFF。次のGOで再実行します。外部機器の状態は戻りません。"
        log("UNDO \(cue.number) / 次のGOを優先 / 時計維持 / OSC OFF")
        _ = saveRuntime()
    }
    func reset() {
        guard !running else { return }
        guard archiveRun() else { return }
        elapsed = show.initialElapsed; records = []; skipped = []; replayIDs = []; outputArmed = false; lastGO = -.infinity
        banner = "新しい上演を準備しました。OSC出力はOFFです。"; log("上演をリセット"); _ = saveRuntime()
    }
    func rewind(to id: UUID) {
        guard !running, let index = show.cues.firstIndex(where: {$0.id == id}) else { return }
        guard archiveRun() else { return }
        replayIDs = []
        let earlier = Set(show.cues.prefix(index).map(\.id))
        records.removeAll {!earlier.contains($0.cueID)}
        skipped = Set(show.cues.prefix(index).map(\.id)).subtracting(records.map(\.cueID))
        outputArmed = false
        log("ジャンプ → \(show.cues[index].number) / 以前の未実行CUEはスキップ / OSC OFF")
        banner = "ジャンプしました。上演時計は維持しています。自動CUEの時刻を確認してください。"
        _ = saveRuntime()
    }
    func setElapsed(_ value: Double) {
        guard !running, value.isFinite, value >= -604800, value >= (records.map(\.showTime).max() ?? -604800) else { alert = "時計は最後に実行したCUE以降の時刻を指定してください。"; return }
        elapsed = value; log("上演時計を \(timeText(value)) に変更"); _ = saveRuntime()
    }
    func updateCue(_ cue: Cue) {
        guard !running, let index = show.cues.firstIndex(where: {$0.id == cue.id}) else { return }
        var candidate = show; candidate.cues[index] = cue
        do { try candidate.validate(); show = candidate; _ = saveShow() } catch { alert = error.localizedDescription }
    }
    func addCue(copy: Bool = false) {
        guard !running else { return }
        var cue = copy ? (selected ?? Cue(number:"",title:"新しいCUE")) : Cue(number:"",title:"新しいCUE")
        cue.id = UUID(); cue.number = String(format:"%02d",show.cues.count+1)
        if copy { cue.title += "（コピー）"; cue.messages = cue.messages.map { var m = $0; m.id = UUID(); m.arguments = m.arguments.map {var a = $0; a.id = UUID(); return a}; return m } }
        let index = selectedID.flatMap {id in show.cues.firstIndex {$0.id == id}}.map {$0+1} ?? show.cues.count
        show.cues.insert(cue,at:index); selectedID = cue.id; _ = saveShow()
    }
    func deleteSelected() {
        guard !running, let id = selectedID else { return }
        guard !show.cues.contains(where: {$0.trigger == .afterCue && $0.anchorID == id}) else { alert = "このCUEを基準にした自動CUEがあります。先に基準を変更してください。"; return }
        guard !doneIDs.contains(id) else { alert = "実行済み・スキップ済みCUEは、上演をリセットしてから削除してください。"; return }
        show.cues.removeAll {$0.id == id}; replayIDs.removeAll {$0 == id}; selectedID = next?.id; _ = saveShow()
    }
    func moveSelected(_ offset: Int) {
        guard !running, let id = selectedID, let i = show.cues.firstIndex(where: {$0.id == id}), show.cues.indices.contains(i+offset) else { return }
        var candidate = show; candidate.cues.swapAt(i,i+offset)
        do { try candidate.validate(); show = candidate; _ = saveShow() } catch { alert = error.localizedDescription }
    }
    @discardableResult func replace(with candidate: Show) -> Bool {
        guard !running, !sheetUpdateBusy else {return false}
        do {try candidate.validate()} catch {alert = error.localizedDescription; return false}
        guard archiveRun(includeShow:true) else {return false}
        show = candidate; elapsed = candidate.initialElapsed; records = []; skipped = []; logs = []; replayIDs = []; outputArmed = false
        selectedID = next?.id; banner = "作品を読み込みました。全CUE未実行 / OSC出力OFF"; log("作品を読み込み")
        return saveShow()
    }
    @discardableResult func registerSourceURL(_ raw: String) -> Bool {
        guard !running, !hasPendingEdits, !sheetUpdateBusy else {alert = "HOLDにし、編集を保存してからURLを登録してください。"; return false}
        do {
            let trimmed = raw.trimmingCharacters(in:.whitespacesAndNewlines)
            let canonical = trimmed.isEmpty ? "" : try SheetLocation(trimmed).canonicalURL.absoluteString
            if show.sourceURL != canonical {
                show.sourceURL = canonical; show.sourceCheckedAt = nil; show.sourceUpdatedAt = nil
            }
            return saveShow()
        } catch {alert = error.localizedDescription; return false}
    }
    @discardableResult func applySheetUpdate(_ plan: SheetUpdatePlan) -> Bool {
        guard !running, !hasPendingEdits, show == plan.baseline, activeProjectID == plan.projectID else {
            alert = "取得中に作品または編集内容が変わりました。現在の内容を維持します。もう一度取得してください。"; return false
        }
        sheetUpdateBusy = false
        if !plan.changed {
            show.sourceURL = plan.candidate.sourceURL; show.sourceCheckedAt = plan.fetchedAt
            log("シート更新確認: 変更なし / 進行を維持")
            banner = "シートは最新版です。時計・実行済みCUEを維持しました。"
            return saveShow()
        }
        var candidate = plan.candidate
        candidate.sourceUpdatedAt = Date()
        guard replace(with:candidate) else {return false}
        banner = "シートを最新版に更新しました。旧作品・進行はバックアップ済み / 全CUE未実行 / OSC OFF"
        log("URLからシートを更新: \(candidate.cues.count) CUE")
        return saveRuntime()
    }
    @discardableResult func archiveRun(includeShow: Bool = false) -> Bool {
        guard let directory else { return true }
        do {
            let date = Date().formatted(.iso8601).replacingOccurrences(of:":",with:"-")
            let folder = directory.appendingPathComponent("RunBackups")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let backupName = "\(date)-\(UUID().uuidString.prefix(6))"
            if includeShow {
                let projects = directory.appendingPathComponent("ProjectBackups")
                try FileManager.default.createDirectory(at:projects,withIntermediateDirectories:true)
                try jsonEncoder.encode(show).write(to:projects.appendingPathComponent(backupName + ".cuedeck.json"),options:.atomic)
            }
            let state = RuntimeSnapshot(cueIDs:show.cues.map(\.id),elapsed:elapsed,records:records,skipped:Array(skipped),logs:logs,replayIDs:replayIDs)
            try jsonEncoder.encode(state).write(to:folder.appendingPathComponent(backupName + ".json"),options:.atomic)
            return true
        } catch { alert = "進行バックアップ失敗: \(error.localizedDescription)"; return false }
    }
    var liveStates: [(String,String,String)] {
        var state: [String:(String,String)] = [:]
        for record in records {
            guard let cue = show.cues.first(where: {$0.id == record.cueID}) else { continue }
            for (key,value) in cue.actions where !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { state[key] = (value,cue.number) }
        }
        let keys = departmentOrder + state.keys.filter {!departmentOrder.contains($0)}.sorted()
        return keys.compactMap { key in state[key].map {(key,$0.0,$0.1)} }
    }
    func logCSV() -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of:"\"",with:"\"\"") + "\"" }
        return "\u{FEFF}実日時,上演秒,上演時刻,種別,内容\n" + logs.map { [q($0.date.formatted(.iso8601)),String(format:"%.3f",$0.showTime),q(timeText($0.showTime)),q($0.level),q($0.text)].joined(separator:",") }.joined(separator:"\n")
    }
}
