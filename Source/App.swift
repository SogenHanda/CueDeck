import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Palette {
    static let background = Color(red:0.043,green:0.047,blue:0.055)
    static let surface = Color(red:0.075,green:0.082,blue:0.095)
    static let raised = Color(red:0.10,green:0.11,blue:0.13)
    static let line = Color.white.opacity(0.10)
    static let muted = Color(red:0.61,green:0.64,blue:0.69)
    static let accent = Color(red:0.76,green:0.95,blue:0.48)
    static let amber = Color(red:1.0,green:0.75,blue:0.35)
}
@MainActor func confirm(_ title: String, _ detail: String, action: String = "実行") -> Bool {
    let a = NSAlert(); a.messageText = title; a.informativeText = detail
    a.alertStyle = .warning; a.addButton(withTitle:action); a.addButton(withTitle:"キャンセル")
    return a.runModal() == .alertFirstButtonReturn
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: ShowEngine?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if let engine, engine.hasPendingEdits, !confirm("未保存の編集があります","編集を破棄して終了しますか？",action:"破棄して終了") { return .terminateCancel }
            if let engine, engine.running {
                guard confirm("上演を停止して終了しますか？","進行を保存し、次回はHOLD・OSC出力OFFで復帰します。",action:"終了") else { return .terminateCancel }
                engine.hold(reason:"アプリ終了")
            }
            if let engine, !engine.saveRuntime() {
                return confirm("進行を保存できません","保存エラーがあります。このまま終了しますか？",action:"保存せず終了") ? .terminateNow : .terminateCancel
            }
            return .terminateNow
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct CueDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var engine: ShowEngine
    init() {
        let url = Bundle.main.url(forResource:"Show",withExtension:"json")!
        let seed = try! jsonDecoder.decode(Show.self,from:Data(contentsOf:url))
        let root = ProcessInfo.processInfo.environment["CUEDECK_DATA_DIRECTORY"].map {URL(fileURLWithPath:$0)} ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CueDeck")
        _engine = StateObject(wrappedValue:ShowEngine(seed:seed,projectLibrary:ProjectLibrary(root:root)))
    }
    var body: some Scene {
        Window("CueDeck",id:"main") {
            RootView(engine:engine)
                .preferredColorScheme(.dark)
                .onAppear { delegate.engine = engine; NSApp.activate(ignoringOtherApps:true) }
        }
        .defaultSize(width:1490,height:960)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing:.newItem) {}
            CommandGroup(after:.saveItem) {
                Button("作品を書き出す…") { FileActions.exportShow(engine) }.keyboardShortcut("s",modifiers:[.command,.shift])
                Button("この作品をJSONで更新…") { FileActions.importShow(engine) }.disabled(engine.running)
                Button("この作品をCSV / TSVで更新…") { FileActions.importSheet(engine) }.disabled(engine.running)
                Button("実行ログを書き出す…") { FileActions.exportLog(engine) }
            }
        }
    }
}
enum FileActions {
    @MainActor static func exportShow(_ engine: ShowEngine) {
        guard !engine.hasPendingEdits else { engine.alert = "先に編集を保存または破棄してから書き出してください。"; return }
        let p = NSSavePanel(); p.allowedContentTypes = [.json]; p.nameFieldStringValue = engine.show.title + ".cuedeck.json"
        if p.runModal() == .OK, let url = p.url {
            do { try jsonEncoder.encode(engine.show).write(to:url,options:.atomic); engine.log("作品書き出し \(url.lastPathComponent)") } catch { engine.alert = error.localizedDescription }
        }
    }
    @MainActor static func importShow(_ engine: ShowEngine, asNewProject: Bool = false) {
        guard !engine.running, !engine.sheetUpdateBusy else { return }
        if engine.hasPendingEdits, !confirm("未保存の編集があります","作品を読み込むと編集が破棄されます。続けますか？",action:"続ける") { return }
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url {
            do {
                let data = try Data(contentsOf:url)
                guard data.count <= 20_000_000 else { throw CueError.message("ファイルが大きすぎます。") }
                let show = try jsonDecoder.decode(Show.self,from:data); try show.validate()
                if asNewProject {engine.createProject(name:show.title,from:show)}
                else if confirm("現在の作品を更新しますか？","作品と進行をバックアップし、読み込む内容を未実行の状態で開きます。",action:"更新") {engine.replace(with:show)}
            } catch { engine.alert = error.localizedDescription }
        }
    }
    @MainActor static func importSheet(_ engine: ShowEngine, asNewProject: Bool = false) {
        guard !engine.running, !engine.sheetUpdateBusy else {return}
        guard !engine.hasPendingEdits else {engine.alert = "先に編集を保存または破棄してから取り込んでください。"; return}
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText,.tabSeparatedText,.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "GoogleスプレッドシートからダウンロードしたUTF-8のCSV / TSVを選択してください。"
        guard panel.runModal() == .OK, let url = panel.url else {return}
        do {
            let result = try SheetImport.decode(Data(contentsOf:url),filename:url.lastPathComponent,endpoints:engine.show.endpoints)
            let alert = NSAlert(); alert.messageText = asNewProject ? "新しいプロジェクトとして取り込みますか？" : "現在の作品をシートで更新しますか？"
            var detail = "\(result.show.cues.count)件のイベント。全CUEを手動・未実行・OSC出力OFFで読み込みます。\n現在の作品と進行はバックアップします。OSCメッセージと自動実行設定は引き継ぎません。"
            if !result.warnings.isEmpty {detail += "\n\n" + result.warnings.prefix(8).joined(separator:"\n")}
            alert.informativeText = detail
            let title = NSTextField(string:result.show.title); title.frame = NSRect(x:0,y:0,width:400,height:26)
            title.placeholderString = "作品名"; alert.accessoryView = title
            alert.addButton(withTitle:"取り込む"); alert.addButton(withTitle:"キャンセル")
            if alert.runModal() == .alertFirstButtonReturn {
                var candidate = result.show; candidate.title = title.stringValue
                try candidate.validate()
                if asNewProject {engine.createProject(name:candidate.title,from:candidate)} else {engine.replace(with:candidate)}
            }
        } catch {engine.alert = error.localizedDescription}
    }
    @MainActor static func exportLog(_ engine: ShowEngine) {
        let p = NSSavePanel(); p.allowedContentTypes = [.commaSeparatedText]; p.nameFieldStringValue = "CueDeck-実行ログ.csv"
        if p.runModal() == .OK, let url = p.url {
            do { try engine.logCSV().write(to:url,atomically:true,encoding:.utf8) } catch { engine.alert = error.localizedDescription }
        }
    }
}
private struct SheetUpdateRequest: Identifiable {
    let id = UUID()
    let autoFetch: Bool
}
struct RootView: View {
    @ObservedObject var engine: ShowEngine
    @State private var inspector = false
    @State private var projectManager = false
    @State private var sheetUpdate: SheetUpdateRequest?
    @State private var draft: Cue?
    @State private var stateFilter = "全担当"
    @State private var clockInput = ""
    @State private var clockSheet = false
    @State private var preventSleep: NSObjectProtocol?
    @State private var keyMonitor: Any?
    @State private var activity: NSObjectProtocol?
    private let timer = Timer.publish(every:0.05,on:.main,in:.common).autoconnect()
    var dirty: Bool { draft != engine.selected }
    var body: some View {
        VStack(spacing:0) {
            header
            Rectangle().fill(Palette.line).frame(height:1)
            if !engine.banner.isEmpty {
                HStack(spacing:10) {
                    Image(systemName:"info.circle.fill").foregroundStyle(Palette.amber)
                    Text(engine.banner).font(.system(size:12))
                    Spacer()
                    Button { engine.banner = "" } label: {Image(systemName:"xmark")}.buttonStyle(.plain)
                }.padding(.horizontal,20).padding(.vertical,10).background(Palette.amber.opacity(0.10))
            }
            HStack(spacing:0) {
                cueList.frame(width:274)
                Rectangle().fill(Palette.line).frame(width:1)
                dashboard.frame(minWidth:540,maxWidth:.infinity,maxHeight:.infinity)
                if inspector {
                    Rectangle().fill(Palette.line).frame(width:1)
                    inspectorView.frame(width:338)
                }
            }
            footer
        }
        .background(Palette.background)
        .foregroundStyle(Color.white.opacity(0.94))
        .frame(minWidth:inspector ? 1200 : 880,minHeight:760)
        .onReceive(timer) { _ in engine.tick() }
        .onAppear {
            draft = engine.selected
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { event in
                let consume: Bool = MainActor.assumeIsolated {
                    guard NSApp.keyWindow != nil, NSApp.modalWindow == nil, !clockSheet, !projectManager, sheetUpdate == nil,
                          !(NSApp.keyWindow?.firstResponder is NSTextView),
                          event.modifierFlags.intersection([.command,.option,.control]).isEmpty else { return false }
                    if event.keyCode == 53 { if engine.running { engine.hold() }; return true }
                    if event.keyCode == 49, !event.isARepeat { engine.go(); return true }
                    return false
                }
                return consume ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
        }
        .onChange(of:engine.running) { _, running in
            if running {
                activity = ProcessInfo.processInfo.beginActivity(options:[.idleSystemSleepDisabled,.userInitiated],reason:"CueDeck show operation")
            } else if let activity {
                ProcessInfo.processInfo.endActivity(activity); self.activity = nil
            }
        }
        .onChange(of:dirty) { _,value in engine.cueEditPending = value }
        .onChange(of:engine.selectedID) { _, _ in draft = engine.selected }
        .onChange(of:engine.show) { _, _ in if !dirty { draft = engine.selected } }
        .alert("確認",isPresented:Binding(get:{engine.alert != nil},set:{if !$0 {engine.alert = nil}})) {
            Button("OK",role:.cancel) { engine.alert = nil }
        } message: { Text(engine.alert ?? "") }
        .sheet(item:$sheetUpdate) {request in SheetUpdateView(engine:engine,autoFetch:request.autoFetch)}
        .sheet(isPresented:$projectManager) {ProjectManager(engine:engine)}
        .sheet(isPresented:$clockSheet) {
            VStack(alignment:.leading,spacing:20) {
                Text("上演時計を調整").font(.title2.bold())
                Text("実行済みCUEの時刻より前には戻せません。自動CUEの発火時刻にも影響します。").foregroundStyle(Palette.muted)
                TextField("HH:MM:SS または秒",text:$clockInput).textFieldStyle(.roundedBorder)
                HStack {
                    Button("キャンセル") { clockSheet = false }
                    Spacer()
                    Button("適用") {
                        if let seconds = parseTime(clockInput,allowNegative:true) { engine.setElapsed(seconds); clockSheet = false }
                        else { engine.alert = "時刻は HH:MM:SS、MM:SS または秒で入力してください。" }
                    }.buttonStyle(ActionButtonStyle(color:Palette.accent))
                }
            }.padding(28).frame(width:430).preferredColorScheme(.dark)
        }
    }
    func abandonDraft() -> Bool {
        !dirty || confirm("未保存のCUE編集があります","変更を破棄して続けますか？",action:"破棄して続ける")
    }
    func choose(_ id: UUID) {
        if engine.selectedID != id, abandonDraft() { engine.selectedID = id }
    }
    var header: some View {
        HStack(spacing:18) {
            HStack(spacing:9) {
                RoundedRectangle(cornerRadius:3).fill(Palette.accent).frame(width:9,height:25)
                Text("CUE DECK").font(.system(size:17,weight:.black,design:.rounded)).tracking(2)
            }
            Rectangle().fill(Palette.line).frame(width:1,height:25)
            VStack(alignment:.leading,spacing:3) {
                Button {projectManager = true} label: {HStack(spacing:8) {Image(systemName:"folder"); Text(engine.show.title).lineLimit(1); Image(systemName:"chevron.down").font(.system(size:9))}}.buttonStyle(.plain).font(.system(size:14,weight:.semibold)).help("プロジェクトを作成・切り替え")
                Text("PROJECT  /  SHOW CONTROL").font(.system(size:9,weight:.medium,design:.monospaced)).tracking(1.3).foregroundStyle(Palette.muted)
            }
            Spacer(minLength:8)
            Button {
                sheetUpdate = SheetUpdateRequest(autoFetch:!engine.show.sourceURL.isEmpty)
            } label: {Label("シートを更新",systemImage:"arrow.clockwise").font(.system(size:12,weight:.semibold))}
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
                .disabled(engine.running || engine.hasPendingEdits || engine.sheetUpdateBusy)
            Button {sheetUpdate = SheetUpdateRequest(autoFetch:false)} label: {Image(systemName:"link").font(.system(size:14))}
                .buttonStyle(.plain).help("このプロジェクトのシートURLを登録・変更").disabled(engine.running || engine.hasPendingEdits || engine.sheetUpdateBusy)
            HStack(spacing:6) {
                Circle().fill(engine.outputArmed ? Palette.amber : Palette.muted).frame(width:6,height:6)
                Text(engine.outputArmed ? "OSC OUTPUT ON" : "OSC OUTPUT OFF").font(.system(size:10,weight:.bold,design:.monospaced))
            }.padding(.horizontal,12).padding(.vertical,8).background(engine.outputArmed ? Palette.amber.opacity(0.12) : Palette.raised,in:Capsule())
            Button { inspector.toggle() } label: {Image(systemName:"sidebar.right").font(.system(size:17))}.buttonStyle(.plain).help("編集・ネットワーク・ログ")
            Menu {
                Button("プロジェクトを作成・切り替え…") {projectManager = true}
                Button("シートURLを登録・変更…") {sheetUpdate = SheetUpdateRequest(autoFetch:false)}.disabled(engine.running || engine.hasPendingEdits || engine.sheetUpdateBusy)
                Divider()
                Button("作品を書き出す…") { FileActions.exportShow(engine) }
                Button("この作品をJSONで更新…") { if abandonDraft() { FileActions.importShow(engine) } }.disabled(engine.running)
                Button("この作品をCSV / TSVで更新…") { FileActions.importSheet(engine) }.disabled(engine.running)
                Button("実行ログを書き出す…") { FileActions.exportLog(engine) }
                Divider()
                Button("新しい上演 / リセット…") {
                    if abandonDraft(), confirm("上演をリセットしますか？","時計・実行済み状態を初期化します。前回の進行はローカルにバックアップします。",action:"リセット") { engine.reset() }
                }.disabled(engine.running)
                Button("同梱の最新CUEシートで更新…") {
                    if abandonDraft(), confirm("同梱のCUEシートで更新しますか？","現在の作品と進行をバックアップして差し替えます。",action:"更新"), let url = Bundle.main.url(forResource:"Show",withExtension:"json"), let data = try? Data(contentsOf:url), let show = try? jsonDecoder.decode(Show.self,from:data) { engine.replace(with:show); draft = engine.selected }
                }.disabled(engine.running)
                Divider()
                Button("操作ガイドを開く") {
                    if let url = Bundle.main.url(forResource:"Guide",withExtension:"html") { NSWorkspace.shared.open(url) }
                }
            } label: {Image(systemName:"ellipsis.circle").font(.system(size:18))}
            .menuStyle(.borderlessButton).fixedSize()
        }.padding(.leading,80).padding(.trailing,22).frame(height:70)
    }
    var cueList: some View {
        VStack(spacing:0) {
            HStack {
                eyebrow("RUN OF SHOW")
                Spacer()
                Text("\(engine.show.cues.count) EVENTS").font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.muted)
            }.padding(.horizontal,18).padding(.top,22).padding(.bottom,14)
            HStack(spacing:8) {
                Image(systemName:"magnifyingglass").foregroundStyle(Palette.muted)
                TextField("CUE・担当を検索",text:$engine.search).textFieldStyle(.plain).font(.system(size:12))
                if !engine.search.isEmpty { Button {engine.search = ""} label: {Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain) }
            }.padding(10).background(Palette.raised,in:RoundedRectangle(cornerRadius:7)).padding(.horizontal,14).padding(.bottom,10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing:3) {
                        ForEach(engine.show.cues.filter {cue in engine.search.isEmpty || (cue.number+" "+cue.title+" "+cue.actions.map {"\($0.key) \($0.value)"}.joined(separator:" ")).localizedCaseInsensitiveContains(engine.search)}) { cue in
                            cueRow(cue).id(cue.id)
                        }
                    }.padding(.horizontal,9).padding(.vertical,4)
                }
                HStack {
                    Button("次のCUEへ") { if let next = engine.next { engine.search = ""; choose(next.id); withAnimation {proxy.scrollTo(next.id,anchor:.center)} } }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                    Spacer()
                    Text("\(engine.firedCount) 実行済").foregroundStyle(Palette.muted)
                }.font(.system(size:11)).padding(16)
            }
            HStack(spacing:12) {
                Button {if abandonDraft() {engine.addCue(); draft = engine.selected}} label: {Label("追加",systemImage:"plus")}
                Button {if abandonDraft() {engine.addCue(copy:true); draft = engine.selected}} label: {Image(systemName:"doc.on.doc")}
                Spacer()
                Button {if abandonDraft() {engine.moveSelected(-1); draft = engine.selected}} label: {Image(systemName:"arrow.up")}
                Button {if abandonDraft() {engine.moveSelected(1); draft = engine.selected}} label: {Image(systemName:"arrow.down")}
            }.buttonStyle(.plain).font(.system(size:12)).padding(16).background(Palette.surface).disabled(engine.running)
        }.background(Palette.surface.opacity(0.5))
    }
    func cueRow(_ cue: Cue) -> some View {
        let fired = engine.records.contains {$0.cueID == cue.id}
        let skipped = engine.skipped.contains(cue.id)
        let isNext = engine.next?.id == cue.id
        let selected = engine.selectedID == cue.id
        return Button {choose(cue.id)} label: {
            HStack(alignment:.top,spacing:11) {
                VStack(spacing:7) {
                    Text(cue.number).font(.system(size:13,weight:.bold,design:.monospaced))
                    Image(systemName:fired ? "checkmark.circle.fill" : skipped ? "forward.end.circle" : isNext ? "arrowtriangle.right.fill" : "circle")
                        .font(.system(size:10)).foregroundStyle(fired ? Palette.accent : isNext ? Palette.amber : Palette.muted.opacity(0.45))
                }.frame(width:28).padding(.top,1)
                VStack(alignment:.leading,spacing:7) {
                    Text(cue.title.replacingOccurrences(of:"\n",with:" ")).font(.system(size:12,weight:selected || isNext ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing:7) {
                        Text(cue.planned.map {timeText($0)} ?? "時刻未定").font(.system(size:10,design:.monospaced))
                        Text(cue.trigger == .manual ? "MANUAL" : "AUTO").font(.system(size:8,weight:.bold,design:.monospaced)).padding(.horizontal,4).padding(.vertical,2).background(cue.trigger == .manual ? Color.white.opacity(0.06) : Palette.accent.opacity(0.13),in:RoundedRectangle(cornerRadius:3))
                        if isNext {Text("NEXT").font(.system(size:8,weight:.bold)).foregroundStyle(Palette.amber)}
                    }.foregroundStyle(Palette.muted)
                }
                Spacer(minLength:0)
            }.padding(.horizontal,10).padding(.vertical,12)
                .background(selected ? Color.white.opacity(0.075) : Color.clear,in:RoundedRectangle(cornerRadius:8))
                .overlay(alignment:.leading) {if isNext {RoundedRectangle(cornerRadius:2).fill(Palette.amber).frame(width:2).padding(.vertical,9)}}
                .opacity(fired || skipped ? 0.52 : 1)
        }.buttonStyle(.plain)
    }
    var currentTimingDescription: String {
        guard let last = engine.records.last else { return "上演時計を開始し、GOで最初のイベントへ。" }
        var result = "実行 " + timeText(last.showTime) + "  /  " + last.origin
        if engine.records.count >= 2 {
            let previous = engine.records[engine.records.count-2]
            result += "  /  前CUEとの間隔 " + timeText(last.showTime-previous.showTime)
        }
        return result
    }
    var dashboard: some View {
        VStack(spacing:0) {
            OperationDashboard(engine:engine,filter:$stateFilter)
            transport
        }
    }
    var transport: some View {
        VStack(spacing:12) {
            HStack(spacing:12) {
                if engine.running {
                    Button {engine.hold()} label: {VStack(spacing:6) {Image(systemName:"pause.fill"); Text("HOLD").font(.system(size:11,weight:.bold,design:.monospaced))}.frame(width:82,height:72)}
                        .buttonStyle(ActionButtonStyle(color:Palette.amber,filled:false)).help("Esc")
                } else {
                    Button {
                        guard !dirty else {engine.alert = "先にCUE編集を保存または破棄してください。"; return}
                        engine.start()
                    } label: {VStack(spacing:6) {Image(systemName:"play.fill"); Text(engine.records.isEmpty && engine.elapsed == engine.show.initialElapsed ? "START" : "RESUME").font(.system(size:10,weight:.bold,design:.monospaced))}.frame(width:82,height:72)}
                    .buttonStyle(ActionButtonStyle(color:Palette.accent,filled:false))
                }
                Button {engine.go()} label: {
                    HStack(spacing:14) {
                        VStack(alignment:.leading,spacing:5) {
                            Text("GO").font(.system(size:30,weight:.black,design:.rounded)).tracking(2)
                            Text(engine.running ? "SPACE  /  次のCUEを実行" : "先に START / RESUME").font(.system(size:10,weight:.semibold))
                        }
                        Spacer()
                        Text(engine.next?.number ?? "—").font(.system(size:32,weight:.medium,design:.monospaced))
                        Image(systemName:"arrow.right").font(.system(size:22))
                    }.padding(.horizontal,22).frame(maxWidth:.infinity).frame(height:72)
                }.buttonStyle(ActionButtonStyle(color:Palette.accent)).disabled(!engine.running || engine.complete)
            }
            HStack {
                Button {
                    guard !engine.hasPendingEdits else {engine.alert = "先に編集を保存または破棄してください。"; return}
                    if engine.running {engine.hold(reason:"戻す操作のためHOLD")}
                    guard let cue = engine.current else {return}
                    if confirm("CUE \(cue.number) の実行を取り消しますか？","直前のCUEを次のGOで再実行できる状態に戻します。時計は維持し、OSC出力をOFFにします。外部機器の状態は戻りません。",action:"1つ戻す") {engine.undoLastCue()}
                } label: {Label("1つ戻す",systemImage:"backward.end.fill")}
                    .buttonStyle(.plain).font(.system(size:11,weight:.semibold)).foregroundStyle(Palette.amber).disabled(engine.records.isEmpty)
                Text("GOはNEXTのCUEを実行").font(.system(size:10)).foregroundStyle(Palette.muted)
                Spacer()
                Button("スキップ…") {
                    if confirm("次のCUEをスキップしますか？","状態の更新とOSC送信は行いません。",action:"スキップ") {engine.skipNext()}
                }.buttonStyle(.plain).font(.system(size:10)).foregroundStyle(Palette.muted).disabled(engine.running || engine.complete)
            }
        }.padding(.horizontal,26).padding(.vertical,18).background(Palette.surface).overlay(alignment:.top) {Rectangle().fill(Palette.line).frame(height:1)}
    }
    var inspectorView: some View {
        VStack(spacing:0) {
            Picker("",selection:Binding(get:{engine.panel},set:{value in
                if engine.panel == "OSC" && engine.networkEditPending {
                    guard confirm("未保存のOSC設定があります","変更を破棄して表示を切り替えますか？",action:"破棄して続ける") else { return }
                    engine.networkEditPending = false
                }
                engine.panel = value
            })) {
                Text("CUE編集").tag("CUE編集"); Text("OSC").tag("OSC"); Text("ログ").tag("ログ")
            }.pickerStyle(.segmented).labelsHidden().padding(16)
            if engine.panel == "CUE編集" {
                if let cue = draft {
                    CueEditor(engine:engine,draft:Binding(get:{draft ?? cue},set:{draft = $0}),dirty:dirty,onSave:{engine.updateCue(draft!); if engine.alert == nil {draft = engine.selected}})
                    HStack {
                        Button("破棄") {draft = engine.selected}.disabled(!dirty)
                        Spacer()
                        Menu {
                            Button("選択CUEをHOLD中に実行…") {
                                if abandonDraft(), confirm("選択CUEを実行しますか？","上演時計は進めません。OSC出力ONの場合は実際に送信します。",action:"実行") {engine.manualSelected()}
                            }.disabled(engine.doneIDs.contains(cue.id))
                            Button("ここから再開 / ジャンプ…") {
                                if abandonDraft(), confirm("CUE \(cue.number) にジャンプしますか？","この行以降を未実行に戻します。以前の未実行行はスキップし、OSC出力をOFFにします。時計は維持します。",action:"ジャンプ") {engine.rewind(to:cue.id)}
                            }
                            Button("削除…",role:.destructive) {if confirm("CUEを削除しますか？",cue.title,action:"削除") {engine.deleteSelected(); draft = engine.selected}}
                        } label: {Text("その他").font(.system(size:11))}
                    }.padding(16).disabled(engine.running)
                } else {Spacer(); Text("CUEを選択してください").foregroundStyle(Palette.muted); Spacer()}
            } else if engine.panel == "OSC" {NetworkEditor(engine:engine)}
            else {LogView(engine:engine)}
        }.background(Palette.surface.opacity(0.55))
    }
    var footer: some View {
        HStack(spacing:16) {
            HStack(spacing:5) {Circle().fill(Palette.accent).frame(width:4,height:4); Text("LOCAL / OFFLINE")}
            Text(engine.dirtyDescription)
            Spacer()
            if dirty {Text("CUE編集 未保存").foregroundStyle(Palette.amber)}
            Button("時計を調整") {clockInput = String(Int(engine.elapsed)); clockSheet = true}.buttonStyle(.plain).disabled(engine.running)
            Text("SPACE  GO    ESC  HOLD")
        }.font(.system(size:9,weight:.medium,design:.monospaced)).foregroundStyle(Palette.muted)
            .padding(.horizontal,20).frame(height:31).background(Palette.background).overlay(alignment:.top) {Rectangle().fill(Palette.line).frame(height:1)}
    }
}
func eyebrow(_ text: String, color: Color = Palette.muted) -> some View {
    Text(text).font(.system(size:10,weight:.semibold,design:.monospaced)).tracking(1.4).foregroundStyle(color)
}
struct ActionButtonStyle: ButtonStyle {
    var color: Color
    var filled = true
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(filled ? Palette.background : color)
            .background(filled ? color : color.opacity(0.08),in:RoundedRectangle(cornerRadius:9))
            .overlay(RoundedRectangle(cornerRadius:9).stroke(filled ? Color.clear : color.opacity(0.35)))
            .opacity(!enabled ? 0.25 : configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius:9))
    }
}
