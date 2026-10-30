import Foundation

enum RouteKind: String, CaseIterable, Codable, Identifiable {
    case tailscale = "Tailscale"
    case wireGuard = "WireGuard"
    case otherVPN = "Other VPN"
    case local = "Local HTTPS"
    case custom = "Custom HTTPS"

    var id: String { rawValue }

    var guidance: String {
        switch self {
        case .tailscale: "Connect your existing Tailscale app, then enter the workstation's verified HTTPS hostname."
        case .wireGuard: "Connect your existing WireGuard tunnel and enter a hostname routed to the workstation."
        case .otherVPN: "Connect a VPN that routes to the workstation, then enter its HTTPS address."
        case .local: "Join the same trusted local network and use a certificate valid for the entered hostname."
        case .custom: "Enter the HTTPS address of a trusted reverse proxy that forwards ZedLink API requests."
        }
    }
}

struct ConnectionProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var route: RouteKind
    var endpoint: String
    var gatewayID: String
}

struct ZedTarget: Identifiable, Equatable {
    let id: String
    let label: String
    let available: Bool
}

struct AgentOption: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
}

struct NativeAgentActivity: Equatable {
    let phase: String
    let label: String
    let detail: String?

    static let ready = NativeAgentActivity(phase: "idle", label: "Ready", detail: nil)

    init(phase: String, label: String, detail: String?) {
        self.phase = phase
        self.label = label
        self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? detail : nil
    }

    init(_ value: Any?, status: String, currentTurnID: Int?) {
        let row = value as? [String: Any]
        let fallbackWorking = currentTurnID != nil || status == "Generating"
        phase = row?["phase"] as? String ?? (fallbackWorking ? "responding" : "idle")
        label = row?["label"] as? String ?? (fallbackWorking ? "Agent is responding" : "Ready")
        let rawDetail = row?["detail"] as? String
        detail = rawDetail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? rawDetail : nil
    }

    var isWorking: Bool { phase != "idle" }
    var isCompacting: Bool { phase == "compacting" }
    var isWaitingForApproval: Bool { phase == "waiting_for_approval" }
    var displayText: String { detail.map { "\(label) · \($0)" } ?? label }
}

struct NativeThread: Identifiable, Equatable {
    let id: String
    let title: String
    let status: String
    let currentTurnID: Int?
    var agentName = "Zed Agent"
    var retrying = false
    var failed = false
    var approvalCount: Int? = nil
    var inputCount: Int? = nil
    var activity = NativeAgentActivity.ready
}

struct NativeCommand: Identifiable, Equatable {
    let name: String
    let description: String
    let category: String
    let requiresArgument: Bool
    var inputHint: String? = nil
    var execution = "prompt"
    var confirmation: String? = nil
    var warning: String? = nil

    var id: String { name }
}

struct NativeApproval: Identifiable, Equatable {
    let id: String
    let turnID: Int?
    let toolName: String
    let display: String
    let rawInput: String?
    let detailsTruncated: Bool
    let canApproveOnce: Bool
    let canDenyOnce: Bool
    let subagentID: String?
    let authorizationKind: String
    let decisions: [NativeApprovalDecision]
    var viewIdentity: String { "\(subagentID ?? "root"):\(turnID ?? -1):\(id)" }
}

struct NativeApprovalDecision: Identifiable, Equatable {
    let optionID: String
    let label: String
    let optionKind: String
    let choiceIndex: Int?
    let selectedPatternIndices: [Int]
    let action: String?

    var id: String {
        "\(optionID):\(choiceIndex.map(String.init) ?? "flat"):\(selectedPatternIndices.map(String.init).joined(separator: ","))"
    }

    var isRejecting: Bool { optionKind.hasPrefix("reject") }
    var displayLabel: String {
        guard let action else { return label }
        return "\(action == "allow" ? "Allow" : "Deny") · \(label)"
    }
}

struct NativeElicitationField: Identifiable, Equatable {
    let id: String
    let title: String
    let type: String
    let required: Bool
    let choices: [String]
    var defaultValue: String? = nil
    var minimum: Double? = nil
    var maximum: Double? = nil
    var minLength: Int? = nil
    var maxLength: Int? = nil
}

struct NativeElicitation: Identifiable, Equatable {
    let id: String
    let message: String
    let url: String?
    let fields: [NativeElicitationField]
}

struct NativeEntryMeta: Equatable {
    let kind: String
    let callID: String?
    let elicitationID: String?

    static func page(_ raw: Any?, count: Int) -> [NativeEntryMeta?] {
        guard let rows = raw as? [[String: Any]], rows.count == count else {
            return Array(repeating: nil, count: count)
        }
        return rows.map { row in
            NativeEntryMeta(kind: row["kind"] as? String ?? "other",
                            callID: row["call_id"] as? String,
                            elicitationID: row["elicitation_id"] as? String)
        }
    }
}

struct NativeQueueEntry: Identifiable, Equatable {
    let id: Int
    let preview: String
    let steer: Bool
}

struct NativeEditReview: Equatable {
    let changedFiles: Int
    let linesAdded: Int
    let linesRemoved: Int
}

struct NativeModelOption: Identifiable, Equatable {
    let id: String
    let providerID: String
    let name: String
}

struct NativeAgentProfile: Identifiable, Equatable { let id: String; let name: String }

struct NativeThreadSettings: Equatable {
    let modelID: String?
    let providerID: String?
    let models: [NativeModelOption]
    let usedTokens: Int?
    let maxTokens: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let remainingTokens: Int?
    var profileID: String? = nil
    var profiles: [NativeAgentProfile] = []
    var thinkingEnabled: Bool? = nil
    var thinkingSupported = false
    var thinkingCanDisable = false
}

struct NativeRewindPoint: Identifiable, Equatable {
    let id: String
    let entryIndex: Int
    let entriesRemoved: Int
}

struct NativeSubagent: Identifiable, Equatable {
    let id: String
    let title: String
    let status: String
    let currentTurnID: Int?
    let entries: [String]
    var entryStartIndex = 0
    var totalEntries = 0
    var entriesTruncated = false
    var isActive: Bool { currentTurnID != nil || ["pending", "running", "inprogress", "in progress", "waiting", "generating"].contains(status.lowercased()) }
}
struct NativeProjectFile: Identifiable, Equatable { let id: String; let kind: String; let size: Int? }
struct NativeChange: Identifiable, Equatable { let id: String; let status: String; let staging: String }
struct NativeTerminal: Identifiable, Equatable {
    let id: String
    let title: String
    let workingDirectory: String?
    let taskLabel: String?
    let taskState: String?
}
struct NativeTerminalRun: Equatable {
    let text: String
    let foreground: String
    let background: String
    let bold: Bool
    let italic: Bool
    let underline: Bool
    let dim: Bool
}
struct NativeTerminalSnapshot: Equatable {
    let terminal: NativeTerminal
    let content: String
    let truncated: Bool
    var styledRuns: [NativeTerminalRun] = []
}
struct NativeConfiguredTask: Identifiable, Equatable {
    let id: String
    let label: String
    let source: String
}
struct NativeDebugScenario: Identifiable, Equatable {
    let id: String
    let label: String
    let adapter: String
    let source: String
}
struct NativeDebuggerThread: Identifiable, Equatable {
    let id: Int
    let name: String
    let status: String
}
struct NativeDebuggerSession: Identifiable, Equatable {
    let id: String
    let label: String
    let adapter: String
    let terminated: Bool
    let canRestart: Bool
    let canStepBack: Bool
    let threads: [NativeDebuggerThread]
}

/// Authoritative native failure, separate from gateway connectivity and send delivery.
struct NativeAgentError: Equatable {
    let kind: String
    let title: String
    let message: String
    let retrying: Bool

    init?(snapshot: [String: Any]) {
        if let error = snapshot["agent_error"] as? [String: Any],
           let title = error["title"] as? String, let message = error["message"] as? String {
            kind = error["kind"] as? String ?? "agent_error"
            self.title = title; self.message = message
            retrying = error["retrying"] as? Bool ?? false
        } else if snapshot["had_error"] as? Bool == true {
            kind = "agent_error"; title = "Agent request failed"
            message = "The last native Zed Agent turn failed. Open desktop Zed for additional details."
            retrying = false
        } else { return nil }
    }
}

struct ThreadSnapshot: Equatable {
    let threadID: String
    let title: String
    let status: String
    let currentTurnID: Int?
    let instanceID: String
    let epoch: String
    let lastSequence: Int
    let entries: [String]
    let entryStartIndex: Int
    let totalEntries: Int
    let hasOlderEntries: Bool
    let activityEntries: [String]
    let truncated: Bool
    let activityTruncated: Bool
    let pendingApprovals: [NativeApproval]
    let rewindPoints: [NativeRewindPoint]
    let subagents: [NativeSubagent]
    var agentError: NativeAgentError? = nil
    var entryMeta: [NativeEntryMeta?] = []

    var isBusy: Bool { status == "Generating" || currentTurnID != nil }
}

struct PendingSend: Codable {
    var localConfirmed: Bool? = nil
    let id: String
    let instanceID: String
    let epoch: String
    let threadID: String
    // A draft remains in memory only. A relaunched app reconciles by ID without resending.
    var text: String?
    var contextPaths: [String] = []
    var attachments: [PromptAttachment] = []

    var submissionParams: [String: Any] {
        var params: [String: Any] = ["instance_id": instanceID, "epoch": epoch, "thread_id": threadID, "text": text ?? ""]
        if localConfirmed == true { params["local_confirmed"] = true }
        if !contextPaths.isEmpty { params["context_paths"] = contextPaths }
        if !attachments.isEmpty { params["uploads"] = attachments.map(\.payload) }
        return params
    }

    enum CodingKeys: String, CodingKey { case id, instanceID, epoch, threadID }
}

enum LinkState: Equatable {
    case offline
    case connecting
    case live
    case reconnecting
    case stale

    var label: String {
        switch self {
        case .offline: "Offline"
        case .connecting: "Connecting"
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .stale: "Stale"
        }
    }

    var symbol: String {
        switch self {
        case .offline: "wifi.slash"
        case .connecting: "arrow.triangle.2.circlepath"
        case .live: "circle.fill"
        case .reconnecting: "arrow.clockwise"
        case .stale: "exclamationmark.triangle"
        }
    }
}

struct PromptAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let mimeType: String
    let data: Data
    var payload: [String: Any] { ["name": name, "mime_type": mimeType, "data": data.base64EncodedString()] }
}

struct ProjectSearchMatch: Identifiable {
    let path: String
    let line: Int
    let column: Int
    let preview: String
    var id: String { "\(path):\(line):\(column)" }
}

enum WorkspacePage: String { case files, changes, terminal, debug, activity }
