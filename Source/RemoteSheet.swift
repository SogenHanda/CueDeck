import Foundation

struct SheetLocation: Equatable {
    let spreadsheetID: String
    let gid: String?
    let published: Bool
    let resourceKey: String?
    init(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in:.whitespacesAndNewlines)
        let input = trimmed.hasPrefix("docs.google.com/") ? "https://" + trimmed : trimmed
        guard let url = URLComponents(string:input), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "docs.google.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else {throw CueError.message("GoogleスプレッドシートのHTTPS URLを入力してください。")}
        var parts = url.path.split(separator:"/").map(String.init)
        if parts.count >= 3, parts[0] == "spreadsheets", parts[1] == "u", Int(parts[2]) != nil {parts.removeSubrange(1...2)}
        guard parts.count >= 3, parts[0] == "spreadsheets", parts[1] == "d" else {throw CueError.message("シートURLの形式を確認してください。")}
        published = parts[2] == "e"
        let idIndex = published ? 3 : 2
        guard parts.indices.contains(idIndex) else {throw CueError.message("シートIDがありません。")}
        let id = parts[idIndex]
        guard (10...200).contains(id.count), id.utf8.allSatisfy({(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95}) else {throw CueError.message("シートIDが不正です。")}
        spreadsheetID = id
        let query = url.queryItems ?? []
        let fragment = URLComponents(string:"https://docs.google.com/?" + (url.fragment ?? ""))?.queryItems ?? []
        let gids = fragment.filter {$0.name == "gid"}
        let chosen = gids.isEmpty ? query.filter {$0.name == "gid"} : gids
        guard chosen.count <= 1 else {throw CueError.message("シートのgidが重複しています。")}
        if let value = chosen.first?.value {
            guard !value.isEmpty, value.utf8.allSatisfy({(48...57).contains($0)}), let number = UInt32(value) else {throw CueError.message("シートのgidは0以上の整数で指定してください。")}
            gid = String(number)
        } else if !chosen.isEmpty {throw CueError.message("シートのgidがありません。")}
        else {gid = nil}
        let keys = query.filter {$0.name == "resourcekey"}
        guard keys.count <= 1 else {throw CueError.message("resourcekeyが重複しています。")}
        resourceKey = keys.first?.value
        if let resourceKey, resourceKey.count > 256 || !resourceKey.utf8.allSatisfy({$0 > 32 && $0 < 127}) {throw CueError.message("共有URLのresourcekeyが不正です。")}
    }
    var canonicalURL: URL {
        var c = URLComponents()
        c.scheme = "https"; c.host = "docs.google.com"
        c.path = published ? "/spreadsheets/d/e/\(spreadsheetID)/pubhtml" : "/spreadsheets/d/\(spreadsheetID)/edit"
        var q: [URLQueryItem] = []
        if let gid {q.append(.init(name:"gid",value:gid))}
        if let resourceKey {q.append(.init(name:"resourcekey",value:resourceKey))}
        c.queryItems = q.isEmpty ? nil : q
        return c.url!
    }
    var exportURL: URL {
        var c = URLComponents(url:canonicalURL,resolvingAgainstBaseURL:false)!
        c.path = published ? "/spreadsheets/d/e/\(spreadsheetID)/pub" : "/spreadsheets/d/\(spreadsheetID)/export"
        var q = c.queryItems ?? []
        q.append(.init(name:published ? "output" : "format",value:"csv"))
        if published {q.append(.init(name:"single",value:"true"))}
        c.queryItems = q; return c.url!
    }
    var tabDescription: String {gid.map {"シート gid: " + $0} ?? "先頭のシート（gid未指定）"}
}
struct RemoteSheetResult {
    let location: SheetLocation
    let imported: SheetImportResult
    let fetchedAt: Date
}
enum RemoteSheet {
    static let maxBytes = 20_000_000
    static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {throw CueError.message("シートの応答を確認できません。")}
        if http.statusCode == 401 || http.statusCode == 403 || response.url?.host == "accounts.google.com" {
            throw CueError.message("このシートはアプリから閲覧できません。ログインなしでCSVを取得できる共有URLが必要です。共有設定は自動で変更しません。限定公開のまま使う場合は、従来のCSV取り込みを使ってください。")
        }
        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 404: throw CueError.message("シートまたは指定したタブが見つかりません。URLとgidを確認してください。")
            case 429: throw CueError.message("Googleの取得回数制限です。少し待ってから再度更新してください。")
            default: throw CueError.message("シートを取得できませんでした（HTTP \(http.statusCode)）。現在の作品は維持します。")
            }
        }
        let host = response.url?.host?.lowercased() ?? ""
        guard host == "docs.google.com" || host == "googleusercontent.com" || host.hasSuffix(".googleusercontent.com") else {throw CueError.message("Google以外の応答先に転送されたため読み込みを止めました。")}
        guard response.mimeType?.lowercased() != "text/html" else {throw CueError.message("CSVではなくログイン画面またはエラーページが返されました。シートの閲覧権限とURLを確認してください。")}
        guard response.expectedContentLength <= maxBytes else {throw CueError.message("シートが20MBを超えています。")}
    }
    static func fetch(_ raw: String, endpoints: [Endpoint]) async throws -> RemoteSheetResult {
        let location = try SheetLocation(raw)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpCookieAcceptPolicy = .never; config.httpShouldSetCookies = false
        let session = URLSession(configuration:config)
        defer {session.invalidateAndCancel()}
        var request = URLRequest(url:location.exportURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache, no-store",forHTTPHeaderField:"Cache-Control")
        request.setValue("text/csv",forHTTPHeaderField:"Accept")
        let (bytes,response) = try await session.bytes(for:request)
        try validateResponse(response)
        var data = Data()
        for try await byte in bytes {
            if data.count >= maxBytes {throw CueError.message("シートが20MBを超えています。")}
            data.append(byte)
            if data.count % 8192 == 0 {try Task.checkCancellation()}
        }
        try Task.checkCancellation()
        guard !data.isEmpty else {throw CueError.message("シートの内容が空でした。")}
        if let prefix = String(data:data.prefix(256),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased(),
           prefix.hasPrefix("<!doctype") || prefix.hasPrefix("<html") {throw CueError.message("CSVではなくWebページが返されました。シートURLと閲覧権限を確認してください。")}
        let result = try SheetImport.decode(data,filename:"Google Sheet.csv",endpoints:endpoints)
        return RemoteSheetResult(location:location,imported:result,fetchedAt:Date())
    }
}
struct SheetChange: Identifiable {
    let id = UUID()
    let kind: String
    let title: String
    let detail: String
}
struct SheetUpdatePlan {
    let baseline: Show
    let projectID: UUID?
    var candidate: Show
    let fetchedAt: Date
    var matched: Int
    var changes: [SheetChange]
    var warnings: [String]
    var changed: Bool { !changes.isEmpty }
    static func make(baseline: Show, projectID: UUID?, result: RemoteSheetResult, preserveSettings: Bool) throws -> SheetUpdatePlan {
        var candidate = result.imported.show
        candidate.title = baseline.title; candidate.subtitle = baseline.subtitle
        candidate.sourceURL = result.location.canonicalURL.absoluteString
        candidate.sourceCheckedAt = result.fetchedAt
        candidate.sourceUpdatedAt = baseline.sourceUpdatedAt
        var warnings = result.imported.warnings, changes: [SheetChange] = []
        var matches: [Int:Int] = [:], used: Set<Int> = []
        func normal(_ s: String) -> String {s.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ").lowercased()}
        let keys: [(Cue)->String] = [
            {normal($0.title) + "|" + normal($0.operatorCue ?? "")},
            {normal($0.operatorCue ?? "")},
            {normal($0.title)}
        ]
        for (stage,key) in keys.enumerated() {
            let oldGroups = Dictionary(grouping:baseline.cues.indices.filter {!used.contains($0)},by:{key(baseline.cues[$0])})
            let newGroups = Dictionary(grouping:candidate.cues.indices.filter {matches[$0] == nil},by:{key(candidate.cues[$0])})
            for (value,newIndices) in newGroups {
                guard !value.isEmpty, newIndices.count == 1, let oldIndices = oldGroups[value], oldIndices.count == 1 else {continue}
                if stage == 2 {
                    let oldCall = normal(baseline.cues[oldIndices[0]].operatorCue ?? "")
                    let newCall = normal(candidate.cues[newIndices[0]].operatorCue ?? "")
                    if !oldCall.isEmpty && !newCall.isEmpty && oldCall != newCall {continue}
                }
                matches[newIndices[0]] = oldIndices[0]; used.insert(oldIndices[0])
            }
        }
        for (newIndex,oldIndex) in matches {
            let old = baseline.cues[oldIndex]
            candidate.cues[newIndex].id = old.id
            if preserveSettings {
                candidate.cues[newIndex].trigger = old.trigger
                candidate.cues[newIndex].delay = old.delay
                candidate.cues[newIndex].anchorID = old.anchorID
                candidate.cues[newIndex].messages = old.messages
            }
        }
        for i in candidate.cues.indices {
            var cue = candidate.cues[i]
            if cue.trigger == .afterCue, !candidate.cues.prefix(i).contains(where: {$0.id == cue.anchorID}) {
                cue.trigger = .manual; cue.anchorID = nil
                warnings.append("CUE \(cue.number): 基準CUEの削除・順序変更のため手動GOに戻します。")
            }
            if cue.trigger == .showTime && cue.planned == nil {
                cue.trigger = .manual
                warnings.append("CUE \(cue.number): 予定時刻が未定になったため手動GOに戻します。")
            }
            candidate.cues[i] = cue
        }
        func sourceNotes(_ text: String) -> String {
            let lines = text.components(separatedBy:"\n")
            return lines.first?.hasPrefix("取込元:") == true ? lines.dropFirst().joined(separator:"\n") : text
        }
        for i in candidate.cues.indices {
            let cue = candidate.cues[i]
            guard let oldIndex = matches[i] else {
                changes.append(SheetChange(kind:"追加",title:"\(cue.number)  \(cue.title)",detail:"新しいCUE / 手動GO")); continue
            }
            let old = baseline.cues[oldIndex]
            var fields: [String] = []
            if cue.title != old.title {fields.append("イベント名")}
            if cue.planned != old.planned {fields.append("予定 \(old.planned.map {timeText($0)} ?? "未定") → \(cue.planned.map {timeText($0)} ?? "未定")")}
            if cue.actions != old.actions {fields.append("担当状態")}
            if cue.operatorCue != old.operatorCue {fields.append("進行CUE")}
            if sourceNotes(cue.notes) != sourceNotes(old.notes) {fields.append("シート補足・メモ")}
            if cue.number != old.number || i != oldIndex {fields.append("並び順・番号")}
            if cue.trigger != old.trigger || cue.delay != old.delay || cue.anchorID != old.anchorID || cue.messages != old.messages {fields.append("自動実行・OSC設定")}
            if !fields.isEmpty {changes.append(SheetChange(kind:"変更",title:"\(cue.number)  \(cue.title)",detail:fields.joined(separator:" / ")))}
        }
        for i in baseline.cues.indices where !used.contains(i) {
            let cue = baseline.cues[i]
            changes.append(SheetChange(kind:"削除",title:"\(cue.number)  \(cue.title)",detail:"シートに一致するCUEがありません"))
        }
        let unmatchedConfigured = baseline.cues.indices.filter {!used.contains($0) && (baseline.cues[$0].trigger != .manual || !baseline.cues[$0].messages.isEmpty)}.count
        if unmatchedConfigured > 0 {warnings.append("一致しない旧CUE \(unmatchedConfigured)件のOSC・自動設定は引き継ぎません。旧作品はバックアップします。")}
        try candidate.validate()
        return SheetUpdatePlan(baseline:baseline,projectID:projectID,candidate:candidate,fetchedAt:result.fetchedAt,matched:matches.count,changes:changes,warnings:warnings)
    }
}
