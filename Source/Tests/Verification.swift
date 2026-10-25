import Foundation
import Darwin

@main struct Verification {
    @MainActor static func main() throws {
        var count = 0
        func check(_ test: @autoclosure () -> Bool, _ label: String) {
            guard test() else { fputs("FAIL: \(label)\n",stderr); exit(1) }
            count += 1; print("PASS: \(label)")
        }
        func rejects(_ label: String,_ body: () throws -> Void) {do {try body(); fputs("FAIL: \(label)\n",stderr); exit(1)} catch {count += 1; print("PASS: \(label)")}}
        let original = try jsonDecoder.decode(Show.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        try original.validate()
        check(original.cues.count == 31,"latest source imports all 31 events")
        check(original.cues.allSatisfy {$0.trigger == .manual && $0.messages.isEmpty},"initial cues manual, no speculative OSC")
        check(original.cues.last(where: {$0.planned != nil})?.planned == 6990,"latest final timed event is 1:56:30")
        check(parseTime("1:11:00") == 4260 && parseTime("18:00") == 1080 && parseTime("90") == 90 && parseTime("1:99") == nil,"time parsing")
        let ep = Endpoint(name:"loopback",host:"127.0.0.1",port:13001)
        let a = Cue(number:"01",title:"Anchor",actions:["音響":"play","照明":"on"])
        let b = Cue(number:"02",title:"Manual wait",actions:["音響":"stop"])
        let c = Cue(number:"03",title:"Relative",trigger:.afterCue,delay:1,anchorID:a.id,actions:["照明":"fade"])
        let d = Cue(number:"04",title:"Absolute",planned:1.5,trigger:.showTime)
        let show = Show(title:"Test",cues:[a,b,c,d],endpoints:[ep])
        let engine = ShowEngine(seed:show)
        engine.start(now:100); engine.go(now:100.1)
        engine.go(now:100.2)
        check(engine.records.count == 1,"GO repeat debounce")
        engine.tick(now:100.5); engine.hold(now:100.5)
        let held = engine.elapsed; engine.tick(now:190)
        check(engine.elapsed == held,"HOLD freezes clock")
        engine.start(now:200); engine.tick(now:200.4)
        check(engine.records.count == 1,"relative timer excludes HOLD")
        engine.tick(now:200.7)
        check(engine.records.map(\.cueID) == [a.id,c.id] && engine.next?.id == b.id,"relative AUTO runs independently of waiting manual")
        engine.tick(now:201.1)
        check(engine.records.map(\.cueID) == [a.id,c.id,d.id],"absolute AUTO")
        engine.tick(now:201.2)
        check(engine.records.count == 3,"AUTO never fires twice")
        engine.go(now:201.3)
        check(engine.current?.id == b.id && engine.complete,"manual queue catches pending cue")
        check(engine.liveStates.contains {$0.0 == "照明" && $0.1 == "fade"} && engine.liveStates.contains {$0.0 == "音響" && $0.1 == "stop"},"state carry-forward in execution order")
        engine.hold(now:201.3); engine.arm(true); engine.rewind(to:c.id)
        check(!engine.outputArmed && engine.records.map(\.cueID) == [a.id,b.id] && engine.next?.id == c.id,"rewind clears later records and disarms")
        let stalled = ShowEngine(seed:show)
        stalled.start(now:0); stalled.tick(now:0.2); stalled.tick(now:3)
        check(!stalled.running && stalled.records.isEmpty && abs(stalled.elapsed-0.2)<0.001,"suspend gap HOLD without catch-up")
        let overdue = ShowEngine(seed:Show(title:"Late",cues:[Cue(number:"1",title:"late",planned:1,trigger:.showTime)],endpoints:[]))
        overdue.start(now:0); overdue.tick(now:0.2); overdue.tick(now:1.9)
        check(!overdue.running && overdue.records.isEmpty,"overdue AUTO HOLD without burst")
        var invalid = show; invalid.cues[0].trigger = .afterCue; invalid.cues[0].anchorID = c.id
        rejects("forward/cyclic anchors rejected") {try invalid.validate()}
        var message = OSCMessage(endpointID:ep.id,address:"/test",arguments:[OSCArgument(type:"i",value:"-1"),OSCArgument(type:"f",value:"0.5"),OSCArgument(type:"s",value:"go")])
        let bytes = try OSC.encode(message)
        let expected: [UInt8] = [47,116,101,115,116,0,0,0,44,105,102,115,0,0,0,0,255,255,255,255,63,0,0,0,103,111,0,0]
        check(Array(bytes) == expected,"OSC wire layout, padding, big-endian int32/float32/string")
        message.arguments[0].value = "2147483648"
        rejects("int32 overflow rejected") {_ = try OSC.encode(message)}
        message.arguments[0].value = "1"; message.address = "/bad address"
        rejects("invalid OSC address rejected") {_ = try OSC.encode(message)}
        let fd = socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP); defer {close(fd)}
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; inet_pton(AF_INET,"127.0.0.1",&addr.sin_addr)
        let bound = withUnsafePointer(to:&addr) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        check(bound == 0,"local UDP receiver binds")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to:&addr) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {getsockname(fd,$0,&length)}}
        var timeout = timeval(tv_sec:1,tv_usec:0); setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        let loopback = Endpoint(name:"local",host:"127.0.0.1",port:Int(UInt16(bigEndian:addr.sin_port)))
        let packet = OSCMessage(endpointID:loopback.id,address:"/test",arguments:[OSCArgument(type:"i",value:"1")])
        var cue = a; cue.messages = [packet]
        let wireShow = Show(title:"UDP",cues:[cue],endpoints:[loopback])
        let live = ShowEngine(seed:wireShow); live.arm(true); live.start(now:0); live.go(now:0.1)
        var buffer = [UInt8](repeating:0,count:256)
        let size = recv(fd,&buffer,buffer.count,0)
        let wire = try OSC.encode(packet)
        check(size == wire.count && Array(buffer.prefix(max(0,size))) == Array(wire),"GO submits actual OSC UDP datagram on localhost")
        let dry = ShowEngine(seed:wireShow)
        var sends = 0; dry.sender = {_,_ in sends += 1}; dry.start(now:0); dry.go(now:0.1)
        check(sends == 0 && dry.records.count == 1,"rehearsal suppresses output but records event")
        let failure = ShowEngine(seed:wireShow); failure.sender = {_,_ in throw CueError.message("injected UDP failure")}
        failure.arm(true); failure.start(now:0); failure.go(now:0.1)
        check(!failure.running && !failure.outputArmed && failure.records.count == 1,"UDP failure HOLD, disarm, no automatic replay")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CueDeckTests-\(UUID())")
        defer {try? FileManager.default.removeItem(at:dir)}
        let saved = ShowEngine(seed:show,directory:dir,restore:false)
        saved.arm(true); saved.start(now:0); saved.go(now:0.1); saved.hold(now:0.4)
        let restored = ShowEngine(seed:show,directory:dir)
        check(!restored.running && !restored.outputArmed && restored.records.count == 1 && abs(restored.elapsed-0.4)<0.001,"disk restore retains progress, HOLD and OSC OFF")
        restored.reset()
        check(restored.elapsed == 0 && restored.records.isEmpty && !restored.outputArmed,"new run reset")
        let backups = try FileManager.default.contentsOfDirectory(atPath:dir.appendingPathComponent("RunBackups").path)
        check(backups.count == 1,"reset archives prior run")
        let unsaved = ShowEngine(seed:show)
        unsaved.networkEditPending = true; unsaved.start(now:0)
        check(!unsaved.running,"unsaved network changes block START")
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("CueDeckFailure-\(UUID())")
        defer {try? FileManager.default.removeItem(at:broken)}
        let protected = ShowEngine(seed:show,directory:broken,restore:false)
        protected.start(now:0); protected.go(now:0.1); protected.hold(now:0.2)
        try FileManager.default.removeItem(at:broken); try Data().write(to:broken)
        protected.reset()
        check(protected.records.count == 1 && protected.elapsed > 0,"failed backup prevents destructive reset")
        let undo = ShowEngine(seed:show)
        undo.start(now:0); undo.go(now:0.1); undo.tick(now:1.2); undo.tick(now:1.6); undo.hold(now:1.6)
        undo.arm(true); let undoElapsed = undo.elapsed
        undo.undoLastCue(); undo.undoLastCue()
        check(undo.records.map(\.cueID) == [a.id] && undo.next?.id == c.id && !undo.doneIDs.contains(b.id),"repeated undo preserves earlier pending manual cue")
        check(!undo.running && !undo.outputArmed && undo.elapsed == undoElapsed,"undo is HOLD, output OFF and preserves clock")
        check(undo.liveStates.contains {$0.0 == "照明" && $0.1 == "on"},"undo rebuilds department state")
        undo.start(now:10); undo.tick(now:10.2)
        check(undo.records.count == 1 && undo.running,"reverted automatic cues wait for manual GO")
        undo.go(now:10.3)
        check(undo.records.last?.cueID == c.id && undo.next?.id == d.id,"GO prioritizes reverted cue and then replay queue")
        undo.go(now:10.8)
        check(undo.records.last?.cueID == d.id && undo.next?.id == b.id,"replay queue then returns to earlier pending manual cue")
        let undoDisk = ShowEngine(seed:show,directory:dir)
        undoDisk.start(now:0); undoDisk.go(now:0.1); undoDisk.hold(now:0.2); undoDisk.undoLastCue()
        let undoRestored = ShowEngine(seed:show,directory:dir)
        check(undoRestored.replayIDs == [a.id] && undoRestored.next?.id == a.id,"replay wait survives disk restore")
        let importedText = "\u{FEFF}イベント名,開始時刻,音響,照明,メモ\r\n\"第1幕,開始\",00:10,\"音声\n再生\",明転,\"引用\"\"メモ\"\r\n,,停止,,補足\r\n"
        let imported = try SheetImport.decode(Data(importedText.utf8),filename:"新作品.csv",endpoints:[ep])
        check(imported.show.cues.count == 2 && imported.show.cues[0].title == "第1幕,開始" && imported.show.cues[0].planned == 10,"CSV import recognizes Japanese headers, BOM and quoted comma")
        check(imported.show.cues[0].actions["音響"] == "音声\n再生" && imported.show.cues[0].notes.contains("引用\"メモ"),"CSV embedded newline and escaped quote")
        check(imported.show.cues[1].title == "停止" && imported.show.cues.allSatisfy {$0.trigger == .manual && $0.messages.isEmpty},"blank-name technical row imported, manual with no OSC")
        let tsv = try SheetImport.decode(Data("event\tstart time\tSound state\nTest\t0:18:00\tplay".utf8),filename:"test.tsv",endpoints:[])
        check(tsv.show.cues.first?.planned == 1080,"TSV import and source-sheet style headers")
        rejects("CSV invalid planned time rejected before import") {_ = try SheetImport.decode(Data("イベント名,開始時刻\nTest,あした".utf8),filename:"bad.csv",endpoints:[])}
        rejects("CSV broken quoting rejected") {_ = try SheetImport.rows("イベント名\n\"unclosed",delimiter:",")}
        let sourceFile = URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("SourceSheet.json")
        let raw = try JSONSerialization.jsonObject(with:Data(contentsOf:sourceFile)) as! [String:Any]
        let sourceRows = raw["rows"] as! [[Any]]
        let sourceCSV = sourceRows.map { row in row.map {cell in
            let text = cell is NSNull ? "" : String(describing:cell)
            return "\"" + text.replacingOccurrences(of:"\"",with:"\"\"") + "\""
        }.joined(separator:",") }.joined(separator:"\n")
        let sourceImport = try SheetImport.decode(Data(sourceCSV.utf8),filename:"cue sheet.csv",endpoints:original.endpoints)
        check(sourceImport.show.cues.count == original.cues.count && zip(sourceImport.show.cues,original.cues).allSatisfy {$0.title == $1.title && $0.planned == $1.planned && $0.actions == $1.actions && $0.operatorCue == $1.operatorCue},"latest source sheet CSV round-trip preserves all 31 events and operator calls")
        let importDisk = ShowEngine(seed:show,directory:dir)
        let oldTitle = importDisk.show.title; importDisk.replace(with:imported.show)
        let projectBackups = try FileManager.default.contentsOfDirectory(at:dir.appendingPathComponent("ProjectBackups"),includingPropertiesForKeys:nil)
        let priorShow = try jsonDecoder.decode(Show.self,from:Data(contentsOf:projectBackups[0]))
        check(priorShow.title == oldTitle && importDisk.records.isEmpty && !importDisk.outputArmed,"import backs up complete prior project and resets progress safely")
        check(sourceImport.warnings.count == 2 && sourceImport.show.cues[4].planned == nil && sourceImport.show.cues[4].notes.contains("???"),"unknown times remain manual, unscheduled and preserved")
        check(sourceImport.show.cues.filter {$0.operatorCue != nil}.count == 23 && sourceImport.show.cues[8].actions["技術"] == "富士夫さん裏でmocap","latest operator and technical columns imported")
        check(original.cues[0].planned == -3600 && original.cues[1].planned == -1800 && original.initialElapsed == -3600,"updated sheet preserves signed preshow times")
        check(parseTime("-0:05:00",allowNegative:true) == -300 && parseTime("−1:00:00",allowNegative:true) == -3600 && parseTime("-5") == nil,"signed clock parsing, positive-only relative duration")
        let pre = ShowEngine(seed:original)
        pre.start(now:0); pre.go(now:0.1); pre.hold(now:0.2)
        check(pre.records.count == 1 && pre.elapsed < -3599 && pre.cueElapsed >= 0,"preshow clock and GO run with negative show time")
        pre.reset()
        check(pre.elapsed == -3600 && pre.records.isEmpty,"new run returns to preshow origin")
        let previewCues = [
            Cue(number:"1",title:"Sound only",actions:["音響":"play"]),
            Cue(number:"2",title:"Same light",actions:["照明":"on"]),
            Cue(number:"3",title:"Light down",actions:["照明":"off"]),
            Cue(number:"4",title:"Sound stop",actions:["音響":"stop"])
        ]
        let previews = StatePreview.make(current:["照明":"on","音響":"ready"],upcoming:previewCues)
        let lp = previews.first {$0.id == "照明"}!
        let sp = previews.first {$0.id == "音響"}!
        check(lp.changedKeys.isEmpty && lp.afterNext["照明"] == "on" && lp.upcomingCue?.number == "3","preview carries light state and skips repeated unchanged rows")
        check(sp.current["音響"] == "ready" && sp.afterNext["音響"] == "play" && sp.changedKeys.contains("音響"),"preview highlights next-GO sound change")
        let callOnly = Cue(number:"5",title:"Light command",actions:[:],operatorCue:"照明 : Q2\n音響 : Q3")
        let callPreview = StatePreview.make(current:["照明":"on"],upcoming:[callOnly])
        check(callPreview.first {$0.id == "照明"}?.upcomingCue?.id == callOnly.id,"department call without explicit state remains visible")
        let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("CueDeckLibrary-\(UUID())")
        defer {try? FileManager.default.removeItem(at:libraryRoot)}
        let legacy = ShowEngine(seed:show,directory:libraryRoot,restore:false)
        legacy.start(now:0); legacy.go(now:0.1); legacy.hold(now:0.3)
        let library = ProjectLibrary(root:libraryRoot)
        let managed = ShowEngine(seed:original,projectLibrary:library)
        let firstProject = managed.activeProjectID!
        check(managed.projects.count == 1 && managed.show.title == show.title && managed.records.count == 1 && abs(managed.elapsed-0.3)<0.001,"legacy project and progress migrate into project library")
        managed.createProject(name:"Second")
        let secondProject = managed.activeProjectID!
        check(secondProject != firstProject && managed.show.cues.isEmpty && managed.elapsed == 0 && !managed.outputArmed,"create blank project in same application")
        managed.addCue()
        managed.start(now:10); managed.go(now:10.1); managed.hold(now:10.4)
        managed.arm(true); managed.switchProject(firstProject)
        check(managed.records.count == 1 && abs(managed.elapsed-0.3)<0.001 && !managed.outputArmed && !managed.running,"switch restores independent progress and disarms output")
        managed.switchProject(secondProject)
        check(managed.records.count == 1 && managed.show.title == "Second" && abs(managed.elapsed-0.4)<0.001,"each project keeps separate clock and cue history")
        managed.start(now:20); managed.switchProject(firstProject)
        check(managed.activeProjectID == secondProject,"project switching blocked during operation")
        managed.hold(now:20)
        let reopen = ShowEngine(seed:original,projectLibrary:ProjectLibrary(root:libraryRoot))
        check(reopen.activeProjectID == secondProject && reopen.records.count == 1 && !reopen.running && !reopen.outputArmed,"last active project restores at relaunch in HOLD")
        let beforeSwitch = reopen.activeProjectID
        let badPath = library.directory(for:firstProject).appendingPathComponent("Runtime.json")
        try Data("broken runtime".utf8).write(to:badPath)
        reopen.switchProject(firstProject)
        check(reopen.activeProjectID == beforeSwitch && reopen.show.title == "Second","invalid target progress does not replace active project")
        let sheetURL = "https://docs.google.com/spreadsheets/d/1Bk0GYM1XBjNkqKEj1L7XB-GTgLlTTwNS6o5DWI-uUM8/edit?gid=0#gid=1587164916"
        let location = try SheetLocation(sheetURL)
        check(location.gid == "1587164916" && location.exportURL.absoluteString.contains("format=csv") && location.exportURL.absoluteString.contains("gid=1587164916"),"URL refresh selects fragment gid and CSV export")
        let published = try SheetLocation("https://docs.google.com/spreadsheets/d/e/2PACX-FAKE_PUBLISHED_ID/pubhtml?gid=10")
        check(published.published && published.exportURL.path.hasSuffix("/pub") && published.exportURL.absoluteString.contains("output=csv"),"published Google Sheet URL supported")
        rejects("non-Google URL rejected") {_ = try SheetLocation("https://docs.google.com.example.org/spreadsheets/d/1234567890/edit")}
        rejects("invalid gid rejected") {_ = try SheetLocation("https://docs.google.com/spreadsheets/d/1234567890/edit#gid=-1")}
        rejects("URL credentials rejected") {_ = try SheetLocation("https://user:pass@docs.google.com/spreadsheets/d/1234567890/edit")}
        rejects("private-sheet HTTP error is actionable") {try RemoteSheet.validateResponse(HTTPURLResponse(url:location.exportURL,statusCode:403,httpVersion:nil,headerFields:[:])!)}
        rejects("HTML login response rejected") {try RemoteSheet.validateResponse(HTTPURLResponse(url:location.exportURL,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"text/html"])!)}
        let fetchedTime = Date()
        let sameResult = RemoteSheetResult(location:location,imported:SheetImportResult(show:show,warnings:[]),fetchedAt:fetchedTime)
        let samePlan = try SheetUpdatePlan.make(baseline:show,projectID:nil,result:sameResult,preserveSettings:true)
        check(!samePlan.changed && samePlan.matched == 4,"unchanged sheet detected without resetting runtime")
        var withSettings = a; withSettings.operatorCue = "音響 : Q1"; withSettings.messages = [OSCMessage(endpointID:ep.id,address:"/cue/1")]
        let configured = Show(title:"Configured",cues:[withSettings,b,c],endpoints:[ep])
        var edited = withSettings; edited.id = UUID(); edited.title = "Renamed anchor"; edited.messages = []; edited.actions["音響"] = "new sound"
        var importedB = b; importedB.id = UUID()
        var importedC = c; importedC.id = UUID(); importedC.trigger = .manual; importedC.anchorID = nil
        let changedResult = RemoteSheetResult(location:location,imported:SheetImportResult(show:Show(title:"raw",cues:[edited,importedB,importedC],endpoints:[ep]),warnings:[]),fetchedAt:fetchedTime)
        let preserved = try SheetUpdatePlan.make(baseline:configured,projectID:nil,result:changedResult,preserveSettings:true)
        check(preserved.candidate.cues[0].id == a.id && preserved.candidate.cues[0].messages.count == 1 && preserved.candidate.cues[2].trigger == .afterCue && preserved.candidate.cues[2].anchorID == a.id,"unique operator cue matches renamed row and preserves OSC and relative anchors")
        check(preserved.candidate.cues[0].actions["音響"] == "new sound" && preserved.candidate.title == "Configured","sheet instructions update while project identity remains")
        let withoutSettings = try SheetUpdatePlan.make(baseline:configured,projectID:nil,result:changedResult,preserveSettings:false)
        check(withoutSettings.candidate.cues.allSatisfy {$0.messages.isEmpty && $0.trigger == .manual},"explicit option imports all-manual without OSC")
        let missingAnchor = RemoteSheetResult(location:location,imported:SheetImportResult(show:Show(title:"raw",cues:[importedC],endpoints:[ep]),warnings:[]),fetchedAt:fetchedTime)
        let orphan = try SheetUpdatePlan.make(baseline:configured,projectID:nil,result:missingAnchor,preserveSettings:true)
        check(orphan.candidate.cues[0].trigger == .manual && !orphan.warnings.isEmpty,"deleted relative anchor downgraded to manual with warning")
        let dup1 = Cue(number:"1",title:"Same",messages:[OSCMessage(endpointID:ep.id)])
        let dup2 = Cue(number:"2",title:"Same",messages:[OSCMessage(endpointID:ep.id)])
        let ambiguousBase = Show(title:"Ambiguous",cues:[dup1,dup2],endpoints:[ep])
        let ambiguousNew = Show(title:"raw",cues:[Cue(number:"1",title:"Same"),Cue(number:"2",title:"Same")],endpoints:[ep])
        let ambiguous = try SheetUpdatePlan.make(baseline:ambiguousBase,projectID:nil,result:RemoteSheetResult(location:location,imported:.init(show:ambiguousNew,warnings:[]),fetchedAt:fetchedTime),preserveSettings:true)
        check(ambiguous.matched == 0 && ambiguous.candidate.cues.allSatisfy {$0.messages.isEmpty},"ambiguous duplicate rows never receive old OSC settings")
        var otherCall = withSettings; otherCall.id = UUID(); otherCall.operatorCue = "音響 : Q99"; otherCall.messages = []
        let conflict = try SheetUpdatePlan.make(baseline:Show(title:"base",cues:[withSettings],endpoints:[ep]),projectID:nil,result:RemoteSheetResult(location:location,imported:.init(show:Show(title:"new",cues:[otherCall],endpoints:[ep]),warnings:[]),fetchedAt:fetchedTime),preserveSettings:true)
        check(conflict.matched == 0 && conflict.candidate.cues[0].messages.isEmpty,"conflicting operator calls do not match by title alone")
        let refreshEngine = ShowEngine(seed:show)
        refreshEngine.start(now:0); refreshEngine.go(now:0.1); refreshEngine.hold(now:0.3)
        let beforeRefresh = refreshEngine.elapsed
        refreshEngine.sheetUpdateBusy = true
        refreshEngine.start(now:1)
        check(!refreshEngine.running,"START blocked while refresh review is open")
        check(refreshEngine.applySheetUpdate(samePlan) && refreshEngine.records.count == 1 && refreshEngine.elapsed == beforeRefresh && refreshEngine.show.sourceCheckedAt != nil,"no-change refresh saves timestamp and keeps progress")
        let freshBase = refreshEngine.show
        let freshPlan = try SheetUpdatePlan.make(baseline:freshBase,projectID:nil,result:changedResult,preserveSettings:true)
        check(refreshEngine.applySheetUpdate(freshPlan) && refreshEngine.records.isEmpty && !refreshEngine.outputArmed && refreshEngine.show.sourceUpdatedAt != nil,"changed refresh resets runtime and stores applied timestamp")
        let stalePlan = try SheetUpdatePlan.make(baseline:show,projectID:nil,result:sameResult,preserveSettings:true)
        let beforeStale = refreshEngine.show
        check(!refreshEngine.applySheetUpdate(stalePlan) && refreshEngine.show == beforeStale,"stale refresh cannot overwrite newly edited project")
        let registerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("CueDeckURL-\(UUID())")
        defer {try? FileManager.default.removeItem(at:registerRoot)}
        let registered = ShowEngine(seed:show,directory:registerRoot,restore:false)
        check(registered.registerSourceURL(sheetURL),"register URL for project")
        let registeredReload = ShowEngine(seed:show,directory:registerRoot)
        check(registeredReload.show.sourceURL == location.canonicalURL.absoluteString,"registered URL persists across relaunch")
        print("VERIFIED \(count) critical checks")
    }
}
