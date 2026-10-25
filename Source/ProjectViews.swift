import SwiftUI

struct ProjectManager: View {
    @ObservedObject var engine: ShowEngine
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sheetSettings = false
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("プロジェクト").font(.system(size:24,weight:.semibold))
                    Text("1つのCueDeckで、作品と進行を切り替える").font(.system(size:12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("閉じる") {dismiss()}.keyboardShortcut(.cancelAction)
            }
            if engine.running {Text("切り替え・作成はHOLD中に行います。").foregroundStyle(Palette.amber).font(.system(size:12))}
            ScrollView {
                LazyVStack(spacing:8) {
                    ForEach(engine.projects) {project in
                        Button {
                            engine.switchProject(project.id)
                            if engine.activeProjectID == project.id {dismiss()}
                        } label: {
                            HStack(spacing:12) {
                                Image(systemName:project.id == engine.activeProjectID ? "checkmark.circle.fill" : "folder").foregroundStyle(project.id == engine.activeProjectID ? Palette.accent : Palette.muted)
                                VStack(alignment:.leading,spacing:6) {
                                    Text(project.title).font(.system(size:14,weight:.semibold))
                                    Text(project.updatedAt.formatted(date:.abbreviated,time:.shortened)).font(.system(size:10)).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                Text(project.id == engine.activeProjectID ? "現在の作品" : "開く").font(.system(size:11)).foregroundStyle(Palette.muted)
                            }.padding(15).background(Palette.surface,in:RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain).disabled(engine.running)
                    }
                }
            }.frame(minHeight:150,maxHeight:280)
            Divider()
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Text("現在の作品のシートURL").font(.system(size:12,weight:.semibold))
                    Spacer()
                    Button("登録・変更…") {sheetSettings = true}.disabled(engine.running || engine.hasPendingEdits)
                }
                Text(engine.show.sourceURL.isEmpty ? "未登録" : engine.show.sourceURL).font(.system(size:10)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Divider()
            TextField("新しいプロジェクト名",text:$name).textFieldStyle(.roundedBorder)
            HStack {
                Button {
                    engine.createProject(name:name)
                } label: {Label("空のプロジェクトを作成",systemImage:"plus").padding(10)}
                    .buttonStyle(ActionButtonStyle(color:Palette.accent)).disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || engine.running || engine.hasPendingEdits)
                Button("現在の作品を複製") {
                    engine.createProject(name:name.isEmpty ? engine.show.title + "（コピー）" : name,from:engine.show)
                }.disabled(engine.running || engine.hasPendingEdits)
            }
            HStack {
                Button("作品JSONから追加…") {FileActions.importShow(engine,asNewProject:true)}
                Button("CSV / TSVから追加…") {FileActions.importSheet(engine,asNewProject:true)}
            }.disabled(engine.running || engine.hasPendingEdits)
            Text("作品ごとに時計・実行済みCUE・送信先を保存します。開いたときはHOLD・OSC出力OFFです。")
                .font(.system(size:11)).foregroundStyle(Palette.muted)
        }
        .padding(26).frame(width:610).background(Palette.background).preferredColorScheme(.dark)
        .sheet(isPresented:$sheetSettings) {SheetUpdateView(engine:engine,autoFetch:false)}
        .onChange(of:engine.activeProjectID) {_,_ in dismiss()}
    }
}
