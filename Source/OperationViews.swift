import SwiftUI

struct OperationDashboard: View {
    @ObservedObject var engine: ShowEngine
    @Binding var filter: String
    var body: some View {
        VStack(spacing:14) {
            clocks
            HStack(alignment:.top,spacing:14) {
                eventCard(cue:engine.current,isNext:false)
                eventCard(cue:engine.next,isNext:true)
            }
            HStack {
                eyebrow("担当別  現在 → 次のGO後")
                Spacer()
                Picker("",selection:$filter) {
                    Text("全担当").tag("全担当"); Text("技術").tag("技術"); Text("出演者").tag("出演者")
                }.labelsHidden().pickerStyle(.segmented).frame(width:205)
            }
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:340),alignment:.top)],alignment:.leading,spacing:12) {
                    ForEach(engine.departmentPreviews.filter {filter == "全担当" || (filter == "出演者" ? $0.id == "出演者" : $0.id != "出演者")}) {preview in
                        DepartmentCard(preview:preview,nextID:engine.next?.id)
                    }
                }.padding(.bottom,8)
            }
            Text("空欄は現在の状態を継続。次のGO後はプレビューです。各担当の次の変更はCUE順で表示します。")
                .font(.system(size:10)).foregroundStyle(Palette.muted).frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.horizontal,22).padding(.top,18).padding(.bottom,10)
    }
    var clocks: some View {
        HStack(alignment:.center,spacing:22) {
            VStack(alignment:.leading,spacing:5) {
                HStack(spacing:6) {
                    Circle().fill(engine.running ? Palette.accent : Palette.amber).frame(width:6,height:6)
                    eyebrow(engine.running ? "RUNNING" : "HOLD",color:engine.running ? Palette.accent : Palette.amber)
                    Text(engine.elapsed < 0 ? "開演前 / 上演時計" : "上演時計").font(.system(size:10)).foregroundStyle(Palette.muted)
                }
                Text(timeText(engine.elapsed)).font(.system(size:38,weight:.medium,design:.monospaced)).tracking(-1)
            }
            Rectangle().fill(Palette.line).frame(width:1,height:48)
            VStack(alignment:.leading,spacing:8) {
                eyebrow("現在CUEから")
                Text(timeText(engine.cueElapsed)).font(.system(size:25,weight:.medium,design:.monospaced)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength:0)
            VStack(alignment:.trailing,spacing:7) {
                Text(Date(),style:.time).font(.system(size:12,design:.monospaced))
                Text("\(engine.firedCount) / \(engine.show.cues.count) 実行済").font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.muted)
            }
        }.frame(height:67)
    }
    func eventCard(cue: Cue?, isNext: Bool) -> some View {
        let color = isNext ? Palette.amber : Palette.accent
        return VStack(alignment:.leading,spacing:9) {
            HStack {
                eyebrow(isNext ? "次のCUE / NEXT GO" : "現在のイベント / NOW",color:color)
                Spacer(minLength:0)
                Text(cue.map {"CUE " + $0.number} ?? "—").font(.system(size:11,weight:.bold,design:.monospaced)).foregroundStyle(color)
            }
            if let call = cue?.operatorCue, !call.isEmpty {
                Text(call.replacingOccurrences(of:"\n",with:"  /  ")).font(.system(size:12,weight:.bold)).foregroundStyle(color).lineLimit(2)
            }
            Text(cue?.title ?? (isNext ? (engine.show.cues.isEmpty ? "CUEを追加してください" : "すべてのCUEが完了") : "スタンバイ / まだ実行していません"))
                .font(.system(size:19,weight:.semibold)).lineLimit(3).lineSpacing(3)
                .frame(maxWidth:.infinity,minHeight:46,alignment:.topLeading).help(cue?.title ?? "")
            Text(timing(cue:cue,isNext:isNext)).font(.system(size:11,design:.monospaced)).foregroundStyle(Palette.muted).lineLimit(2)
            if isNext, let auto = engine.show.cues.filter({!engine.doneIDs.contains($0.id) && !engine.replayIDs.contains($0.id) && engine.dueTime($0) != nil}).min(by:{engine.dueTime($0)! < engine.dueTime($1)!}), auto.id != cue?.id {
                Text("並行AUTO \(auto.number)  \(timeText((engine.dueTime(auto) ?? 0)-engine.elapsed))後")
                    .font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(Palette.amber)
            }
        }
        .padding(16).frame(maxWidth:.infinity,minHeight:165,alignment:.topLeading)
        .background(color.opacity(isNext ? 0.04 : 0.025),in:RoundedRectangle(cornerRadius:10))
        .overlay(RoundedRectangle(cornerRadius:10).stroke(color.opacity(0.22)))
    }
    func timing(cue: Cue?, isNext: Bool) -> String {
        guard let cue else {return isNext ? (engine.show.cues.isEmpty ? "左下の追加、またはプロジェクト画面から取り込み" : "上演を終えたらHOLDしてください") : "START → GO で進行を開始"}
        if !isNext {return "実行 " + timeText(engine.records.last?.showTime ?? 0) + "  /  " + (engine.records.last?.origin ?? "")}
        if engine.replayID == cue.id {return "戻したCUE / 次のGOで再実行"}
        if let due = engine.dueTime(cue) {return "AUTO  " + (due < engine.elapsed ? "超過 " : "あと ") + timeText(abs(due-engine.elapsed))}
        if cue.trigger == .afterCue {return "基準CUE待ち / +" + timeText(cue.delay)}
        guard let p = cue.planned else {return "手動GO待ち / 時刻未定"}
        return "予定 " + timeText(p) + "  /  " + (p < engine.elapsed ? "超過 " : "あと ") + timeText(abs(p-engine.elapsed))
    }
}
struct DepartmentCard: View {
    let preview: DepartmentPreview
    let nextID: UUID?
    @State private var expanded = false
    var color: Color {
        switch preview.id {
        case "照明": Palette.amber
        case "音響": Color(red:0.55,green:0.78,blue:1)
        case "mocap / 映像": Color(red:0.75,green:0.65,blue:1)
        case "AI / 映像": Palette.accent
        case "出演者": Color(red:0.92,green:0.65,blue:0.72)
        default: Palette.muted
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Circle().fill(color).frame(width:6,height:6)
                Text(preview.id).font(.system(size:14,weight:.semibold))
                Spacer()
                Text(preview.changedKeys.isEmpty ? "次GOで継続" : "次GOで変更")
                    .font(.system(size:10,weight:.bold)).foregroundStyle(preview.changedKeys.isEmpty ? Palette.muted : Palette.amber)
                Button {expanded.toggle()} label: {Image(systemName:expanded ? "chevron.up" : "chevron.down")}.buttonStyle(.plain).foregroundStyle(Palette.muted).help("全文を表示")
            }
            HStack(alignment:.top,spacing:12) {
                stateColumn(title:"現在",state:preview.current,isNext:false).frame(maxWidth:.infinity,alignment:.topLeading)
                Rectangle().fill(Palette.line).frame(width:1)
                stateColumn(title:"次のGO後",state:preview.afterNext,isNext:true).frame(maxWidth:.infinity,alignment:.topLeading)
            }.fixedSize(horizontal:false,vertical:true)
            Divider()
            if let cue = preview.upcomingCue {
                HStack(alignment:.top,spacing:8) {
                    Text(cue.id == nextID ? "次GO" : "この担当の次").font(.system(size:9,weight:.bold)).foregroundStyle(color).padding(.vertical,3).padding(.horizontal,5).background(color.opacity(0.1),in:RoundedRectangle(cornerRadius:3))
                    VStack(alignment:.leading,spacing:5) {
                        HStack {
                            Text("CUE \(cue.number)").fontWeight(.bold)
                            Text(cue.planned.map {timeText($0)} ?? "時刻未定").foregroundStyle(Palette.muted)
                            Spacer(minLength:0)
                        }.font(.system(size:10,design:.monospaced))
                        Text(cue.title.replacingOccurrences(of:"\n",with:" ")).font(.system(size:11)).lineLimit(expanded ? nil : 2)
                        let instruction = preview.department.keys.compactMap {key in preview.upcomingActions[key].map {key + ": " + $0}}.joined(separator:"\n")
                        Text(instruction.isEmpty ? (cue.operatorCue ?? "担当指示を確認") : instruction).font(.system(size:11)).foregroundStyle(color).lineLimit(expanded ? nil : 3).textSelection(.enabled)
                    }
                }
            } else {Text("この先の担当変更は登録されていません").font(.system(size:11)).foregroundStyle(Palette.muted)}
        }.padding(15).frame(maxWidth:.infinity,alignment:.topLeading).background(Palette.surface,in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(Palette.line))
    }
    func stateColumn(title: String,state: [String:String],isNext: Bool) -> some View {
        VStack(alignment:.leading,spacing:9) {
            eyebrow(title,color:isNext ? Palette.amber : Palette.muted)
            let keys = preview.department.keys.filter {state[$0] != nil}
            if keys.isEmpty {Text("状態未確定").font(.system(size:12)).foregroundStyle(Palette.muted)}
            ForEach(keys,id:\.self) {key in
                VStack(alignment:.leading,spacing:4) {
                    if preview.department.keys.count > 1 {Text(key).font(.system(size:9)).foregroundStyle(Palette.muted)}
                    Text(state[key] ?? "").font(.system(size:12,weight:isNext && preview.changedKeys.contains(key) ? .semibold : .regular))
                        .foregroundStyle(isNext && preview.changedKeys.contains(key) ? Palette.amber : .white.opacity(0.9))
                        .lineLimit(expanded ? nil : 3).textSelection(.enabled).help(state[key] ?? "")
                }
            }
        }
    }
}
