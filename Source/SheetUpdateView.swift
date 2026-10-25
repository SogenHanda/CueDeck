import SwiftUI
import AppKit

struct SheetUpdateView: View {
    @ObservedObject var engine: ShowEngine
    let autoFetch: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var result: RemoteSheetResult?
    @State private var baseline: Show?
    @State private var projectID: UUID?
    @State private var preserveSettings = true
    @State private var plan: SheetUpdatePlan?
    @State private var error = ""
    @State private var message = ""
    @State private var loading = false
    @State private var task: Task<Void,Never>?
    @State private var requestID: UUID?
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("シートURL・更新").font(.system(size:23,weight:.semibold))
                    Text(engine.show.title).font(.system(size:12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("閉じる") {cancel(); dismiss()}.keyboardShortcut(.cancelAction)
            }
            VStack(alignment:.leading,spacing:9) {
                fieldLabel("GoogleスプレッドシートのURL（開いているタブのgidを含むURL）")
                TextField("https://docs.google.com/spreadsheets/d/…/edit#gid=…",text:$url)
                    .textFieldStyle(.roundedBorder).font(.system(size:12)).disabled(loading || result != nil)
                HStack {
                    Button("URLを保存") {
                        if engine.registerSourceURL(url) {url = engine.show.sourceURL; message = "このプロジェクトにURLを保存しました。"; error = ""}
                        else {error = engine.alert ?? "URLを保存できませんでした。"; engine.alert = nil}
                    }.disabled(loading || result != nil || engine.running || engine.hasPendingEdits)
                    if let location = try? SheetLocation(url) {
                        Text(location.tabDescription).font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("シートを開く") {NSWorkspace.shared.open(location.canonicalURL)}
                    } else {Spacer()}
                }
                HStack(spacing:16) {
                    if let date = engine.show.sourceCheckedAt {
                        Text("最終確認 " + date.formatted(date:.abbreviated,time:.shortened))
                    }
                    if let date = engine.show.sourceUpdatedAt {
                        Text("最終反映 " + date.formatted(date:.abbreviated,time:.shortened))
                    }
                }.font(.system(size:10)).foregroundStyle(Palette.muted)
            }
            if loading {
                HStack(spacing:12) {ProgressView().controlSize(.small); Text("Googleから最新版を取得しています…").font(.system(size:13)); Spacer(); Button("中止") {cancel()}}
                    .padding(16).background(Palette.surface,in:RoundedRectangle(cornerRadius:8))
            }
            if !error.isEmpty {
                Text(error).font(.system(size:12)).foregroundStyle(Palette.amber).textSelection(.enabled)
                    .padding(13).frame(maxWidth:.infinity,alignment:.leading).background(Palette.amber.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
            }
            if !message.isEmpty {Text(message).font(.system(size:12)).foregroundStyle(Palette.accent)}
            if let plan {review(plan)}
            else if !loading {
                Text("最新版を取得した後、変更内容を確認して反映します。取得失敗・中止では現在の作品を変更しません。")
                    .font(.system(size:12)).foregroundStyle(Palette.muted)
                Text("ログインなしでCSVを取得できるGoogleシートに対応します。閲覧権限や共有設定をアプリから変更することはありません。")
                    .font(.system(size:11)).foregroundStyle(Palette.muted)
            }
            HStack {
                if result != nil {
                    Button("再取得") {result = nil; plan = nil; engine.sheetUpdateBusy = false; fetch()}
                }
                Spacer()
                if let plan {
                    Button {
                        if engine.applySheetUpdate(plan) {dismiss()}
                        else {error = engine.alert ?? "反映できませんでした。"; engine.alert = nil}
                    } label: {Text(plan.changed ? "バックアップして更新" : "確認完了（進行を維持）").font(.system(size:12,weight:.semibold)).padding(.horizontal,18).padding(.vertical,12)}
                        .buttonStyle(ActionButtonStyle(color:Palette.accent)).disabled(engine.running)
                } else {
                    Button(action:fetch) {Label("最新版を取得",systemImage:"arrow.clockwise").font(.system(size:12,weight:.semibold)).padding(.horizontal,18).padding(.vertical,12)}
                        .buttonStyle(ActionButtonStyle(color:Palette.accent)).disabled(loading || url.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || engine.running || engine.hasPendingEdits)
                }
            }
        }
        .padding(25).frame(width:730).background(Palette.background).preferredColorScheme(.dark)
        .onAppear {url = engine.show.sourceURL; if autoFetch && !url.isEmpty {fetch()}}
        .onDisappear {cancel()}
        .onChange(of:preserveSettings) {_,_ in makePlan()}
    }
    func review(_ plan: SheetUpdatePlan) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(plan.changed ? "更新内容を確認" : "変更はありません").font(.system(size:17,weight:.semibold))
                Spacer()
                Text("\(plan.baseline.cues.count) → \(plan.candidate.cues.count) CUE").font(.system(size:12,design:.monospaced)).foregroundStyle(Palette.accent)
            }
            HStack(spacing:16) {
                ForEach(["追加","変更","削除"],id:\.self) {kind in
                    Text("\(kind) \(plan.changes.filter {$0.kind == kind}.count)").font(.system(size:11,weight:.semibold))
                }
                Spacer()
                Text("一致 \(plan.matched)件").font(.system(size:11)).foregroundStyle(Palette.muted)
            }
            Toggle("一致するCUEのOSC・自動実行設定を引き継ぐ",isOn:$preserveSettings).font(.system(size:12))
            Text("シートの本文・時刻・担当状態・メモを優先します。名前と進行CUEなどで一意に対応するCUEの設定だけを引き継ぎます。")
                .font(.system(size:10)).foregroundStyle(Palette.muted)
            if plan.changed {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:10) {
                        ForEach(plan.changes) {change in
                            HStack(alignment:.top,spacing:12) {
                                Text(change.kind).font(.system(size:10,weight:.bold)).foregroundStyle(change.kind == "削除" ? Palette.amber : Palette.accent)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(change.title.replacingOccurrences(of:"\n",with:" ")).font(.system(size:12,weight:.semibold))
                                    Text(change.detail).font(.system(size:10)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength:0)
                            }
                            Divider()
                        }
                    }
                }.frame(maxHeight:210)
            }
            if !plan.warnings.isEmpty {
                ScrollView {Text(plan.warnings.joined(separator:"\n")).font(.system(size:11)).foregroundStyle(Palette.amber).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)}.frame(maxHeight:75)
            }
            Text(plan.changed ? "反映時に旧作品と進行をバックアップします。時計と実行済み状態は初期化し、HOLD・OSC出力OFFで開きます。" : "確認日時だけを保存し、時計・実行済み状態・CUE設定を維持します。")
                .font(.system(size:11)).foregroundStyle(Palette.muted)
        }.padding(16).background(Palette.surface,in:RoundedRectangle(cornerRadius:9))
    }
    func fetch() {
        guard !loading, !engine.running, !engine.hasPendingEdits else {error = "HOLDにし、編集を保存してから取得してください。"; return}
        do {_ = try SheetLocation(url)} catch {self.error = error.localizedDescription; return}
        let base = engine.show, active = engine.activeProjectID, value = url, token = UUID()
        baseline = base; projectID = active; requestID = token
        error = ""; message = ""; result = nil; plan = nil; loading = true; engine.sheetUpdateBusy = true
        task = Task {
            do {
                let fetched = try await RemoteSheet.fetch(value,endpoints:base.endpoints)
                guard !Task.isCancelled, requestID == token else {return}
                guard engine.show == base, engine.activeProjectID == active else {throw CueError.message("取得中にプロジェクトが変わりました。もう一度取得してください。")}
                result = fetched; loading = false; makePlan()
            } catch {
                guard requestID == token else {return}
                loading = false; engine.sheetUpdateBusy = false
                if !Task.isCancelled {self.error = error.localizedDescription}
            }
        }
    }
    func makePlan() {
        guard let result, let baseline else {return}
        do {plan = try SheetUpdatePlan.make(baseline:baseline,projectID:projectID,result:result,preserveSettings:preserveSettings); error = ""}
        catch {self.error = error.localizedDescription; plan = nil}
    }
    func cancel() {
        requestID = nil; task?.cancel(); task = nil; loading = false; engine.sheetUpdateBusy = false
    }
}
