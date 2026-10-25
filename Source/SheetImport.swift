import Foundation

struct SheetImportResult {
    var show: Show
    var warnings: [String]
}
enum SheetImport {
    // RFC 4180 quoting, with the same rules applied to tab-separated sheets.
    static func rows(_ input: String, delimiter: Character) throws -> [[String]] {
        let text = input.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        let characters = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var result: [[String]] = [], row: [String] = [], cell = ""
        var quoted = false, closed = false, index = 0
        while index < characters.count {
            let c = characters[index]
            if quoted {
                if c == "\"" {
                    if index+1 < characters.count && characters[index+1] == "\"" {cell.append("\""); index += 1}
                    else {quoted = false; closed = true}
                } else {cell.append(c)}
            } else if c == delimiter {
                row.append(cell); cell = ""; closed = false
            } else if c == "\n" {
                row.append(cell); result.append(row); row = []; cell = ""; closed = false
            } else if c == "\"" {
                guard cell.isEmpty && !closed else {throw CueError.message("CSVの引用符が不正です（\(result.count+1)行付近）。")}
                quoted = true
            } else {
                guard !closed else {
                    if c == " " {index += 1; continue}
                    throw CueError.message("CSVの引用符の後に区切り文字以外があります。")
                }
                cell.append(c)
            }
            index += 1
        }
        guard !quoted else {throw CueError.message("CSVの引用符が閉じられていません。")}
        if !cell.isEmpty || !row.isEmpty || closed {row.append(cell); result.append(row)}
        return result
    }
    static func decode(_ data: Data, filename: String, endpoints: [Endpoint]) throws -> SheetImportResult {
        guard data.count <= 20_000_000, let text = String(data:data,encoding:.utf8) else {throw CueError.message("UTF-8のCSV / TSVを選んでください（最大20MB）。")}
        let delimiter: Character = filename.lowercased().hasSuffix(".tsv") ? "\t" : ","
        let table = try rows(text,delimiter:delimiter)
        guard let header = table.first, !header.isEmpty else {throw CueError.message("CUEシートが空です。")}
        func normalize(_ value: String) -> String {value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}
        let names = header.map(normalize)
        func column(_ aliases: [String]) -> Int? {names.firstIndex {aliases.contains($0)}}
        let titleColumn = column(["overview / event","event","title","イベント","イベント名","cue名"])
        let numberColumn = column(["cue","cue番号","番号","number"])
        let timeColumn = column(["start time","planned","予定時刻","開始時刻"])
        let noteColumn = column(["notes","note","メモ","備考"])
        let operatorColumn = column(["sogen cue","進行cue","進行キュー"])
        let mappings: [(String,[String])] = [
            ("技術",["tech state","technical","技術"]),("音響",["sound state","音響"]),("音響詳細",["sound detail","音響詳細"]),
            ("照明",["light state","照明"]),("照明詳細",["light detail","照明詳細"]),
            ("mocap",["mocap state","mocap"]),("mocap 下PJ",["mocap : 1st pj（下）","mocap 下pj"]),
            ("mocap 上PJ",["mocap : 2nd pj（上）","mocap 上pj"]),("mocap HMD",["mocap : hmd","mocap hmd"]),
            ("AI",["ai steate","ai state","ai"]),("AI PJ",["ai : pj","ai pj"]),("AI HMD",["ai : hmd","ai hmd"]),
            ("AI Camarm",["ai : camarm","ai camarm"]),("出演者全体",["cast state","出演者全体"]),
            ("竹本",["生身:竹本","竹本"]),("富士夫",["mocap:富士夫","富士夫"]),("萌",["義肢:萌","萌"]),("花形",["ai:花形","花形"])
        ]
        let stateColumns = mappings.compactMap { name,aliases in column(aliases).map {(name,$0)} }
        guard titleColumn != nil || !stateColumns.isEmpty else {throw CueError.message("見出し行を認識できません。「overview / event」または「イベント名」列を含めてください。")}
        var used = Set(stateColumns.map(\.1))
        [titleColumn,numberColumn,timeColumn,noteColumn,operatorColumn].compactMap {$0}.forEach {used.insert($0)}
        var cues: [Cue] = [], warnings: [String] = []
        let extraHeaders = header.enumerated().filter {!used.contains($0.offset) && !$0.element.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
        for (offset,row) in table.dropFirst().enumerated() {
            func cell(_ column: Int?) -> String {
                guard let column, row.indices.contains(column) else {return ""}
                return row[column].trimmingCharacters(in:.whitespacesAndNewlines)
            }
            let actions = Dictionary(uniqueKeysWithValues:stateColumns.compactMap { name,column in
                let value = cell(column); return value.isEmpty ? nil : (name,value)
            })
            var title = cell(titleColumn)
            if title.isEmpty {title = ["照明","音響","音響詳細","技術"].compactMap {actions[$0]}.first ?? stateColumns.compactMap {actions[$0.0]}.first ?? ""}
            if title.isEmpty && actions.isEmpty {
                if row.contains(where:{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) {warnings.append("\(offset+2)行目: イベント名・担当指示がないためスキップ")}
                continue
            }
            let rawTime = cell(timeColumn)
            let unknownTime = ["???","?","未定","tbd"].contains(rawTime.lowercased())
            let planned = rawTime.isEmpty || unknownTime ? nil : parseTime(rawTime,allowNegative:true)
            guard rawTime.isEmpty || unknownTime || planned != nil else {throw CueError.message("\(offset+2)行目: 予定時刻「\(rawTime)」を読めません。HH:MM:SS / MM:SS / 秒で指定してください。")}
            var notes = ["取込元: \(filename) / \(offset+2)行目"]
            if unknownTime {
                notes.append("開始時刻: \(rawTime)（時刻未定）")
                warnings.append("\(offset+2)行目: 開始時刻 \(rawTime) は時刻未定として取り込み")
            }
            if !cell(noteColumn).isEmpty {notes.append(cell(noteColumn))}
            for extra in extraHeaders where !cell(extra.offset).isEmpty {notes.append("\(extra.element): \(cell(extra.offset))")}
            let number = cell(numberColumn).isEmpty ? String(format:"%02d",cues.count+1) : cell(numberColumn)
            cues.append(Cue(number:number,title:title,planned:planned,actions:actions,notes:notes.joined(separator:"\n"),operatorCue:cell(operatorColumn).isEmpty ? nil : cell(operatorColumn)))
            guard cues.count <= 5000 else {throw CueError.message("CUE数は最大5000件です。")}
        }
        guard !cues.isEmpty else {throw CueError.message("取り込めるイベントがありません。")}
        let name = URL(fileURLWithPath:filename).deletingPathExtension().lastPathComponent
        let show = Show(title:name.isEmpty ? "新しい作品" : name,cues:cues,endpoints:endpoints)
        try show.validate()
        return SheetImportResult(show:show,warnings:warnings)
    }
}
