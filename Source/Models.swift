import Foundation

let departmentOrder = ["技術","音響","音響詳細","照明","照明詳細","mocap","mocap 下PJ","mocap 上PJ","mocap HMD","AI","AI PJ","AI HMD","AI Camarm","出演者全体","竹本","富士夫","萌","花形"]

enum Trigger: String, Codable, CaseIterable {
    case manual, showTime, afterCue
    var label: String { switch self { case .manual: "手動 GO"; case .showTime: "上演時計"; case .afterCue: "CUEからの時間" } }
}
struct OSCArgument: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: String = "i"
    var value: String = "1"
}
struct OSCMessage: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var endpointID: UUID
    var address: String = "/cue"
    var arguments: [OSCArgument] = []
}
struct Endpoint: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 13001
}
struct Cue: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var number: String
    var title: String
    var planned: Double?
    var trigger: Trigger = .manual
    var delay: Double = 60
    var anchorID: UUID?
    var actions: [String:String] = [:]
    var notes: String = ""
    var operatorCue: String? = nil
    var messages: [OSCMessage] = []
}
struct Show: Codable, Equatable {
    var schemaVersion: Int = 1
    var title: String
    var subtitle: String = "本番進行 / CUE SHEET"
    var sourceURL: String = ""
    var sourceCheckedAt: Date? = nil
    var sourceUpdatedAt: Date? = nil
    var cues: [Cue]
    var endpoints: [Endpoint]
    var initialElapsed: Double { min(0,cues.compactMap(\.planned).min() ?? 0) }
    func validate() throws {
        guard schemaVersion == 1 else { throw CueError.message("対応していないファイル形式です。") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueError.message("作品名を入力してください。") }
        guard cues.count <= 5000, endpoints.count <= 100 else { throw CueError.message("CUEまたは送信先の数が上限を超えています。") }
        guard Set(cues.map(\.id)).count == cues.count, Set(endpoints.map(\.id)).count == endpoints.count else { throw CueError.message("IDが重複しています。") }
        for e in endpoints { try OSC.validate(e) }
        for (index,c) in cues.enumerated() {
            guard !c.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueError.message("CUE \(c.number) の名前を入力してください。") }
            if let p = c.planned, !p.isFinite || p < -604800 || p > 604800 { throw CueError.message("予定時刻は−168〜168時間で指定してください。") }
            guard c.delay.isFinite, c.delay >= 0, c.delay <= 604800 else { throw CueError.message("相対秒数が不正です。") }
            if c.trigger == .showTime && c.planned == nil { throw CueError.message("上演時計CUEには予定時刻が必要です。") }
            if c.trigger == .afterCue {
                guard let anchor = c.anchorID, cues[..<index].contains(where: {$0.id == anchor}) else { throw CueError.message("CUE \(c.number): 基準には前のCUEを指定してください。") }
            }
            guard Set(c.messages.map(\.id)).count == c.messages.count else { throw CueError.message("OSCメッセージのIDが重複しています。") }
            for m in c.messages {
                guard endpoints.contains(where: {$0.id == m.endpointID}) else { throw CueError.message("CUE \(c.number): OSC送信先がありません。") }
                _ = try OSC.encode(m)
            }
        }
    }
}
enum CueError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): value } }
}
struct FireRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var cueID: UUID
    var showTime: Double
    var date: Date = Date()
    var origin: String
}
struct LogEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = Date()
    var showTime: Double
    var level: String
    var text: String
}
struct RuntimeSnapshot: Codable {
    var cueIDs: [UUID]
    var elapsed: Double
    var records: [FireRecord]
    var skipped: [UUID]
    var logs: [LogEntry]
    var replayIDs: [UUID]? = nil
}
func timeText(_ value: Double, tenths: Bool = false) -> String {
    guard value.isFinite else { return "--:--" }
    let v = abs(value), n = Int(v), sign = value < 0 ? "−" : ""
    let base = n >= 3600 ? String(format:"%d:%02d:%02d",n/3600,(n/60)%60,n%60) : String(format:"%02d:%02d",n/60,n%60)
    return sign + base + (tenths ? String(format:".%d",Int((v - floor(v))*10)) : "")
}
func parseTime(_ text: String, allowNegative: Bool = false) -> Double? {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    var sign: Double = 1
    if s.hasPrefix("-") || s.hasPrefix("−") {
        guard allowNegative else {return nil}
        sign = -1; s.removeFirst()
    }
    let parts = s.split(separator:":",omittingEmptySubsequences:false)
    guard (1...3).contains(parts.count), parts.allSatisfy({Double($0) != nil}) else { return nil }
    let values = parts.map {Double($0)!}
    guard values.allSatisfy({$0 >= 0 && $0.isFinite}), values.dropFirst().allSatisfy({$0 < 60}) else { return nil }
    let result = values.reduce(0) {$0*60+$1}
    return result <= 604800 ? sign*result : nil
}
let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601; return e
}()
let jsonDecoder: JSONDecoder = {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
}()
