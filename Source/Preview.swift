import Foundation

struct Department: Identifiable {
    let id: String
    let keys: [String]
    let callNames: [String]
    static let all: [Department] = [
        .init(id:"照明",keys:["照明","照明詳細"],callNames:["照明"]),
        .init(id:"音響",keys:["音響","音響詳細"],callNames:["音響","sound"]),
        .init(id:"mocap / 映像",keys:["mocap","mocap 下PJ","mocap 上PJ","mocap HMD"],callNames:["mocap"]),
        .init(id:"AI / 映像",keys:["AI","AI PJ","AI HMD","AI Camarm"],callNames:["ai"]),
        .init(id:"出演者",keys:["出演者全体","竹本","富士夫","萌","花形"],callNames:["出演者"]),
        .init(id:"技術",keys:["技術"],callNames:["テクニカル","技術"])
    ]
}
struct DepartmentPreview: Identifiable {
    var id: String {department.id}
    let department: Department
    let current: [String:String]
    let afterNext: [String:String]
    let changedKeys: Set<String>
    let upcomingCue: Cue?
    let upcomingActions: [String:String]
}
enum StatePreview {
    static func merge(_ state: [String:String], actions: [String:String]) -> [String:String] {
        var result = state
        for (key,value) in actions where !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {result[key] = value}
        return result
    }
    static func make(current: [String:String], upcoming: [Cue]) -> [DepartmentPreview] {
        let next = upcoming.first
        let afterNext = merge(current,actions:next?.actions ?? [:])
        return Department.all.map {dept in
            let changed = Set(dept.keys.filter {current[$0] != afterNext[$0]})
            var simulated = current, found: Cue?, instructions: [String:String] = [:]
            for cue in upcoming {
                let after = merge(simulated,actions:cue.actions)
                let stateChange = dept.keys.contains {simulated[$0] != after[$0]}
                let call = cue.operatorCue?.lowercased() ?? ""
                let hasCall = dept.callNames.contains {name in
                    call.split(separator:"\n").contains {line in line.trimmingCharacters(in:.whitespaces).hasPrefix(name.lowercased() + " ") || line.trimmingCharacters(in:.whitespaces).hasPrefix(name.lowercased() + ":") || line.trimmingCharacters(in:.whitespaces).hasPrefix(name.lowercased() + "：")}
                }
                if stateChange || hasCall {
                    found = cue
                    instructions = Dictionary(uniqueKeysWithValues:dept.keys.compactMap {key in
                        guard let value = cue.actions[key], !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return nil}
                        return (key,value)
                    })
                    break
                }
                simulated = after
            }
            return DepartmentPreview(department:dept,current:current,afterNext:afterNext,changedKeys:changed,upcomingCue:found,upcomingActions:instructions)
        }
    }
}
