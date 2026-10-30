import Foundation
import Combine

enum SessionActivity: String, CaseIterable {
    case approval = "Approval needed", input = "Input needed", failed = "Request failed"
    case retrying = "Retrying", compacting = "Compacting context", generating = "Working", ready = "Ready", unknown = "Unknown"
    init(_ thread: NativeThread) {
        if (thread.approvalCount ?? 0) > 0 || thread.activity.isWaitingForApproval { self = .approval }
        else if (thread.inputCount ?? 0) > 0 { self = .input }
        else if thread.retrying { self = .retrying }
        else if thread.activity.isCompacting { self = .compacting }
        else if thread.status == "Idle" && thread.failed { self = .failed }
        else if thread.activity.isWorking || thread.status == "Generating" { self = .generating }
        else if thread.status == "Idle" { self = .ready }
        else { self = .unknown }
    }
    var attention: Bool { [.approval, .input, .failed].contains(self) }
    var running: Bool { [.compacting, .generating, .retrying].contains(self) }
    var group: String { attention ? "Needs attention" : running ? "Running" : "Ready & other" }
}

@MainActor final class SessionLibrary: ObservableObject {
    @Published private(set) var pins: Set<String>
    @Published private(set) var updated: Set<String> = []
    @Published private(set) var recent: [String]
    private var signatures: [String: NativeThread] = [:]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pins = Set(defaults.stringArray(forKey: "zedlink.sessionPins") ?? [])
        recent = defaults.stringArray(forKey: "zedlink.sessionRecent") ?? []
    }
    static func key(profile: String, target: String, thread: String) -> String {
        // Persist conversation identity, never connection epoch or transcript data.
        String(data: try! JSONEncoder().encode([profile, target, thread]), encoding: .utf8)!
    }
    func toggle(_ key: String) {
        if pins.contains(key) { pins.remove(key) } else { pins.insert(key) }
        defaults.set(Array(pins).sorted(), forKey: "zedlink.sessionPins")
    }
    func observe(_ threads: [NativeThread], profile: String, target: String, selected: String?) {
        for thread in threads {
            let key = Self.key(profile: profile, target: target, thread: thread.id)
            if let previous = signatures[key], selected != thread.id,
               previous.status != thread.status || previous.currentTurnID != thread.currentTurnID || previous.activity != thread.activity || previous.retrying != thread.retrying || previous.failed != thread.failed ||
                (previous.approvalCount != nil && thread.approvalCount != nil && previous.approvalCount != thread.approvalCount) ||
                (previous.inputCount != nil && thread.inputCount != nil && previous.inputCount != thread.inputCount) { updated.insert(key) }
            signatures[key] = thread
            if selected == thread.id { updated.remove(key) }
        }
    }
    func seen(_ key: String) { updated.remove(key) }
    func opened(_ key: String) {
        recent = [key] + Array(recent.filter { $0 != key }.prefix(19))
        defaults.set(recent, forKey: "zedlink.sessionRecent")
        seen(key)
    }
}
