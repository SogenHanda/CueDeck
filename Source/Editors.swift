import SwiftUI
import AppKit

struct CueEditor: View {
    @ObservedObject var engine: ShowEngine
    @Binding var draft: Cue
    let dirty: Bool
    let onSave: () -> Void
    @State private var statesOpen = true
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:19) {
                HStack {
                    eyebrow("EVENT DETAILS")
                    Spacer()
                    if engine.running {Label("HOLDで編集",systemImage:"lock.fill").font(.system(size:10)).foregroundStyle(Palette.amber)}
                }
                VStack(alignment:.leading,spacing:8) {
                    fieldLabel("CUE番号")
                    TextField("01",text:$draft.number)
                    fieldLabel("イベント名")
                    TextEditor(text:$draft.title).font(.system(size:13)).frame(height:80).scrollContentBackground(.hidden).padding(7).background(Palette.raised,in:RoundedRectangle(cornerRadius:6))
                    fieldLabel("進行CUE / sogen cue")
                    TextField("照明 : Q1",text:Binding(get:{draft.operatorCue ?? ""},set:{draft.operatorCue = $0.isEmpty ? nil : $0}),axis:.vertical)
                }
                Divider()
                VStack(alignment:.leading,spacing:11) {
                    fieldLabel("実行方法")
                    Picker("",selection:$draft.trigger) {ForEach(Trigger.allCases,id:\.self) {Text($0.label).tag($0)}}.labelsHidden()
                    SecondsField(label:"予定時刻",value:$draft.planned,allowNegative:true)
                    if draft.trigger == .afterCue {
                        Picker("基準CUE",selection:$draft.anchorID) {
                            Text("選択してください").tag(nil as UUID?)
                            ForEach(engine.show.cues.prefix(while: {$0.id != draft.id})) {cue in
                                Text(cue.number+"  "+cue.title.replacingOccurrences(of:"\n",with:" ").prefix(25)).tag(cue.id as UUID?)
                            }
                        }
                        SecondsField(label:"基準CUEから",value:Binding(get:{draft.delay},set:{draft.delay = $0 ?? 0}),allowEmpty:false)
                    }
                    Text(draft.trigger == .manual ? "予定時刻は目安です。GOで実行します。" : draft.trigger == .showTime ? "上演時計が予定時刻に到達すると実行します。手動CUEの待機中も発火します。" : "基準CUEが実際に実行されてから計時します。HOLD中は停止します。")
                        .font(.system(size:11)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
                }
                Divider()
                DisclosureGroup(isExpanded:$statesOpen) {
                    VStack(alignment:.leading,spacing:13) {
                        Text("空欄は前の状態を引き継ぎます。明示的に終了する場合は「終了」などを入力。").font(.system(size:10)).foregroundStyle(Palette.muted)
                        ForEach(departmentOrder + draft.actions.keys.filter {!departmentOrder.contains($0)}.sorted(),id:\.self) {key in
                            VStack(alignment:.leading,spacing:5) {
                                fieldLabel(key)
                                TextField("引き継ぎ",text:Binding(get:{draft.actions[key] ?? ""},set:{draft.actions[key] = $0}),axis:.vertical).lineLimit(1...6)
                            }
                        }
                    }.padding(.top,12)
                } label: {fieldLabel("担当の状態")}
                Divider()
                VStack(alignment:.leading,spacing:8) {
                    fieldLabel("メモ / 元シート参照")
                    TextEditor(text:$draft.notes).font(.system(size:11)).frame(height:85).scrollContentBackground(.hidden).padding(7).background(Palette.raised,in:RoundedRectangle(cornerRadius:6))
                }
                Divider()
                VStack(alignment:.leading,spacing:12) {
                    HStack {eyebrow("OSC MESSAGES"); Spacer(); Text("\(draft.messages.count)").foregroundStyle(Palette.muted).font(.system(size:11))}
                    ForEach($draft.messages) {$message in
                        MessageEditor(message:$message,endpoints:engine.show.endpoints,onDelete:{draft.messages.removeAll {$0.id == message.id}},onTest:{
                            if confirm("OSCテストを送信しますか？","\(message.address)\n受信機が動作する可能性があります。",action:"送信") {engine.testMessage(message)}
                        },canTest:engine.outputArmed && !engine.running)
                    }
                    Button {
                        if let first = engine.show.endpoints.first {draft.messages.append(OSCMessage(endpointID:first.id))}
                        else {engine.alert = "先にOSCタブで送信先を追加してください。"}
                    } label: {Label("OSCメッセージを追加",systemImage:"plus")}.font(.system(size:11))
                    Text("受信アプリのOSC仕様に合わせて設定してください。初期データにはメッセージを設定していません。").font(.system(size:10)).foregroundStyle(Palette.muted)
                }
            }.padding(18).disabled(engine.running).textFieldStyle(.roundedBorder)
        }
        Button(action:onSave) {
            HStack {Image(systemName:"checkmark"); Text(dirty ? "変更を保存" : "保存済み").fontWeight(.semibold); Spacer(); Text("CUE "+draft.number).font(.system(size:11,design:.monospaced))}
                .padding(.horizontal,14).frame(height:42)
        }.buttonStyle(ActionButtonStyle(color:Palette.accent)).padding(.horizontal,16).padding(.top,10).disabled(engine.running || !dirty)
    }
}
func fieldLabel(_ value: String) -> some View {
    Text(value).font(.system(size:11,weight:.medium)).foregroundStyle(Palette.muted)
}
struct SecondsField: View {
    let label: String
    @Binding var value: Double?
    var allowEmpty = true
    var allowNegative = false
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {fieldLabel(label); Spacer(); Text("HH:MM:SS / MM:SS / 秒").font(.system(size:9)).foregroundStyle(Palette.muted)}
            TextField(allowEmpty ? "時刻未定" : "0",text:$text)
                .focused($focused).font(.system(size:12,design:.monospaced))
                .onAppear {text = value.map {String(format:"%.3f",$0)} ?? ""}
                .onChange(of:text) {_,new in
                    if new.trimmingCharacters(in:.whitespaces).isEmpty {value = allowEmpty ? nil : -604801}
                    else {value = parseTime(new,allowNegative:allowNegative) ?? -604801}
                }
                .onChange(of:value) {_,new in
                    if !focused {text = new.map {String(format:"%.3f",$0)} ?? ""}
                }
            if value == -604801 {Text("時刻の形式を確認してください。").font(.system(size:10)).foregroundStyle(.red)}
        }
    }
}
struct MessageEditor: View {
    @Binding var message: OSCMessage
    let endpoints: [Endpoint]
    let onDelete: () -> Void
    let onTest: () -> Void
    let canTest: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Picker("送信先",selection:$message.endpointID) {ForEach(endpoints) {Text($0.name).tag($0.id)}}.labelsHidden()
                Spacer()
                Button(action:onDelete) {Image(systemName:"trash")}.buttonStyle(.plain).foregroundStyle(Palette.muted)
            }
            TextField("/cue/1/start",text:$message.address).font(.system(size:12,design:.monospaced))
            ForEach($message.arguments) {$arg in
                HStack(spacing:5) {
                    Picker("",selection:$arg.type) {Text("int").tag("i");Text("float").tag("f");Text("str").tag("s")}.labelsHidden().frame(width:76)
                    TextField("値",text:$arg.value).font(.system(size:11,design:.monospaced))
                    Button {message.arguments.removeAll {$0.id == arg.id}} label: {Image(systemName:"minus.circle")}.buttonStyle(.plain).foregroundStyle(Palette.muted)
                }
            }
            HStack {
                Button("＋ 引数") {message.arguments.append(OSCArgument())}
                Spacer()
                Button("テスト送信…",action:onTest).disabled(!canTest)
            }.font(.system(size:10))
        }.padding(12).background(Palette.raised,in:RoundedRectangle(cornerRadius:8))
    }
}
struct NetworkEditor: View {
    @ObservedObject var engine: ShowEngine
    @State private var endpoints: [Endpoint] = []
    @State private var title = ""
    var dirty: Bool {endpoints != engine.show.endpoints || title != engine.show.title}
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                eyebrow("OUTPUT CONTROL")
                VStack(alignment:.leading,spacing:12) {
                    HStack {
                        Circle().fill(engine.outputArmed ? Palette.amber : Palette.muted).frame(width:8,height:8)
                        Text(engine.outputArmed ? "本番出力 ON" : "リハーサル / 出力 OFF").font(.system(size:14,weight:.semibold))
                    }
                    Text(engine.outputArmed ? "GOと自動CUEで実際にOSC/UDPを送信します。" : "CUEと時計は動作します。OSCは送信せず、ログに記録します。").font(.system(size:11)).foregroundStyle(Palette.muted)
                    Button {
                        if engine.outputArmed {engine.arm(false)}
                        else if dirty {engine.alert = "先に送信先設定を保存してください。"}
                        else if confirm("OSC出力を有効にしますか？","次のGO・自動CUEから、設定した受信機に送信します。ネットワークと受信機を確認してください。",action:"出力をON") {engine.arm(true)}
                    } label: {Text(engine.outputArmed ? "OSC出力をOFF" : "OSC出力をON…").font(.system(size:12,weight:.semibold)).frame(maxWidth:.infinity).padding(.vertical,12)}
                        .buttonStyle(ActionButtonStyle(color:Palette.amber,filled:false)).disabled(engine.running)
                }.padding(15).background(Palette.surface,in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(Palette.line))
                Text("UDPの送信ログは、受信機の到達・実行を保証しません。会場では受信機側でも動作を確認してください。").font(.system(size:11)).foregroundStyle(Palette.muted)
                Divider()
                VStack(alignment:.leading,spacing:8) {
                    fieldLabel("作品名")
                    TextField("作品名",text:$title)
                }.disabled(engine.running)
                HStack {eyebrow("DESTINATIONS"); Spacer(); Text("IPv4 / UDP").font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.muted)}
                ForEach($endpoints) {$endpoint in
                    VStack(alignment:.leading,spacing:9) {
                        HStack {
                            TextField("送信先名",text:$endpoint.name)
                            Button {
                                if engine.show.cues.contains(where: {$0.messages.contains {$0.endpointID == endpoint.id}}) {engine.alert = "この送信先を使っているCUEがあります。先にCUE側の送信先を変更してください。"}
                                else {endpoints.removeAll {$0.id == endpoint.id}}
                            } label: {Image(systemName:"trash")}.buttonStyle(.plain).foregroundStyle(Palette.muted)
                        }
                        HStack {
                            TextField("192.168.220.101",text:$endpoint.host).frame(maxWidth:.infinity)
                            Text(":").foregroundStyle(Palette.muted)
                            TextField("13001",value:$endpoint.port,format:.number.grouping(.never)).frame(width:75)
                        }.font(.system(size:11,design:.monospaced))
                    }.padding(12).background(Palette.raised,in:RoundedRectangle(cornerRadius:8))
                }.disabled(engine.running)
                Button {endpoints.append(Endpoint(name:"New destination",host:"127.0.0.1"))} label: {Label("送信先を追加",systemImage:"plus")}.font(.system(size:11)).disabled(engine.running)
                Text("NetworkシートのAI / Mocap / Light / Soundを初期登録しています。実際のIPとOSCアドレスは本番構成に合わせて変更してください。").font(.system(size:11)).foregroundStyle(Palette.muted)
                Divider()
                eyebrow("このアプリで扱うOSC")
                Text("1つのメッセージを1つのUDPパケットで送ります。引数はint32 / float32 / ASCII文字列。複数メッセージは順に送ります。失敗時はHOLDし、自動再送しません。").font(.system(size:11)).foregroundStyle(Palette.muted)
            }.padding(18).textFieldStyle(.roundedBorder)
        }
        HStack {
            Button("破棄") {load()}.disabled(!dirty)
            Button {
                var candidate = engine.show; candidate.endpoints = endpoints; candidate.title = title
                do {
                    try candidate.validate(); engine.show = candidate; engine.arm(false); _ = engine.saveShow()
                } catch {engine.alert = error.localizedDescription}
            } label: {Text("設定を保存").frame(maxWidth:.infinity).padding(.vertical,12)}
                .buttonStyle(ActionButtonStyle(color:Palette.accent)).disabled(engine.running || !dirty)
        }.padding(16)
        .onAppear {load()}
        .onChange(of:dirty) {_,value in engine.networkEditPending = value}
        .onChange(of:engine.show) {_,_ in load()}
    }
    func load() {endpoints = engine.show.endpoints; title = engine.show.title}
}
struct LogView: View {
    @ObservedObject var engine: ShowEngine
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {eyebrow("EXECUTION LOG"); Spacer(); Button {FileActions.exportLog(engine)} label: {Image(systemName:"square.and.arrow.up")}.buttonStyle(.plain)}
                .padding(.horizontal,18)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:0) {
                    ForEach(engine.logs.reversed()) {entry in
                        VStack(alignment:.leading,spacing:7) {
                            HStack {
                                Text(timeText(entry.showTime)).font(.system(size:11,weight:.semibold,design:.monospaced))
                                Text(entry.level).font(.system(size:9,weight:.bold,design:.monospaced)).foregroundStyle(entry.level == "ERROR" ? .red : entry.level == "OSC" ? Palette.amber : Palette.accent)
                                Spacer()
                                Text(entry.date,style:.time).font(.system(size:9,design:.monospaced)).foregroundStyle(Palette.muted)
                            }
                            Text(entry.text).font(.system(size:11)).lineSpacing(3).textSelection(.enabled)
                        }.padding(.vertical,14)
                        Divider()
                    }
                    if engine.logs.isEmpty {Text("実行するとログが表示されます。").font(.system(size:12)).foregroundStyle(Palette.muted).padding(.top,30)}
                }.padding(.horizontal,18)
            }
        }.padding(.top,8)
    }
}
