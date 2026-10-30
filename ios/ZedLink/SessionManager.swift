import Foundation
import Combine
import Network

@MainActor final class SessionManager: ObservableObject {
    @Published private(set) var profile: ConnectionProfile?
    @Published private(set) var targets: [ZedTarget] = []
    @Published private(set) var targetID: String?
    @Published private(set) var state: LinkState = .offline
    @Published private(set) var threads: [NativeThread] = []
    @Published private(set) var snapshot: ThreadSnapshot?
    @Published private(set) var lastSnapshotAt: Date?
    @Published private(set) var cachedConversations: [CachedConversation] = []
    @Published private(set) var instanceID: String?
    @Published private(set) var epoch: String?
    @Published private(set) var capabilities: Set<String> = []
    @Published private(set) var commands: [NativeCommand] = []
    @Published private(set) var createAgents: [AgentOption] = []
    @Published private(set) var elicitations: [NativeElicitation] = []
    @Published private(set) var queuedMessages: [NativeQueueEntry] = []
    @Published private(set) var editReview: NativeEditReview?
    @Published private(set) var threadSettings: NativeThreadSettings?
    @Published private(set) var projectFiles: [NativeProjectFile] = []
    @Published private(set) var changes: [NativeChange] = []
    @Published private(set) var changesRevision: String?
    @Published private(set) var terminals: [NativeTerminal] = []
    @Published private(set) var terminalSnapshot: NativeTerminalSnapshot?
    @Published private(set) var creatingTerminal = false
    @Published private(set) var configuredTasks: [NativeConfiguredTask] = []
    @Published private(set) var debuggerCatalog: [NativeDebugScenario] = []
    @Published private(set) var debuggerSessions: [NativeDebuggerSession] = []
    @Published private(set) var projectFolderEntries: [NativeProjectFile]?
    @Published private(set) var projectFolderTruncated = false
    private var directoryRequest = UUID()
    @Published private(set) var projectFilesTruncated = false
    @Published private(set) var previewReadable = false
    @Published private(set) var previewLoading = false
    @Published private(set) var previewTruncated = false
    private var previewRequest = UUID()
    @Published private(set) var previewTitle = ""
    @Published private(set) var previewContent = ""
    @Published var contextPaths: Set<String> = []
    @Published var attachments: [PromptAttachment] = []
    @Published private(set) var supportsImages: Bool?
    @Published private(set) var liveActivity = NativeAgentActivity.ready
    @Published private(set) var diffContent = ""
    @Published private(set) var diffLoading = false
    @Published private(set) var diffTruncated = false
    @Published private(set) var workspaceLoading = false
    @Published private(set) var resolvingApprovals: Set<String> = []
    @Published private(set) var resolvingElicitations: Set<String> = []
    @Published var showConnections = false
    @Published private(set) var demoPreview = false
    private var summaryCache: [String: (Date, NativeThread)] = [:]
    func isRespondingToElicitation(_ id: String) -> Bool { resolvingElicitations.contains((operationScope + [id]).joined(separator: "\n")) }
    private var diffRequest = UUID()
    private var workspaceRequest = UUID()
    private var searchRequest = UUID()
    var operationScope: [String] { [generation.uuidString, profile?.id.uuidString ?? "", targetID ?? "", instanceID ?? "", epoch ?? "", selectedThreadID ?? ""] }
    func clearIssue() { issue = ""; notificationNeedsWorkspace = false }
    func reportIssue(_ message: String) { issue = message }
    func addImage(_ data: Data) {
        guard capabilities.contains("thread.attachments"), supportsImages != false else { issue = "This thread or model does not support image attachments."; return }
        guard attachments.count + contextPaths.count < 8, data.count <= 1024 * 1024 else { issue = "Use at most eight attachments, each image up to 1 MiB."; return }
        attachments.append(PromptAttachment(name: "image-\(attachments.count + 1).jpg", mimeType: "image/jpeg", data: data))
    }
    @Published private(set) var creatingThread = false
    @Published private(set) var selectedThreadID: String?
    @Published var notificationThreadID: String?
    @Published private(set) var delivery = ""
    @Published private(set) var issue = ""
    @Published private(set) var controlsIssue = ""
    @Published private(set) var notificationNeedsWorkspace = false
    @Published private(set) var pending: PendingSend?
    @Published var draft = "" {
        didSet {
            guard let profile, let selectedThreadID else { return }
            let key = draftKey(profileID: profile.id, targetID: targetID, threadID: selectedThreadID)
            if draft.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(draft, forKey: key) }
        }
    }

    private var client: GatewayClient?
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var eventStreamLive = false
    private var lastFastSnapshot = Date.distantPast
    private var lastAuxiliaryRefresh = Date.distantPast
    private var generation = UUID()
    private var resumeTrace: ResumeTrace?
    private var pathMonitor: NWPathMonitor?
    private var pathRetryTask: Task<Void, Never>?
    private var pathMonitorGeneration = UUID()
    private var foregroundActive = true
    private var sawInitialPath = false
    private var refreshingLive = false
    private let threadExposureIssue = "The selected thread is no longer exposed in desktop Zed."

    private func isCancelledRequest(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    var canSend: Bool { state == .live && capabilities.contains("thread.send") && selectedThreadID != nil && snapshot?.threadID == selectedThreadID && pending == nil }
    func savedTargetID(for profile: ConnectionProfile) -> String? {
        UserDefaults.standard.string(forKey: targetKey(profile))
    }
    var visibleThreads: [NativeThread] {
        guard profile != nil else { return [] }
        let exposed = Set(threads.map(\.id))
        return threads + cachedConversations.filter { !exposed.contains($0.threadID) }
            .map { NativeThread(id: $0.threadID, title: $0.title, status: "Saved copy", currentTurnID: nil) }
    }
    func cachedConversation(_ id: String) -> CachedConversation? {
        cachedConversations.first { $0.threadID == id }
    }
    func markConversationVisible() { resumeTrace?.mark("Conversation visible") }
    var canCancel: Bool {
        state == .live && capabilities.contains("thread.cancel") && snapshot?.threadID == selectedThreadID
            && snapshot?.currentTurnID != nil
    }

    func disconnect() {
        pathRetryTask?.cancel(); pathRetryTask = nil
        refreshingLive = false
        summaryCache = [:]
        attachments = []; diffContent = ""; diffLoading = false; workspaceLoading = false; supportsImages = nil
        diffRequest = UUID(); workspaceRequest = UUID(); searchRequest = UUID()
        requestedTerminalID = nil
        generation = UUID()
        resumeTrace?.finish(); resumeTrace = nil
        pollTask?.cancel()
        eventTask?.cancel()
        cacheTask?.cancel()
        pollTask = nil
        eventTask = nil
        cacheTask = nil
        eventStreamLive = false
        lastFastSnapshot = .distantPast
        lastAuxiliaryRefresh = .distantPast
        lastCommandsRefresh = .distantPast
        liveActivity = .ready
        client = nil
        profile = nil
        targets = []
        targetID = nil
        state = .offline
        threads = []
        snapshot = nil
        lastSnapshotAt = nil
        cachedConversations = []
        selectedThreadID = nil
        instanceID = nil
        epoch = nil
        capabilities = []
        commands = []
        createAgents = []
        elicitations = []
        queuedMessages = []
        editReview = nil
        threadSettings = nil
        ApprovalNotifications.shared.clear()
        previewRequest = UUID(); previewReadable = false; previewLoading = false; previewTruncated = false; projectFilesTruncated = false
        projectFolderEntries = nil; directoryRequest = UUID()
        projectFiles = []; changes = []; changesRevision = nil; terminals = []; terminalSnapshot = nil; configuredTasks = []; debuggerCatalog = []; debuggerSessions = []; previewTitle = ""; previewContent = ""; contextPaths = []
        creatingThread = false
        pending = nil
        delivery = ""
        issue = ""
        controlsIssue = ""
        notificationNeedsWorkspace = false
    }

    func connect(_ nextProfile: ConnectionProfile, target requestedTargetID: String? = nil,
                 routeRetryAttempt: Int = 0) async {
        let sameProfile = profile?.gatewayID.caseInsensitiveCompare(nextProfile.gatewayID) == .orderedSame
        let sameTarget = requestedTargetID == nil || requestedTargetID == targetID
        let previousThread = sameProfile && sameTarget ? selectedThreadID : nil
        let previousSnapshot = sameProfile && (requestedTargetID == nil || requestedTargetID == targetID) ? snapshot : nil
        let previousSnapshotAt = previousSnapshot == nil ? nil : lastSnapshotAt
        let previousThreads = sameProfile && (requestedTargetID == nil || requestedTargetID == targetID) ? threads : []
        let previousTargets = sameProfile ? targets : []
        let previousActivity = liveActivity
        let previousInstance = instanceID
        let previousEpoch = epoch
        let previousPending = sameProfile ? pending : nil
        let previousTarget = sameProfile ? targetID : nil
        let previousScope = operationScope
        let previousAttachments = attachments
        let previousContextPaths = contextPaths
        disconnect()
        if !sameProfile { draft = "" }
        let current = generation
        profile = nextProfile
        state = .connecting
        resumeTrace = ResumeTrace()
        let savedTarget = UserDefaults.standard.string(forKey: targetKey(nextProfile))
        let initialTarget = requestedTargetID ?? previousTarget ?? savedTarget
        if let initialTarget {
            targetID = initialTarget
            if initialTarget == previousTarget {
                selectedThreadID = previousThread
                snapshot = previousSnapshot
                lastSnapshotAt = previousSnapshotAt
                threads = previousThreads
                targets = previousTargets
                liveActivity = previousActivity
            }
            cachedConversations = await ConversationCache.shared.list(gatewayID: nextProfile.gatewayID, targetID: initialTarget)
            guard current == generation else { return }
            resumeTrace?.mark("Saved conversation ready")
        }
        do {
            guard let token = await CredentialVault.shared.read(nextProfile) else {
                throw GatewayFailure.native("Pair this device first.")
            }
            guard current == generation else { return }
            let discoveryClient = GatewayClient(profile: nextProfile, token: token)
            if let initialTarget {
                let rememberedThread = previousThread ?? UserDefaults.standard.string(forKey: selectedThreadKey(nextProfile, targetID: initialTarget))
                var params: [String: Any] = [:]
                if let rememberedThread { params["thread_id"] = rememberedThread }
                if sameTarget, let previousInstance, let previousEpoch {
                    params["instance_id"] = previousInstance
                    params["epoch"] = previousEpoch
                }
                let persistedPending = UserDefaults.standard.data(forKey: pendingKey(nextProfile))
                    .flatMap { try? JSONDecoder().decode(PendingSend.self, from: $0) }
                if let pendingID = (previousPending ?? persistedPending)?.id { params["pending_request_id"] = pendingID }
                do {
                    let resumed = try await GatewayClient(profile: nextProfile, token: token, targetID: initialTarget)
                        .rpc("session.resume", params: params)
                    guard current == generation else { return }
                    try await applyResume(resumed, profile: nextProfile, token: token, targetID: initialTarget,
                                          rememberedThread: rememberedThread, previousPending: previousPending,
                                          previousTarget: previousTarget, previousScope: previousScope,
                                          previousAttachments: previousAttachments, previousContextPaths: previousContextPaths,
                                          current: current)
                    return
                } catch GatewayFailure.native("UNSUPPORTED_CAPABILITY"), GatewayFailure.native("UNKNOWN_TARGET") {
                    // Older gateways use the established discovery and snapshot flow.
                }
            }
            try await discoveryClient.verifyIdentity()
            guard current == generation else { return }
            resumeTrace?.mark("Gateway identity verified")
            let registry = try await discoveryClient.rpc("instance.list")
            guard current == generation else { return }
            guard let rows = registry["targets"] as? [[String: Any]], !rows.isEmpty else {
                throw GatewayFailure.native("This gateway has no configured Zed targets.")
            }
            targets = rows.compactMap { row in
                guard let id = row["target_id"] as? String, let label = row["label"] as? String else { return nil }
                return ZedTarget(id: id, label: label, available: row["available"] as? Bool ?? false)
            }
            let preferredTarget = requestedTargetID ?? previousTarget ?? savedTarget
                ?? registry["default_target_id"] as? String
            let selectedTarget: ZedTarget
            if let preferredTarget {
                guard let configured = targets.first(where: { $0.id == preferredTarget }) else {
                    throw GatewayFailure.native("The saved workspace is no longer configured. Choose a workspace in Connections.")
                }
                selectedTarget = configured
            } else {
                guard let configured = targets.first(where: { $0.available }) ?? targets.first else {
                    throw GatewayFailure.native("This gateway has no configured Zed targets.")
                }
                selectedTarget = configured
            }
            targetID = selectedTarget.id
            if selectedTarget.id != initialTarget {
                selectedThreadID = nil
                snapshot = nil
                lastSnapshotAt = nil
                threads = []
                cachedConversations = await ConversationCache.shared.list(gatewayID: nextProfile.gatewayID, targetID: selectedTarget.id)
                guard current == generation else { return }
            }
            UserDefaults.standard.set(selectedTarget.id, forKey: targetKey(nextProfile))
            let nextClient = GatewayClient(profile: nextProfile, token: token, targetID: selectedTarget.id)
            let info = try await nextClient.rpc("instance.info")
            guard current == generation,
                  let instance = info["instance_id"] as? String,
                  let nextEpoch = info["epoch"] as? String else { return }
            client = nextClient
            instanceID = instance
            epoch = nextEpoch
            resumeTrace?.mark("Native instance verified")
            if previousInstance != instance || previousEpoch != nextEpoch { snapshot = nil; lastSnapshotAt = nil }
            capabilities = Set(info["capabilities"] as? [String] ?? [])
            restorePending(for: nextProfile)
            if let previousPending, selectedTarget.id == previousTarget,
               let restored = pending, restored.id == previousPending.id,
               restored.instanceID == previousPending.instanceID,
               restored.epoch == previousPending.epoch,
               restored.threadID == previousPending.threadID {
                // Keep the exact in-memory retry payload, including uploads and context.
                // Persisted identity alone intentionally cannot reconstruct that payload.
                pending = previousPending
            }
            if let previousPending, selectedTarget.id == previousTarget {
                pending = previousPending
                persistPending(for: nextProfile)
                delivery = "Delivery unknown. Reconcile before retrying; the request was not resent."
            }
            let rememberedThread = previousThread ?? UserDefaults.standard.string(forKey: selectedThreadKey(nextProfile, targetID: selectedTarget.id))
            selectedThreadID = rememberedThread
            try await loadThreads(includeSummaries: false)
            guard current == generation else { return }
            resumeTrace?.mark("Thread list ready")
            if let rememberedThread, threads.contains(where: { $0.id == rememberedThread }) {
                selectedThreadID = rememberedThread
                if Array(operationScope.dropFirst(2)) == Array(previousScope.dropFirst(2)) {
                    attachments = previousAttachments
                    contextPaths = previousContextPaths
                }
                try await loadSnapshot(rememberedThread, refreshAuxiliary: false)
                resumeTrace?.mark("Native snapshot ready")
            }
            guard current == generation else { return }
            state = .live
            pathRetryTask?.cancel(); pathRetryTask = nil
            resumeTrace?.mark("Live ready")
            resumeTrace?.finish(); resumeTrace = nil
            lastAuxiliaryRefresh = Date()
            issue = ""
            pollTask = Task { [weak self] in
                guard let self else { return }
                await self.pollLoop(current)
            }
            startEventStream(current)
            if let rememberedThread { Task { [weak self] in await self?.refreshAuxiliaryAfterResume(rememberedThread, current: current) } }
            Task { [weak self] in await self?.syncAPNs() }
        } catch {
            guard current == generation else { return }
            if isCancelledRequest(error) {
                state = .reconnecting
                issue = ""
                pathRetryTask?.cancel()
                pathRetryTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, !Task.isCancelled, current == self.generation else { return }
                    self.pathRetryTask = nil
                    await self.refresh()
                }
                return
            }
            let transientRouteFailure = (error as? GatewayFailure)?.isTransientRouteFailure == true
            state = transientRouteFailure && foregroundActive ? .reconnecting : .offline
            issue = error.localizedDescription
            resumeTrace?.finish(); resumeTrace = nil
            if transientRouteFailure && foregroundActive {
                let delaySeconds = min(60, 5 << min(routeRetryAttempt, 4))
                pathRetryTask?.cancel()
                pathRetryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Int64(delaySeconds)))
                    guard let self, !Task.isCancelled, self.foregroundActive,
                          current == self.generation else { return }
                    self.pathRetryTask = nil
                    await self.connect(nextProfile, target: requestedTargetID,
                                       routeRetryAttempt: min(routeRetryAttempt + 1, 4))
                }
            }
        }
    }

    private func applyResume(_ result: [String: Any], profile: ConnectionProfile, token: String, targetID resumedTarget: String,
                             rememberedThread: String?, previousPending: PendingSend?, previousTarget: String?,
                             previousScope: [String], previousAttachments: [PromptAttachment],
                             previousContextPaths: Set<String>, current: UUID) async throws {
        guard let instance = result["instance_id"] as? String,
              let nextEpoch = result["epoch"] as? String,
              let target = result["target"] as? [String: Any],
              target["target_id"] as? String == resumedTarget,
              let label = target["label"] as? String,
              let rows = result["threads"] as? [[String: Any]] else { throw GatewayFailure.invalidResponse }
        targetID = resumedTarget
        targets = [ZedTarget(id: resumedTarget, label: label, available: true)]
        UserDefaults.standard.set(resumedTarget, forKey: targetKey(profile))
        client = GatewayClient(profile: profile, token: token, targetID: resumedTarget)
        guard current == generation else { return }
        if snapshot?.instanceID != instance || snapshot?.epoch != nextEpoch { snapshot = nil; lastSnapshotAt = nil }
        instanceID = instance
        epoch = nextEpoch
        capabilities = Set(result["capabilities"] as? [String] ?? [])
        resumeTrace?.mark("Gateway and native instance verified")
        restorePending(for: profile)
        if let previousPending, resumedTarget == previousTarget {
            pending = previousPending
            persistPending(for: profile)
            delivery = "Delivery unknown. Reconcile before retrying; the request was not resent."
        }
        if let pending, pending.instanceID == instance, pending.epoch == nextEpoch,
           let status = result["pending_status"] as? [String: Any], status["known"] as? Bool == true {
            delivery = "Zed knows this request (\(status["outcome"] as? String ?? "unknown")); native acceptance remains provisional."
        }
        selectedThreadID = rememberedThread
        try await loadThreads(prefetched: ["instance_id": instance, "epoch": nextEpoch, "threads": rows], includeSummaries: false)
        guard current == generation else { return }
        resumeTrace?.mark("Thread list ready")
        if let rememberedThread, threads.contains(where: { $0.id == rememberedThread }) {
            if Array(operationScope.dropFirst(2)) == Array(previousScope.dropFirst(2)) {
                attachments = previousAttachments
                contextPaths = previousContextPaths
            }
            try await loadSnapshot(rememberedThread, refreshAuxiliary: false,
                                   prefetched: result["snapshot"] as? [String: Any])
            resumeTrace?.mark("Native snapshot ready")
        }
        guard current == generation else { return }
        state = .live
        issue = ""
        resumeTrace?.mark("Live ready")
        resumeTrace?.finish(); resumeTrace = nil
        lastAuxiliaryRefresh = Date()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollLoop(current)
        }
        startEventStream(current)
        if let rememberedThread { Task { [weak self] in await self?.refreshAuxiliaryAfterResume(rememberedThread, current: current) } }
        Task { [weak self] in await self?.refreshTargets(current: current) }
        Task { [weak self] in await self?.syncAPNs() }
    }

    func syncAPNs() async {
        guard state == .live, let client, !demoPreview else { return }
        let current = generation
        let notifications = ApprovalNotifications.shared
        await notifications.refreshStatus()
        do {
            let status = try await client.apnsStatus()
            guard current == generation else { return }
            if !notifications.enabled {
                if status.enabled { try await client.unregisterAPNs() }
                if current == generation { notifications.setNativePushStatus("Disabled") }
                return
            }
            guard status.supported else {
                notifications.setNativePushStatus("Gateway APNs provider is not configured")
                return
            }
            guard notifications.permitted else {
                notifications.setNativePushStatus("Allow iPhone notifications first")
                return
            }
            guard let token = notifications.remoteToken else {
                notifications.requestRemoteRegistration()
                return
            }
            #if DEBUG
            let environment = "sandbox"
            #else
            let environment = "production"
            #endif
            try await client.registerAPNs(token: token, environment: environment)
            if current == generation { notifications.setNativePushStatus("Registered with gateway; delivery unverified") }
        } catch {
            if current == generation { notifications.setNativePushStatus("Native push unavailable: \(error.localizedDescription)") }
        }
    }

    func testAPNs() async throws {
        guard state == .live, let client else { throw GatewayFailure.native("Reconnect to test native push.") }
        try await client.testAPNs()
    }

    private func refreshAuxiliaryAfterResume(_ id: String, current: UUID) async {
        guard current == generation, selectedThreadID == id else { return }
        do {
            try await loadAuxiliaryState(id)
            if current == generation && selectedThreadID == id { lastAuxiliaryRefresh = Date(); controlsIssue = "" }
        } catch {
            if current == generation && selectedThreadID == id && !isCancelledRequest(error) {
                controlsIssue = error.localizedDescription
            }
        }
    }

    func refreshSessionControls() async {
        guard state == .live, let id = selectedThreadID else { return }
        let scope = operationScope
        do {
            try await loadAuxiliaryState(id)
            guard scope == operationScope else { return }
            lastAuxiliaryRefresh = Date()
            controlsIssue = ""
        } catch {
            if scope == operationScope && !isCancelledRequest(error) { controlsIssue = error.localizedDescription }
        }
    }

    private func refreshTargets(current: UUID) async {
        guard let client, let profile else { return }
        do {
            let result = try await GatewayClient(profile: profile, token: client.token).rpc("instance.list")
            guard current == generation, let rows = result["targets"] as? [[String: Any]] else { return }
            targets = rows.compactMap { row in
                guard let id = row["target_id"] as? String, let label = row["label"] as? String else { return nil }
                return ZedTarget(id: id, label: label, available: row["available"] as? Bool ?? false)
            }
        } catch { /* The selected, verified target stays usable. */ }
    }

    func refresh() async {
        guard !demoPreview else { return }
        guard foregroundActive else { return }
        guard state != .connecting else { return }
        guard let profile else { return }
        if state == .live, client != nil {
            guard !refreshingLive else { return }
            refreshingLive = true
            defer { refreshingLive = false }
            let current = generation
            do {
                try await loadThreads(includeSummaries: false)
                guard current == generation else { return }
                if let id = selectedThreadID, threads.contains(where: { $0.id == id }) {
                    try await loadSnapshot(id, refreshAuxiliary: false)
                }
                guard current == generation else { return }
                if issue != threadExposureIssue { issue = "" }
            } catch {
                // The poll loop keeps the authenticated route under observation.
                // A canceled foreground refresh is not evidence that Zed went offline.
            }
            return
        }
        await connect(profile)
    }

    func enterForeground() {
        foregroundActive = true
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        let monitorGeneration = UUID()
        pathMonitorGeneration = monitorGeneration
        sawInitialPath = false
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor in
                guard self?.pathMonitorGeneration == monitorGeneration else { return }
                self?.networkPathChanged(reachable: reachable)
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "dev.zedlink.network-path"))
    }

    func enterBackground() {
        foregroundActive = false
        resumeTrace?.finish(); resumeTrace = nil
        pathRetryTask?.cancel(); pathRetryTask = nil
        pathMonitorGeneration = UUID()
        pathMonitor?.cancel(); pathMonitor = nil
        generation = UUID()
        pollTask?.cancel(); pollTask = nil
        eventTask?.cancel(); eventTask = nil
        eventStreamLive = false
        if state == .live || state == .connecting || state == .reconnecting { state = .stale }
    }

    private func networkPathChanged(reachable: Bool) {
        guard foregroundActive, profile != nil, !demoPreview else { return }
        let initial = !sawInitialPath
        sawInitialPath = true
        if !reachable {
            pathRetryTask?.cancel(); pathRetryTask = nil
            // NWPath is a reachability hint, not proof that the paired gateway is down.
            // Existing authenticated polling decides whether to change the visible state.
            return
        }
        if initial { return }
        pathRetryTask?.cancel()
        let wasConnecting = state == .connecting
        pathRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            if wasConnecting {
                for _ in 0..<24 where self.state == .connecting {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                }
                if self.state == .live { return }
            }
            self.pathRetryTask = nil
            await self.refresh()
        }
    }

    func selectTarget(_ id: String) async {
        guard let profile, targets.contains(where: { $0.id == id && $0.available }) else { return }
        await connect(profile, target: id)
    }

    #if DEBUG
    func loadDemoPreview() {
        disconnect(); demoPreview = true
        profile = ConnectionProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Demo workstation", route: .local, endpoint: "https://demo.invalid", gatewayID: "demo")
        targetID = "demo-workspace"; targets = [ZedTarget(id: "demo-workspace", label: "Orbit Notes", available: false)]
        state = .live
        threads = [
            NativeThread(id: "demo-review", title: "Review deployment changes", status: "Generating", currentTurnID: 1, agentName: "Claude Code", approvalCount: 2, inputCount: 0),
            NativeThread(id: "demo-nav", title: "Improve project navigation", status: "Generating", currentTurnID: 2, agentName: "Zed Agent", approvalCount: 0, inputCount: 0),
            NativeThread(id: "demo-retry", title: "Check the integration tests", status: "Generating", currentTurnID: 3, agentName: "Codex", retrying: true, approvalCount: 0, inputCount: 0),
            NativeThread(id: "demo-docs", title: "Update the project documentation", status: "Idle", currentTurnID: nil, agentName: "Codex", approvalCount: 0, inputCount: 0),
            NativeThread(id: "demo-failed", title: "Investigate a failed test run", status: "Idle", currentTurnID: nil, agentName: "Zed Agent", failed: true, approvalCount: 0, inputCount: 0),
        ]
    }
    #endif

    func loadCreateOptions() async {
        guard capabilities.contains("thread.create.options"), let client, let instanceID, let epoch else {
            createAgents = [AgentOption(id: "zed-agent", name: "Zed Agent", kind: "zed")]
            return
        }
        do {
            let result = try await client.rpc("thread.create.options", params: [
                "instance_id": instanceID,
                "epoch": epoch,
            ])
            try checkIdentity(result)
            createAgents = (result["agents"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                return AgentOption(id: id, name: name, kind: row["kind"] as? String ?? "external_acp")
            }
        } catch { issue = error.localizedDescription }
    }

    func createThread(title: String, agentID: String) async -> Bool {
        guard capabilities.contains("thread.create"), let client, let instanceID, let epoch,
              !creatingThread else { return false }
        creatingThread = true
        defer { creatingThread = false }
        let requestID = UUID().uuidString
        do {
            for _ in 0..<40 {
                let result = try await client.rpc("thread.create", params: [
                    "instance_id": instanceID,
                    "epoch": epoch,
                    "title": title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? NSNull() : title.trimmingCharacters(in: .whitespacesAndNewlines),
                    "agent_id": agentID,
                ], requestID: requestID)
                if result["outcome"] as? String == "ready", let id = result["thread_id"] as? String {
                    try await loadThreads()
                    await select(id)
                    return true
                }
                guard result["outcome"] as? String == "creating" else {
                    throw GatewayFailure.invalidResponse
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw GatewayFailure.native("Zed is still creating the session. Refresh to check its status.")
        } catch {
            issue = error.localizedDescription
            return false
        }
    }

    private func loadThreads(prefetched: [String: Any]? = nil, includeSummaries: Bool = true) async throws {
        guard let client else { return }
        let scope = operationScope
        let result: [String: Any]
        if let prefetched { result = prefetched }
        else { result = try await client.rpc("thread.list") }
        guard scope == operationScope else { return }
        try checkIdentity(result)
        guard let rows = result["threads"] as? [[String: Any]] else { throw GatewayFailure.invalidResponse }
        var loaded = rows.compactMap { row -> NativeThread? in
            guard let id = row["thread_id"] as? String else { return nil }
            var thread = NativeThread(id: id, title: row["title"] as? String ?? "Untitled Agent thread",
                                status: row["status"] as? String ?? "Unknown",
                                currentTurnID: row["current_turn_id"] as? Int)
            thread.activity = NativeAgentActivity(row["activity"], status: thread.status, currentTurnID: thread.currentTurnID)
            thread.agentName = (row["agent"] as? [String: Any])?["name"] as? String ?? "Zed Agent"
            thread.retrying = row["retry_status"] is [String: Any]
            thread.failed = row["had_error"] as? Bool == true || row["agent_error"] is [String: Any]
            return thread
        }
        if selectedThreadID == nil && includeSummaries {
            // Read-only counts, cached for five seconds; no new adapter operation.
            for index in loaded.indices {
                guard scope == operationScope else { return }
                var thread = loaded[index]
                if let cached = summaryCache[thread.id], Date().timeIntervalSince(cached.0) < 5,
                   cached.1.currentTurnID == thread.currentTurnID, cached.1.status == thread.status {
                    thread.approvalCount = cached.1.approvalCount; thread.inputCount = cached.1.inputCount
                } else {
                    let params: [String: Any] = ["thread_id": thread.id, "instance_id": instanceID ?? "", "epoch": epoch ?? ""]
                    if capabilities.contains("thread.approvals") {
                        let result = try await client.rpc("thread.approvals", params: params)
                        guard scope == operationScope else { return }
                        thread.approvalCount = (result["approvals"] as? [[String: Any]])?.count
                    }
                    if capabilities.contains("thread.elicitations") {
                        let result = try await client.rpc("thread.elicitations", params: params)
                        thread.inputCount = (result["elicitations"] as? [[String: Any]])?.filter { $0["status"] as? String == "pending" }.count
                    }
                    guard scope == operationScope else { return }
                    summaryCache[thread.id] = (Date(), thread)
                }
                loaded[index] = thread
            }
        }
        guard scope == operationScope else { return }
        threads = loaded
        if let selectedThreadID, !threads.contains(where: { $0.id == selectedThreadID }) {
            self.selectedThreadID = nil
            snapshot = nil
            lastSnapshotAt = nil
            controlsIssue = ""
            liveActivity = .ready
            commands = []
            lastCommandsRefresh = .distantPast
            issue = threadExposureIssue
        }
    }

    func select(_ id: String) async {
        localExposureStopped = false
        guard threads.contains(where: { $0.id == id }) else { return }
        if selectedThreadID != id {
            childHistory.removeAll()
            selectedThreadID = id
            if let profile, let targetID {
                UserDefaults.standard.set(id, forKey: selectedThreadKey(profile, targetID: targetID))
            }
            attachments = []; contextPaths = []; supportsImages = nil; threadSettings = nil
            elicitations = []; queuedMessages = []; editReview = nil
            diffContent = ""; diffLoading = false; diffRequest = UUID()
            previewRequest = UUID(); previewReadable = false; previewLoading = false; previewContent = ""; previewTitle = ""
            projectFolderEntries = nil; directoryRequest = UUID()
            projectFiles = []; projectFilesTruncated = false
            snapshot = nil
            lastSnapshotAt = nil
            controlsIssue = ""
            liveActivity = threads.first(where: { $0.id == id })?.activity ?? .ready
            commands = []
            lastCommandsRefresh = .distantPast
            if let profile {
                draft = UserDefaults.standard.string(forKey: draftKey(profileID: profile.id, targetID: targetID, threadID: id)) ?? ""
            }
        }
        let scope = operationScope
        do {
            try await loadSnapshot(id, refreshAuxiliary: false)
            guard scope == operationScope else { return }
            issue = ""
            startEventStream(generation)
            let current = generation
            Task { [weak self] in await self?.refreshAuxiliaryAfterResume(id, current: current) }
        }
        catch {
            guard scope == operationScope else { return }
            if !isCancelledRequest(error) { issue = "Conversation could not refresh: \(error.localizedDescription)" }
        }
    }

    private func startEventStream(_ current: UUID) {
        eventTask?.cancel()
        eventStreamLive = false
        guard let client, let threadID = selectedThreadID else { return }
        eventTask = Task { [weak self] in
            guard let self else { return }
            var delay = 1
            while !Task.isCancelled && current == generation && selectedThreadID == threadID {
                do {
                    let stream = try client.eventStream(threadID: threadID, afterSequence: snapshot?.lastSequence ?? 0)
                    for try await result in stream {
                        guard current == generation, selectedThreadID == threadID else { return }
                        try checkIdentity(result)
                        guard result["thread_id"] as? String == threadID else { throw GatewayFailure.invalidResponse }
                        if !eventStreamLive { eventStreamLive = true; ResumeTrace.streamReady() }
                        delay = 1
                        let events = result["events"] as? [[String: Any]] ?? []
                        notifyTurnEvents(events, threadID: threadID)
                        applyEventActivity(events)
                        if events.contains(where: { $0["kind"] as? String == "entry.removed" }) { snapshot = nil }
                        let heartbeatDue = snapshot?.isBusy == true && Date().timeIntervalSince(lastFastSnapshot) >= 1
                        if !events.isEmpty || snapshot == nil || heartbeatDue {
                            try await loadSnapshot(threadID, refreshAuxiliary: false)
                        }
                        if !events.isEmpty && Date().timeIntervalSince(lastAuxiliaryRefresh) >= 2 {
                            do {
                                try await loadAuxiliaryState(threadID)
                                lastAuxiliaryRefresh = Date()
                                controlsIssue = ""
                            } catch is CancellationError { return }
                            catch { controlsIssue = error.localizedDescription }
                        }
                    }
                    eventStreamLive = false
                    if Task.isCancelled || current != generation || selectedThreadID != threadID { return }
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(10, delay * 2)
                } catch {
                    eventStreamLive = false
                    if Task.isCancelled || current != generation || selectedThreadID != threadID { return }
                    if case GatewayFailure.native("RESYNC_REQUIRED") = error {
                        snapshot = nil
                        do { try await loadSnapshot(threadID) }
                        catch { if current == generation { issue = error.localizedDescription; state = .stale } }
                    }
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(10, delay * 2)
                }
            }
        }
    }

    func renameSelectedThread(to proposedTitle: String) async -> Bool {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard capabilities.contains("thread.rename"), !title.isEmpty,
              let client, let instanceID, let epoch, let threadID = selectedThreadID else { return false }
        do {
            let result = try await client.rpc("thread.rename", params: [
                "instance_id": instanceID, "epoch": epoch,
                "thread_id": threadID, "title": title,
            ])
            guard result["outcome"] as? String == "requested" else { throw GatewayFailure.invalidResponse }
            try await loadThreads()
            delivery = "Session renamed in desktop Zed."
            return true
        } catch {
            issue = error.localizedDescription
            return false
        }
    }

    func unexposeSelectedThread() async -> Bool {
        guard capabilities.contains("thread.unexpose"), let client, let instanceID, let epoch,
              let threadID = selectedThreadID else { return false }
        do {
            let result = try await client.rpc("thread.unexpose", params: [
                "instance_id": instanceID, "epoch": epoch, "thread_id": threadID,
            ])
            guard result["outcome"] as? String == "unexposed" else { throw GatewayFailure.invalidResponse }
            cacheTask?.cancel(); cacheTask = nil
            if let profile, let targetID {
                await ConversationCache.shared.remove(gatewayID: profile.gatewayID, targetID: targetID, threadID: threadID)
                cachedConversations.removeAll { $0.threadID == threadID }
                UserDefaults.standard.removeObject(forKey: selectedThreadKey(profile, targetID: targetID))
            }
            selectedThreadID = nil
            snapshot = nil
            lastSnapshotAt = nil
            controlsIssue = ""
            liveActivity = .ready
            commands = []
            try await loadThreads()
            delivery = "Remote exposure stopped. The Agent thread remains open in desktop Zed."
            issue = ""
            return true
        } catch {
            issue = error.localizedDescription
            return false
        }
    }

    private func loadSnapshot(_ id: String, refreshAuxiliary: Bool = true,
                              prefetched: [String: Any]? = nil) async throws {
        guard let client else { return }
        let scope = operationScope
        var params: [String: Any] = ["thread_id": id, "tail_entry_count": 24]
        if let old = snapshot, old.threadID == id {
            params["tail_entry_count"] = 16
            if capabilities.contains("thread.snapshot.delta"),
               old.instanceID == instanceID, old.epoch == epoch {
                params["instance_id"] = old.instanceID
                params["epoch"] = old.epoch
                params["after_sequence"] = old.lastSequence
                params["entry_start_index"] = old.entryStartIndex
                params["entry_end_index"] = old.entryStartIndex + old.entries.count
            }
        }
        let result: [String: Any]
        if let prefetched { result = prefetched }
        else { result = try await client.rpc("thread.snapshot", params: params) }
        guard scope == operationScope else { return }
        try checkIdentity(result)
        guard result["thread_id"] as? String == id,
              let entries = result["entries_markdown"] as? [String],
              let sequence = result["last_sequence"] as? Int else { throw GatewayFailure.invalidResponse }
        guard selectedThreadID == id else { return }
        // A slower poll must not overwrite a newer streamed snapshot.
        if let old = snapshot, old.threadID == id, sequence < old.lastSequence { return }
        let pageStart = result["entry_start_index"] as? Int ?? 0
        let pageEnd = result["entry_end_index"] as? Int ?? pageStart + entries.count
        let totalEntries = result["total_entries"] as? Int ?? pageEnd
        guard pageStart >= 0, pageEnd == pageStart + entries.count, totalEntries >= pageEnd else {
            throw GatewayFailure.invalidResponse
        }
        if entries.isEmpty && totalEntries > 0 && result["delta"] as? Bool != true {
            throw GatewayFailure.invalidResponse
        }
        var mergedEntries = entries
        let pageMeta = NativeEntryMeta.page(result["entries_meta"], count: entries.count)
        var mergedMeta = pageMeta
        var mergedStart = pageStart
        let delta = result["delta"] as? Bool == true
        if delta, snapshot?.threadID != id { throw GatewayFailure.invalidResponse }
        if delta, let old = snapshot, old.threadID == id,
           pageStart >= old.entryStartIndex,
           pageStart <= old.entryStartIndex + old.entries.count {
            if entries.isEmpty && pageStart == old.entryStartIndex + old.entries.count {
                mergedEntries = old.entries
                mergedMeta = old.entryMeta.count == old.entries.count ? old.entryMeta : Array(repeating: nil, count: old.entries.count)
            } else {
                mergedEntries = Array(old.entries.prefix(pageStart - old.entryStartIndex)) + entries
                let previous = old.entryMeta.count == old.entries.count ? old.entryMeta : Array(repeating: nil, count: old.entries.count)
                mergedMeta = Array(previous.prefix(pageStart - old.entryStartIndex)) + pageMeta
            }
            mergedStart = old.entryStartIndex
        } else if delta {
            throw GatewayFailure.native("RESYNC_REQUIRED")
        }
        if snapshot?.threadID != id && mergedEntries.count > 24 {
            mergedStart += mergedEntries.count - 24
            mergedMeta = Array(mergedMeta.suffix(24))
            mergedEntries = Array(mergedEntries.suffix(24))
        }
        let childApprovalRows = (result["subagents"] as? [[String: Any]] ?? []).flatMap { child in
            child["pending_approvals"] as? [[String: Any]] ?? []
        }
        let approvalRows = (result["pending_approvals"] as? [[String: Any]] ?? []) + childApprovalRows
        let approvals = approvalRows.compactMap { row -> NativeApproval? in
            guard let approvalID = row["approval_id"] as? String else { return nil }
            let permissionOptions = row["permission_options"] as? [String: Any]
            let decisions = (permissionOptions?["decisions"] as? [[String: Any]] ?? []).compactMap { decision -> NativeApprovalDecision? in
                guard let optionID = decision["option_id"] as? String else { return nil }
                return NativeApprovalDecision(
                    optionID: optionID,
                    label: decision["label"] as? String ?? "Choose",
                    optionKind: decision["option_kind"] as? String ?? "unknown",
                    choiceIndex: decision["choice_index"] as? Int,
                    selectedPatternIndices: decision["selected_pattern_indices"] as? [Int] ?? [],
                    action: decision["action"] as? String
                )
            }
            return NativeApproval(id: approvalID,
                                  turnID: row["turn_id"] as? Int,
                                  toolName: row["tool_name"] as? String ?? "Zed tool",
                                  display: row["display"] as? String ?? "Permission requested",
                                  rawInput: Self.jsonText(row["raw_input"]),
                                  detailsTruncated: row["details_truncated"] as? Bool ?? true,
                                  canApproveOnce: row["can_approve_once"] as? Bool ?? false,
                                  canDenyOnce: row["can_deny_once"] as? Bool ?? false,
                                  subagentID: row["subagent_id"] as? String,
                                  authorizationKind: row["authorization_kind"] as? String ?? "permission_grant",
                                  decisions: decisions)
        }
        let rewindPoints = (result["rewind_points"] as? [[String: Any]] ?? []).compactMap { row -> NativeRewindPoint? in
            guard let clientID = row["client_user_message_id"] as? String,
                  let entryIndex = row["entry_index"] as? Int else { return nil }
            return NativeRewindPoint(id: clientID, entryIndex: entryIndex,
                                     entriesRemoved: row["entries_removed"] as? Int ?? 0)
        }
        let subagents = (result["subagents"] as? [[String: Any]] ?? []).compactMap { row -> NativeSubagent? in
            guard let id = row["session_id"] as? String else { return nil }
            return NativeSubagent(id: id, title: row["title"] as? String ?? row["label"] as? String ?? "Parallel agent",
                                  status: row["status"] as? String ?? "Unknown",
                                  currentTurnID: row["current_turn_id"] as? Int,
                                  entries: row["entries_markdown"] as? [String] ?? [], entryStartIndex: row["entry_start_index"] as? Int ?? 0, totalEntries: row["total_entries"] as? Int ?? 0, entriesTruncated: row["entries_truncated"] as? Bool ?? false)
        }
        lastChildSnapshot = Date()
        var seenChildren = Set<String>()
        let uniqueSubagents = subagents.reversed().filter { seenChildren.insert($0.id).inserted }.reversed().map { child -> NativeSubagent in
            var child = child
            if let history = childHistory[child.id], history.scope == operationScope, history.end >= child.entryStartIndex && history.start <= child.entryStartIndex && history.end <= child.totalEntries {
                child = NativeSubagent(id: child.id, title: child.title, status: child.status, currentTurnID: child.currentTurnID, entries: Array(history.entries.prefix(child.entryStartIndex - history.start)) + child.entries, entryStartIndex: history.start, totalEntries: child.totalEntries, entriesTruncated: history.start > 0)
            }
            childHistory[child.id] = (operationScope, child.entryStartIndex, child.entryStartIndex + child.entries.count, child.entries)
            return child
        }
        let nativeTitle = result["title"] as? String
        let title = nativeTitle.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? (snapshot?.threadID == id ? snapshot?.title : nil)
            ?? threads.first(where: { $0.id == id })?.title ?? "Untitled Agent thread"
        let nativeStatus = result["status"] as? String ?? "Unknown"
        let nativeTurnID = result["current_turn_id"] as? Int
        let nextActivity = NativeAgentActivity(result["activity"], status: nativeStatus, currentTurnID: nativeTurnID)
        if liveActivity != nextActivity { liveActivity = nextActivity }
        if let index = threads.firstIndex(where: { $0.id == id }), threads[index].activity != nextActivity {
            threads[index].activity = nextActivity
        }
        let nextSnapshot = ThreadSnapshot(threadID: id,
                                  title: title,
                                  status: nativeStatus,
                                  currentTurnID: nativeTurnID,
                                  instanceID: instanceID ?? "", epoch: epoch ?? "",
                                  lastSequence: sequence, entries: mergedEntries,
                                  entryStartIndex: mergedStart, totalEntries: totalEntries,
                                  hasOlderEntries: mergedStart > 0,
                                  activityEntries: delta ? mergedEntries : (result["activity_entries_markdown"] as? [String] ?? entries),
                                  truncated: result["truncated"] as? Bool ?? false,
                                  activityTruncated: delta ? mergedStart > 0 : (result["activity_truncated"] as? Bool ?? false),
                                  pendingApprovals: approvals, rewindPoints: rewindPoints, subagents: uniqueSubagents,
                                  agentError: NativeAgentError(snapshot: result), entryMeta: mergedMeta)
        let snapshotChanged = snapshot != nextSnapshot
        if snapshotChanged {
            snapshot = nextSnapshot
            scheduleCacheSave()
        }
        if snapshotChanged || Date().timeIntervalSince(lastSnapshotAt ?? .distantPast) >= 5 {
            lastSnapshotAt = Date()
        }
        if let profile, let targetID, let instanceID, let epoch {
            ApprovalNotifications.shared.update(gateway: profile.gatewayID, target: targetID,
                instance: instanceID, epoch: epoch, thread: id, approvals: approvals, allowActions: capabilities.contains("approval.respond"),
                activity: liveActivity, turnID: nativeTurnID, agentError: snapshot?.agentError)
        }
        lastFastSnapshot = Date()
        if refreshAuxiliary {
            do {
                try await loadAuxiliaryState(id)
                guard scope == operationScope else { return }
                lastAuxiliaryRefresh = Date()
                controlsIssue = ""
            } catch let error as CancellationError { throw error }
            catch {
                if scope == operationScope { controlsIssue = error.localizedDescription }
            }
        }
    }

    private func notifyTurnEvents(_ events: [[String: Any]], threadID: String) {
        guard let profile, let targetID, let instanceID, let epoch else { return }
        ApprovalNotifications.shared.notifyTurnEvents(gateway: profile.gatewayID, target: targetID,
            instance: instanceID, epoch: epoch, thread: threadID, events: events)
    }

    private func applyEventActivity(_ events: [[String: Any]]) {
        guard let row = events.reversed().compactMap({ $0["activity"] as? [String: Any] }).first else { return }
        let nextActivity = NativeAgentActivity(row, status: snapshot?.status ?? "Unknown", currentTurnID: snapshot?.currentTurnID)
        if liveActivity != nextActivity { liveActivity = nextActivity }
        if let id = selectedThreadID, let index = threads.firstIndex(where: { $0.id == id }),
           threads[index].activity != nextActivity {
            threads[index].activity = nextActivity
        }
    }

    private func loadAuxiliaryState(_ id: String) async throws {
        if Date().timeIntervalSince(lastCommandsRefresh) >= 5 { try await loadCommands(id) }
        guard let client, id == selectedThreadID else { return }
        let scope = operationScope
        let base: [String: Any] = ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": id]
        if capabilities.contains("thread.elicitations") {
            let result = try await client.rpc("thread.elicitations", params: base)
            guard scope == operationScope else { return }
            let rows = result["elicitations"] as? [[String: Any]] ?? []
            elicitations = rows.compactMap(Self.decodeElicitation)
            if let profile, let targetID, let instanceID, let epoch {
                ApprovalNotifications.shared.notifyInputs(gateway: profile.gatewayID, target: targetID,
                    instance: instanceID, epoch: epoch, thread: id, inputIDs: elicitations.map(\.id))
            }
        } else { elicitations = [] }
        if capabilities.contains("thread.queue") {
            let result = try await client.rpc("thread.queue", params: base)
            guard scope == operationScope else { return }
            queuedMessages = (result["entries"] as? [[String: Any]] ?? []).compactMap { row in
                guard let index = row["index"] as? Int else { return nil }
                return NativeQueueEntry(id: index, preview: row["preview"] as? String ?? "Attachment",
                                        steer: row["steer"] as? Bool ?? false)
            }
        } else { queuedMessages = [] }
        if capabilities.contains("thread.edit_review") {
            let result = try await client.rpc("thread.edit_review", params: base)
            guard scope == operationScope else { return }
            editReview = result["pending"] as? Bool == true
                ? NativeEditReview(changedFiles: result["changed_files"] as? Int ?? 0,
                                   linesAdded: result["lines_added"] as? Int ?? 0,
                                   linesRemoved: result["lines_removed"] as? Int ?? 0) : nil
        } else { editReview = nil }
        if capabilities.contains("thread.settings") {
            let result = try await client.rpc("thread.settings", params: base)
            guard scope == operationScope else { return }
            let selected = result["model"] as? [String: Any]
            let usage = result["context_usage"] as? [String: Any]
            let models = (result["models"] as? [[String: Any]] ?? []).compactMap { row -> NativeModelOption? in
                guard let modelID = row["id"] as? String, let providerID = row["provider_id"] as? String else { return nil }
                return NativeModelOption(id: "\(providerID)\n\(modelID)", providerID: providerID,
                                         name: row["name"] as? String ?? modelID)
            }
            supportsImages = result["supports_images"] as? Bool
            threadSettings = NativeThreadSettings(modelID: selected?["id"] as? String,
                                                  providerID: selected?["provider_id"] as? String,
                                                  models: models, usedTokens: usage?["used_tokens"] as? Int,
                                                  maxTokens: usage?["max_tokens"] as? Int,
                                                  inputTokens: usage?["input_tokens"] as? Int,
                                                  outputTokens: usage?["output_tokens"] as? Int,
                                                  remainingTokens: usage?["remaining_tokens"] as? Int,
                                                  profileID: result["profile_id"] as? String,
                                                  profiles: (result["profiles"] as? [[String: Any]] ?? []).compactMap { row in
                                                      guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }; return NativeAgentProfile(id: id, name: name)
                                                  }, thinkingEnabled: result["thinking_enabled"] as? Bool, thinkingSupported: result["thinking_supported"] as? Bool ?? false, thinkingCanDisable: result["thinking_can_disable"] as? Bool ?? false)
        } else { threadSettings = nil }
    }


    private static func decodeElicitation(_ row: [String: Any]) -> NativeElicitation? {
        guard row["status"] as? String == "pending",
              let elicitationID = row["elicitation_id"] as? String,
              let request = row["request"] as? [String: Any] else { return nil }
        let schema = request["requestedSchema"] as? [String: Any]
        let required = Set(schema?["required"] as? [String] ?? [])
        let properties = schema?["properties"] as? [String: [String: Any]] ?? [:]
        var fields: [NativeElicitationField] = []
        for (name, value) in properties {
            let oneOfRows = value["oneOf"] as? [[String: Any]] ?? []
            let oneOf = oneOfRows.compactMap { $0["const"].map(String.init(describing:)) }
            let items = value["items"] as? [String: Any]
            let itemRows = items?["oneOf"] as? [[String: Any]] ?? []
            let itemOneOf = itemRows.compactMap { $0["const"].map(String.init(describing:)) }
            let directChoices = (value["enum"] as? [Any] ?? []).map(String.init(describing:))
            let itemChoices = (items?["enum"] as? [Any] ?? []).map(String.init(describing:))
            fields.append(NativeElicitationField(id: name, title: value["title"] as? String ?? name,
                                                  type: value["type"] as? String ?? "string",
                                                  required: required.contains(name),
                                                  choices: directChoices + oneOf + itemChoices + itemOneOf,
                                                  defaultValue: Self.formDefault(value["default"], type: value["type"] as? String),
                                                  minimum: value["minimum"] as? Double, maximum: value["maximum"] as? Double,
                                                  minLength: value["minLength"] as? Int, maxLength: value["maxLength"] as? Int))
        }
        fields.sort { $0.id < $1.id }
        return NativeElicitation(id: elicitationID,
                                 message: request["message"] as? String ?? "Agent needs more information",
                                 url: request["url"] as? String, fields: fields)
    }

    private static func formDefault(_ value: Any?, type: String?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if type == "array", let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) { return text }
        if type == "boolean", let bool = value as? Bool { return bool ? "true" : "false" }
        return String(describing: value)
    }

    func respondToElicitation(_ elicitation: NativeElicitation, action: String, content: [String: Any] = [:]) async {
        guard state == .live, capabilities.contains("elicitation.respond"), !isRespondingToElicitation(elicitation.id),
              let client, let threadID = selectedThreadID, elicitations.contains(where: { $0.id == elicitation.id }) else { return }
        let scope = operationScope
        let key = (scope + [elicitation.id]).joined(separator: "\n")
        resolvingElicitations.insert(key)
        defer { resolvingElicitations.remove(key) }
        do {
            let result = try await client.rpc("elicitation.respond", params: [
                "instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID,
                "elicitation_id": elicitation.id, "action": action, "content": content,
            ])
            guard scope == operationScope else { return }
            guard result["outcome"] as? String == "resolved" else { throw GatewayFailure.invalidResponse }
            try await loadAuxiliaryState(threadID)
        } catch { if scope == operationScope { issue = error.localizedDescription } }
    }

    func clearQueue() async {
        guard let client, let threadID = selectedThreadID else { return }
        do {
            _ = try await client.rpc("thread.queue.clear", params: ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID])
            try await loadAuxiliaryState(threadID)
        } catch { issue = error.localizedDescription }
    }

    func resolveEditReview(_ action: String) async {
        guard let client, let threadID = selectedThreadID else { return }
        do {
            _ = try await client.rpc("thread.edit_review.respond", params: ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID, "action": action, "expected_last_sequence": snapshot?.lastSequence ?? 0])
            try await loadAuxiliaryState(threadID)
        } catch { issue = error.localizedDescription }
    }

    func rewind(to point: NativeRewindPoint) async {
        guard let client, let threadID = selectedThreadID else { return }
        do {
            _ = try await client.rpc("thread.rewind", params: [
                "instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID,
                "client_user_message_id": point.id, "expected_last_sequence": snapshot?.lastSequence ?? 0,
            ])
            snapshot = nil
            try await loadSnapshot(threadID)
        } catch { issue = error.localizedDescription }
    }

    private var lastChildSnapshot = Date.distantPast
    private var childHistory: [String: (scope: [String], start: Int, end: Int, entries: [String])] = [:]
    @Published private(set) var loadingChildHistory = false

    func loadEarlierSubagent(_ childID: String) async {
        guard !loadingChildHistory, let client, let threadID = selectedThreadID,
              let child = snapshot?.subagents.first(where: { $0.id == childID }), child.entryStartIndex > 0 else { return }
        let scope = operationScope
        loadingChildHistory = true
        defer { loadingChildHistory = false }
        do {
            let result = try await client.rpc("thread.history", params: ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID, "subagent_id": childID, "before_entry_index": child.entryStartIndex])
            guard scope == operationScope, result["thread_id"] as? String == threadID, result["subagent_id"] as? String == childID,
                  let start = result["entry_start_index"] as? Int, let end = result["entry_end_index"] as? Int,
                  let entries = result["entries_markdown"] as? [String], start >= 0, end == child.entryStartIndex, start + entries.count == end else { return }
            childHistory[childID] = (scope, start, child.entryStartIndex + child.entries.count, entries + child.entries)
            try await loadSnapshot(threadID)
        } catch { if scope == operationScope { issue = error.localizedDescription } }
    }

    func cancelSubagent(_ subagent: NativeSubagent) async {
        guard let client, let threadID = selectedThreadID, let turnID = subagent.currentTurnID else { return }
        do {
            _ = try await client.rpc("subagent.cancel", params: [
                "instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID,
                "subagent_id": subagent.id, "turn_id": turnID,
            ])
            try await loadSnapshot(threadID)
        } catch { issue = error.localizedDescription }
    }

    @Published private(set) var updatingModel = false

    func selectModel(_ option: NativeModelOption) async { await updateAgentSettings(model: option) }

    func updateAgentSettings(model: NativeModelOption? = nil, profileID: String? = nil, thinking: Bool? = nil) async {
        guard state == .live, snapshot?.status == "Idle", !updatingModel, capabilities.contains("thread.settings.update"), let client, let threadID = selectedThreadID, snapshot?.threadID == threadID,
              let settings = threadSettings else { return }
        if let model, !settings.models.contains(where: { $0.id == model.id }) { return }
        if let profileID, !settings.profiles.contains(where: { $0.id == profileID }) { return }
        if let thinking, !settings.thinkingSupported || (!thinking && !settings.thinkingCanDisable) { return }
        updatingModel = true
        defer { updatingModel = false }
        let scope = operationScope
        do {
            var params: [String: Any] = ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID]
            if let model { params["provider_id"] = model.providerID; params["model_id"] = model.id.split(separator: "\n").last.map(String.init) ?? "" }
            if let profileID { params["profile_id"] = profileID }
            if let thinking { params["thinking_enabled"] = thinking }
            _ = try await client.rpc("thread.settings.update", params: params)
            guard scope == operationScope else { return }
            try await loadAuxiliaryState(threadID)
        } catch { if scope == operationScope { issue = error.localizedDescription } }
    }

    func loadProjectContext(page: WorkspacePage? = nil) async {
        guard let client, let threadID = selectedThreadID else { return }
        let request = UUID(); workspaceRequest = request; workspaceLoading = true
        defer { if workspaceRequest == request { workspaceLoading = false } }
        let scope = (profile?.id, targetID, instanceID, epoch, threadID)
        func current() -> Bool {
            !Task.isCancelled && scope.0 == profile?.id && scope.1 == targetID && scope.2 == instanceID && scope.3 == epoch && scope.4 == selectedThreadID
        }
        do {
            let info = try await client.rpc("instance.info")
            guard current() else { return }
            try checkIdentity(info)
            capabilities = Set(info["capabilities"] as? [String] ?? [])
            let base: [String: Any] = ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID]
            if page == nil || page == .files {
                if capabilities.contains("project.files") {
                    let result = try await client.rpc("project.files", params: base)
                    guard current() else { return }
                    projectFilesTruncated = result["truncated"] as? Bool ?? false
                    projectFiles = (result["entries"] as? [[String: Any]] ?? []).compactMap { row in
                        guard let path = row["path"] as? String else { return nil }
                        return NativeProjectFile(id: path, kind: row["kind"] as? String ?? "file", size: row["size"] as? Int)
                    }
                }
            }
            if page == nil || page == .changes {
                if capabilities.contains("changes.snapshot") {
                    let result = try await client.rpc("changes.snapshot", params: base)
                    guard current() else { return }
                    let revision = (result["repository"] as? [String: Any])?["revision"] as? String
                    if revision != changesRevision { diffContent = "" }
                    changesRevision = revision
                    changes = (result["entries"] as? [[String: Any]] ?? []).compactMap { row in
                        guard let path = row["path"] as? String else { return nil }
                        return NativeChange(id: path, status: row["status"] as? String ?? "changed", staging: row["staging"] as? String ?? "unstaged")
                    }
                }
            }
            if page == nil || page == .terminal {
                if capabilities.contains("terminal.list") {
                    let result = try await client.rpc("terminal.list", params: ["instance_id": instanceID ?? "", "epoch": epoch ?? ""])
                    guard current() else { return }
                    terminals = (result["terminals"] as? [[String: Any]] ?? []).compactMap(Self.decodeTerminal)
                    if terminalSnapshot == nil {
                        let key = "zedlink.terminal.\([profile?.id.uuidString ?? "", targetID ?? "", instanceID ?? "", epoch ?? ""].joined(separator: "."))"
                        if let saved = UserDefaults.standard.string(forKey: key), let terminal = terminals.first(where: { $0.id == saved }) { await loadTerminal(terminal) }
                    }
                    if let selected = terminalSnapshot?.terminal.id, !terminals.contains(where: { $0.id == selected }) {
                        terminalSnapshot = nil
                    }
                } else {
                    terminals = []
                    terminalSnapshot = nil
                }
            }
            if page == nil || page == .terminal {
                if capabilities.contains("task.catalog") {
                    let result = try await client.rpc("task.catalog", params: ["instance_id": instanceID ?? "", "epoch": epoch ?? ""])
                    guard current() else { return }
                    configuredTasks = (result["tasks"] as? [[String: Any]] ?? []).compactMap { row in
                        guard let id = row["task_id"] as? String, let label = row["label"] as? String else { return nil }
                        return NativeConfiguredTask(id: id, label: label, source: row["source"] as? String ?? "project")
                    }
                } else { configuredTasks = [] }
            }
            if page == nil || page == .debug {
                if capabilities.contains("debugger.catalog") {
                    let result = try await client.rpc("debugger.catalog", params: ["instance_id": instanceID ?? "", "epoch": epoch ?? ""])
                    guard current() else { return }
                    debuggerCatalog = (result["scenarios"] as? [[String: Any]] ?? []).compactMap { row in
                        guard let id = row["scenario_id"] as? String, let label = row["label"] as? String else { return nil }
                        return NativeDebugScenario(id: id, label: label, adapter: row["adapter"] as? String ?? "DAP", source: row["source"] as? String ?? "project")
                    }
                } else { debuggerCatalog = [] }
            }
            if page == nil || page == .debug {
                if capabilities.contains("debugger.snapshot") {
                    let result = try await client.rpc("debugger.snapshot", params: ["instance_id": instanceID ?? "", "epoch": epoch ?? ""])
                    guard current() else { return }
                    debuggerSessions = (result["sessions"] as? [[String: Any]] ?? []).compactMap(Self.decodeDebuggerSession)
                } else { debuggerSessions = [] }
            }
        } catch { if current() { issue = error.localizedDescription } }
    }

    func runConfiguredTask(_ task: NativeConfiguredTask) async {
        guard state == .live, let client, capabilities.contains("task.run") else { return }
        let scope = operationScope
        do {
            _ = try await client.rpc("task.run", params: [
                "instance_id": instanceID ?? "", "epoch": epoch ?? "", "task_id": task.id,
            ], requestID: UUID().uuidString)
            try? await Task.sleep(for: .milliseconds(250))
            guard scope == operationScope else { return }
            await loadProjectContext(page: .terminal)
        } catch { if scope == operationScope { issue = error.localizedDescription } }
    }

    func controlDebugger(_ session: NativeDebuggerSession, action: String, thread: NativeDebuggerThread? = nil) async {
        guard state == .live, let client, capabilities.contains("debugger.control") else { return }
        var params: [String: Any] = [
            "instance_id": instanceID ?? "", "epoch": epoch ?? "", "session_id": session.id, "action": action,
        ]
        if let thread { params["thread_id"] = thread.id }
        let scope = operationScope
        do {
            _ = try await client.rpc("debugger.control", params: params, requestID: UUID().uuidString)
            try? await Task.sleep(for: .milliseconds(180))
            guard scope == operationScope else { return }
            await loadProjectContext(page: .debug)
        } catch { if scope == operationScope { issue = error.localizedDescription } }
    }

    func launchDebugger(_ scenario: NativeDebugScenario) async {
        guard state == .live, let client, capabilities.contains("debugger.launch") else { return }
        let scope = operationScope
        do {
            _ = try await client.rpc("debugger.launch", params: [
                "instance_id": instanceID ?? "", "epoch": epoch ?? "", "scenario_id": scenario.id,
            ], requestID: UUID().uuidString)
            try? await Task.sleep(for: .milliseconds(350))
            guard scope == operationScope else { return }
            await loadProjectContext(page: .debug)
        } catch { if scope == operationScope { issue = error.localizedDescription } }
    }

    private static func decodeDebuggerSession(_ row: [String: Any]) -> NativeDebuggerSession? {
        guard let id = row["session_id"] as? String else { return nil }
        let capabilities = row["capabilities"] as? [String: Any]
        let threads = (row["threads"] as? [[String: Any]] ?? []).compactMap { thread -> NativeDebuggerThread? in
            guard let id = thread["thread_id"] as? Int else { return nil }
            return NativeDebuggerThread(id: id, name: thread["name"] as? String ?? "Thread \(id)", status: thread["status"] as? String ?? "unknown")
        }
        return NativeDebuggerSession(id: id, label: row["label"] as? String ?? "Debugger",
                                     adapter: row["adapter"] as? String ?? "DAP",
                                     terminated: row["terminated"] as? Bool ?? false,
                                     canRestart: capabilities?["restart"] as? Bool ?? false,
                                     canStepBack: capabilities?["step_back"] as? Bool ?? false, threads: threads)
    }

    func transferClipboard(_ text: String? = nil) async -> String? {
        let method = text == nil ? "clipboard.read" : "clipboard.write"
        guard let client, capabilities.contains(method), let selectedThreadID else {
            issue = "Enable Remote Clipboard in desktop ZedLink settings."; return nil
        }
        let scope = operationScope
        var params: [String: Any] = ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": selectedThreadID]
        if let text { guard text.utf8.count <= 65536, !text.contains("\0") else { issue = "Clipboard exceeds 64 KiB or contains a null character."; return nil }; params["text"] = text }
        do {
            let result = try await client.rpc(method, params: params)
            guard scope == operationScope else { return nil }
            if text != nil { return text }
            guard let value = result["text"] as? String, value.utf8.count <= 65536 else { throw GatewayFailure.invalidResponse }
            return value
        } catch { issue = error.localizedDescription; return nil }
    }

    private var requestedTerminalID: String?
    private var requestedTerminalSize: (id: String, columns: Int, rows: Int)?
    func createTerminal() async {
        guard state == .live, !creatingTerminal, capabilities.contains("terminal.create"),
              let client, let threadID = selectedThreadID else { return }
        let scope = [profile?.id.uuidString ?? "", targetID ?? "", instanceID ?? "", epoch ?? "", threadID]
        let receiptKey = "zedlink.terminalCreate.\(scope.joined(separator: "."))"
        let requestID = UserDefaults.standard.string(forKey: receiptKey) ?? UUID().uuidString
        UserDefaults.standard.set(requestID, forKey: receiptKey)
        creatingTerminal = true
        defer { creatingTerminal = false }
        do {
            let params: [String: Any] = ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID]
            for _ in 0..<10 {
                guard scope == [profile?.id.uuidString ?? "", targetID ?? "", instanceID ?? "", epoch ?? "", selectedThreadID ?? ""],
                      state == .live, capabilities.contains("terminal.create") else { return }
                let result = try await client.rpc("terminal.create", params: params, requestID: requestID)
                guard scope == [profile?.id.uuidString ?? "", targetID ?? "", instanceID ?? "", epoch ?? "", selectedThreadID ?? ""] else { return }
                if result["outcome"] as? String == "ready" {
                    guard let row = result["terminal"] as? [String: Any], let terminal = Self.decodeTerminal(row) else { throw GatewayFailure.invalidResponse }
                    terminals.removeAll { $0.id == terminal.id }; terminals.append(terminal)
                    await loadTerminal(terminal)
                    UserDefaults.standard.removeObject(forKey: receiptKey)
                    return
                }
                guard result["outcome"] as? String == "pending" else { throw GatewayFailure.invalidResponse }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            issue = "Terminal is still starting. Tap New terminal again to check the same request."
        } catch is CancellationError { return }
        catch {
            if scope == [profile?.id.uuidString ?? "", targetID ?? "", instanceID ?? "", epoch ?? "", selectedThreadID ?? ""] {
                issue = "\(error.localizedDescription) New terminal checks the same request without creating a duplicate."
            }
        }
    }

    func loadTerminal(_ terminal: NativeTerminal, refresh: Bool = false) async {
        if refresh && requestedTerminalID != terminal.id { return }
        if !refresh { requestedTerminalID = terminal.id }
        guard let client, capabilities.contains("terminal.snapshot") else { return }
        let scope = [profile?.id.uuidString ?? "", targetID ?? "", instanceID ?? "", epoch ?? ""]
        do {
            let result = try await client.rpc("terminal.snapshot", params: [
                "instance_id": instanceID ?? "", "epoch": epoch ?? "", "terminal_id": terminal.id,
            ])
            guard requestedTerminalID == terminal.id, scope == [profile?.id.uuidString ?? "", targetID ?? "", instanceID ?? "", epoch ?? ""], terminals.contains(where: { $0.id == terminal.id }) else { return }
            guard let row = result["terminal"] as? [String: Any], let decoded = Self.decodeTerminal(row) else { throw GatewayFailure.invalidResponse }
            let runs = (result["styled_runs"] as? [[String: Any]] ?? []).prefix(2048).compactMap { row -> NativeTerminalRun? in
                guard let text = row["text"] as? String else { return nil }
                return NativeTerminalRun(text: text, foreground: row["foreground"] as? String ?? "", background: row["background"] as? String ?? "", bold: row["bold"] as? Bool ?? false, italic: row["italic"] as? Bool ?? false, underline: row["underline"] as? Bool ?? false, dim: row["dim"] as? Bool ?? false)
            }
            UserDefaults.standard.set(terminal.id, forKey: "zedlink.terminal.\(scope.joined(separator: "."))")
            terminalSnapshot = NativeTerminalSnapshot(terminal: decoded, content: result["content"] as? String ?? "", truncated: result["truncated"] as? Bool ?? false, styledRuns: Array(runs))
        } catch { issue = error.localizedDescription }
    }

    func resizeTerminal(columns: Int, rows: Int) async {
        guard state == .live, let client, let terminal = terminalSnapshot?.terminal,
              capabilities.contains("terminal.resize") else { return }
        let columns = min(max(columns, 24), 120), rows = min(max(rows, 8), 80)
        if let prior = requestedTerminalSize,
           prior.id == terminal.id, prior.columns == columns, prior.rows == rows { return }
        requestedTerminalSize = (terminal.id, columns, rows)
        let scope = operationScope
        do {
            _ = try await client.rpc("terminal.resize", params: [
                "instance_id": instanceID ?? "", "epoch": epoch ?? "", "terminal_id": terminal.id,
                "columns": columns, "rows": rows,
            ], requestID: UUID().uuidString)
            guard scope == operationScope, terminalSnapshot?.terminal.id == terminal.id else { return }
            try? await Task.sleep(for: .milliseconds(100))
            await loadTerminal(terminal, refresh: true)
        } catch let failure as GatewayFailure {
            if case .native(let code) = failure, code == "UNSUPPORTED_CAPABILITY" {
                capabilities.remove("terminal.resize")
            } else if scope == operationScope { issue = "Could not fit the terminal to this screen: " + failure.localizedDescription }
        } catch { if scope == operationScope { issue = "Could not fit the terminal to this screen: " + error.localizedDescription } }
    }

    @discardableResult
    func sendTerminalInput(_ input: String, appendReturn: Bool = true) async -> Bool {
        guard state == .live, let client, let terminal = terminalSnapshot?.terminal, !input.isEmpty,
              capabilities.contains("terminal.input") else { return false }
        let scope = operationScope
        do {
            var params: [String: Any] = [
                "instance_id": instanceID ?? "", "epoch": epoch ?? "", "terminal_id": terminal.id,
                "input": appendReturn ? input + "\n" : input,
            ]
            if let size = requestedTerminalSize, size.id == terminal.id {
                params["columns"] = size.columns; params["rows"] = size.rows
            }
            _ = try await client.rpc("terminal.input", params: params, requestID: UUID().uuidString)
            guard scope == operationScope, terminalSnapshot?.terminal.id == terminal.id else { return false }
            await loadTerminal(terminal, refresh: true)
            return true
        } catch {
            guard scope == operationScope else { return false }
            issue = "Terminal input failed. Check the terminal before retrying: " + error.localizedDescription
            return false
        }
    }

    func stopTerminalTask() async {
        guard let client, let terminal = terminalSnapshot?.terminal,
              capabilities.contains("task.stop") else { return }
        let scope = operationScope
        do {
            _ = try await client.rpc("task.stop", params: [
                "instance_id": instanceID ?? "", "epoch": epoch ?? "", "terminal_id": terminal.id,
            ], requestID: UUID().uuidString)
            try? await Task.sleep(for: .milliseconds(150))
            guard scope == operationScope else { return }
            await loadProjectContext()
            await loadTerminal(terminal, refresh: true)
        } catch { if scope == operationScope { issue = error.localizedDescription } }
    }

    private static func decodeTerminal(_ row: [String: Any]) -> NativeTerminal? {
        guard let id = row["terminal_id"] as? String else { return nil }
        let task = row["task"] as? [String: Any]
        let status = task?["status"] as? [String: Any]
        return NativeTerminal(id: id, title: row["title"] as? String ?? "Terminal",
                              workingDirectory: row["working_directory"] as? String,
                              taskLabel: task?["label"] as? String, taskState: status?["state"] as? String)
    }

    func loadDirectory(_ path: String) async {
        projectFolderEntries = nil; projectFolderTruncated = false
        guard capabilities.contains("project.directory"), let client, let thread = selectedThreadID else { return }
        let request = UUID(); directoryRequest = request
        let scope = (profile?.id, targetID, instanceID, epoch)
        do {
            let result = try await client.rpc("project.directory", params: ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": thread, "path": path])
            guard request == directoryRequest, thread == selectedThreadID, scope.0 == profile?.id,
                  scope.1 == targetID, scope.2 == instanceID, scope.3 == epoch else { return }
            guard result["directory"] as? String == path, let rows = result["entries"] as? [[String: Any]] else { throw GatewayFailure.invalidResponse }
            projectFolderEntries = rows.compactMap { row in
                guard let path = row["path"] as? String else { return nil }
                return NativeProjectFile(id: path, kind: row["kind"] as? String ?? "file", size: row["size"] as? Int)
            }
            projectFolderTruncated = result["truncated"] as? Bool ?? false
        } catch { if request == directoryRequest { issue = error.localizedDescription } }
    }

    func previewFile(_ path: String) async {
        guard let client, let threadID = selectedThreadID else { return }
        let request = UUID(); previewRequest = request
        let scope = (profile?.id, targetID, instanceID, epoch, threadID)
        previewTitle = path; previewContent = ""; previewReadable = false; previewLoading = true; previewTruncated = false
        do {
            let result = try await client.rpc("project.file", params: ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID, "path": path])
            guard request == previewRequest, scope.0 == profile?.id, scope.1 == targetID,
                  scope.2 == instanceID, scope.3 == epoch, scope.4 == selectedThreadID else { return }
            guard result["path"] as? String == path, let content = result["content"] as? String else {
                throw NSError(domain: "ZedLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid file preview"])
            }
            previewReadable = true; previewContent = content; previewTruncated = result["truncated"] as? Bool ?? false
            previewLoading = false
        } catch {
            guard request == previewRequest, scope.0 == profile?.id, scope.1 == targetID,
                  scope.2 == instanceID, scope.3 == epoch, scope.4 == selectedThreadID else { return }
            previewLoading = false; previewContent = "File unavailable: " + error.localizedDescription
        }
    }

    func loadDiff() async {
        guard state == .live, capabilities.contains("changes.diff"), let client, let threadID = selectedThreadID, let revision = changesRevision else { return }
        let scope = operationScope; let request = UUID(); diffRequest = request
        diffLoading = true; diffContent = ""; diffTruncated = false
        defer { if request == diffRequest { diffLoading = false } }
        do {
            for _ in 0..<40 {
                try Task.checkCancellation()
                guard scope == operationScope, request == diffRequest, revision == changesRevision else { return }
                let result = try await client.rpc("changes.diff", params: ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID, "revision": revision])
                guard scope == operationScope, request == diffRequest, revision == changesRevision else { return }
                guard result["revision"] as? String == revision else { throw GatewayFailure.invalidResponse }
                if result["outcome"] as? String == "ready", let content = result["diff"] as? String {
                    diffContent = content.isEmpty ? "No textual diff at this revision." : content
                    diffTruncated = result["truncated"] as? Bool ?? false
                    return
                }
                guard result["outcome"] as? String == "loading" else { throw GatewayFailure.invalidResponse }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw GatewayFailure.native("Diff is still loading. Refresh again to check its status.")
        } catch is CancellationError {} catch { if scope == operationScope, request == diffRequest { issue = error.localizedDescription } }
    }

    func searchProject(_ query: String) async throws -> (matches: [ProjectSearchMatch], truncated: Bool) {
        guard state == .live, capabilities.contains("project.search"), let client, let thread = selectedThreadID else { throw GatewayFailure.native("Project search is unavailable.") }
        let scope = operationScope; let request = UUID(); searchRequest = request
        for _ in 0..<40 {
            try Task.checkCancellation()
            let result = try await client.rpc("project.search", params: ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": thread, "query": query, "case_sensitive": false])
            guard scope == operationScope, searchRequest == request else { throw CancellationError() }
            if result["outcome"] as? String == "ready" {
                let matches = (result["matches"] as? [[String: Any]] ?? []).compactMap { row -> ProjectSearchMatch? in
                    guard let path = row["path"] as? String, let line = row["line"] as? Int, let column = row["column"] as? Int, let preview = row["preview"] as? String else { return nil }
                    return ProjectSearchMatch(path: path, line: line, column: column, preview: preview)
                }
                return (matches, result["truncated"] as? Bool ?? false)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GatewayFailure.native("Project search timed out. Try again.")
    }

    func mutateChange(_ change: NativeChange) async {
        guard state == .live, let client, let threadID = selectedThreadID, let revision = changesRevision else { return }
        let method = change.staging == "staged" ? "changes.unstage" : "changes.stage"
        let requestID = UUID().uuidString
        let scope = operationScope
        do {
            _ = try await client.rpc(method, params: ["instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": threadID,
                "revision": revision, "paths": [change.id]], requestID: requestID)
            guard scope == operationScope else { return }
            await loadProjectContext()
        } catch { if scope == operationScope { issue = error.localizedDescription } }
    }

    func loadEarlierHistory() async {
        guard capabilities.contains("thread.history"), let client, let old = snapshot,
              old.threadID == selectedThreadID, old.entryStartIndex > 0 else { return }
        let scope = operationScope
        do {
            let result = try await client.rpc("thread.history", params: [
                "thread_id": old.threadID, "before_entry_index": old.entryStartIndex
            ])
            guard scope == operationScope else { return }
            try checkIdentity(result)
            guard selectedThreadID == old.threadID, let current = snapshot,
                  current.instanceID == old.instanceID, current.epoch == old.epoch,
                  current.threadID == old.threadID,
                  current.entryStartIndex == old.entryStartIndex,
                  result["thread_id"] as? String == old.threadID,
                  result["entry_end_index"] as? Int == old.entryStartIndex,
                  let start = result["entry_start_index"] as? Int,
                  let entries = result["entries_markdown"] as? [String] else {
                throw GatewayFailure.invalidResponse
            }
            let pageMeta = NativeEntryMeta.page(result["entries_meta"], count: entries.count)
            let currentMeta = current.entryMeta.count == current.entries.count ? current.entryMeta : Array(repeating: nil, count: current.entries.count)
            snapshot = ThreadSnapshot(threadID: current.threadID, title: current.title, status: current.status,
                                      currentTurnID: current.currentTurnID,
                                      instanceID: current.instanceID, epoch: current.epoch,
                                      lastSequence: current.lastSequence,
                                      entries: entries + current.entries,
                                      entryStartIndex: start,
                                      totalEntries: max(current.totalEntries, result["total_entries"] as? Int ?? 0),
                                      hasOlderEntries: start > 0,
                                      activityEntries: current.activityEntries,
                                      truncated: start > 0, activityTruncated: current.activityTruncated,
                                      pendingApprovals: current.pendingApprovals, rewindPoints: current.rewindPoints,
                                      subagents: current.subagents, agentError: current.agentError,
                                      entryMeta: pageMeta + currentMeta)
            scheduleCacheSave()
        } catch {
            if scope == operationScope { issue = error.localizedDescription }
        }
    }

    @Published var localCommandConfirmation: NativeCommand?
    @Published private(set) var localExposureStopped = false
    private var localCommandScope: [String] = []
    private var localCommandText = ""
    private var lastCommandsRefresh = Date.distantPast

    func refreshCommands() async {
        guard let id = selectedThreadID else { return }
        let scope = operationScope
        do { try await loadCommands(id) } catch { if scope == operationScope { issue = error.localizedDescription } }
    }

    private func loadCommands(_ id: String) async throws {
        guard capabilities.contains("thread.commands"), let client else { return }
        let scope = operationScope
        let result = try await client.rpc("thread.commands", params: [
            "instance_id": instanceID ?? "", "epoch": epoch ?? "", "thread_id": id
        ])
        guard scope == operationScope, selectedThreadID == id, result["thread_id"] as? String == id,
              let rows = result["commands"] as? [[String: Any]] else { return }
        commands = rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return NativeCommand(name: name,
                                 description: row["description"] as? String ?? "Zed Agent command",
                                 category: row["category"] as? String ?? "agent",
                                 requiresArgument: row["requires_argument"] as? Bool ?? false, inputHint: row["input_hint"] as? String,
                                 execution: row["execution"] as? String ?? "prompt", confirmation: row["confirmation"] as? String, warning: row["warning"] as? String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        lastCommandsRefresh = Date()
    }

    private func checkIdentity(_ result: [String: Any]) throws {
        guard result["instance_id"] as? String == instanceID,
              result["epoch"] as? String == epoch else { throw GatewayFailure.native("Zed restarted. Reconnect before sending.") }
    }

    private func pollLoop(_ current: UUID) async {
        var consecutiveFailures = 0
        while !Task.isCancelled && current == generation {
            do {
                if let id = selectedThreadID, let client {
                    let result = try await client.rpc("thread.events", params: [
                        "thread_id": id, "after_sequence": snapshot?.lastSequence ?? 0
                    ])
                    guard current == generation, selectedThreadID == id else { continue }
                    try checkIdentity(result)
                    guard result["thread_id"] as? String == id else { throw GatewayFailure.invalidResponse }
                    if let events = result["events"] as? [[String: Any]], !events.isEmpty {
                        notifyTurnEvents(events, threadID: id)
                        applyEventActivity(events)
                        if events.contains(where: { $0["kind"] as? String == "entry.removed" }) {
                            snapshot = nil
                        }
                        try await loadSnapshot(id, refreshAuxiliary: false)
                    } else if snapshot == nil || snapshot?.isBusy == true || (snapshot?.subagents.isEmpty == false && Date().timeIntervalSince(lastChildSnapshot) > 3) {
                        try await loadSnapshot(id, refreshAuxiliary: false)
                    } else if let sequence = result["last_sequence"] as? Int,
                              var old = snapshot, sequence > old.lastSequence {
                        old = ThreadSnapshot(threadID: old.threadID, title: old.title, status: old.status,
                                             currentTurnID: old.currentTurnID,
                                             instanceID: old.instanceID, epoch: old.epoch,
                                             lastSequence: sequence, entries: old.entries,
                                             entryStartIndex: old.entryStartIndex,
                                             totalEntries: old.totalEntries,
                                             hasOlderEntries: old.hasOlderEntries,
                                             activityEntries: old.activityEntries,
                                             truncated: old.truncated, activityTruncated: old.activityTruncated,
                                             pendingApprovals: old.pendingApprovals, rewindPoints: old.rewindPoints,
                                             subagents: old.subagents, agentError: old.agentError,
                                             entryMeta: old.entryMeta)
                        snapshot = old
                    }
                } else {
                    try await loadThreads()
                }
                if let id = selectedThreadID, Date().timeIntervalSince(lastAuxiliaryRefresh) >= 2 {
                    do {
                        try await loadAuxiliaryState(id)
                        lastAuxiliaryRefresh = Date()
                        controlsIssue = ""
                    } catch is CancellationError { break }
                    catch { controlsIssue = error.localizedDescription }
                }
                if pending != nil { await reconcilePending() }
                if current == generation {
                    consecutiveFailures = 0
                    state = .live
                    if issue != threadExposureIssue { issue = "" }
                }
            } catch {
                if case GatewayFailure.native("RESYNC_REQUIRED") = error, let id = selectedThreadID {
                    snapshot = nil
                    do { try await loadSnapshot(id); state = .live }
                    catch { state = .stale; issue = error.localizedDescription }
                } else if case GatewayFailure.native("THREAD_NOT_EXPOSED") = error {
                    guard current == generation else { break }
                    selectedThreadID = nil
                    snapshot = nil
                    lastSnapshotAt = nil
                    controlsIssue = ""
                    liveActivity = .ready
                    commands = []
                    do {
                        try await loadThreads()
                        guard current == generation else { break }
                        state = .live
                        issue = threadExposureIssue
                    } catch {
                        guard current == generation else { break }
                        state = .reconnecting
                        issue = error.localizedDescription
                    }
                } else if current == generation && !isCancelledRequest(error) {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 2 {
                        state = .reconnecting
                        issue = error.localizedDescription
                    }
                }
            }
            do { try await Task.sleep(for: .seconds(state == .live ? (eventStreamLive ? 10 : 1) : 3)) }
            catch { break }
        }
    }

    func cancelCurrentTurn() async {
        guard canCancel, let client, let instanceID, let epoch,
              let threadID = selectedThreadID, let turnID = snapshot?.currentTurnID else { return }
        do {
            let result = try await client.rpc("thread.cancel", params: [
                "instance_id": instanceID, "epoch": epoch,
                "thread_id": threadID, "turn_id": turnID
            ])
            guard result["outcome"] as? String == "requested",
                  result["turn_id"] as? Int == turnID else { throw GatewayFailure.invalidResponse }
            delivery = "Stop requested for this desktop Zed turn. Completed tool effects remain."
            try await loadSnapshot(threadID)
        } catch {
            issue = error.localizedDescription
            try? await loadSnapshot(threadID)
        }
    }

    func handleApprovalNotification(_ data: [String: String], action: String) async {
        // Foreground refresh can overlap an alert opened during connection restoration.
        for _ in 0..<80 {
            guard state == .connecting else { break }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
        }
        guard state != .connecting else { issue = "Connection is still restoring. Open the session to review current requests."; return }
        if state != .live { await refresh() }
        guard state == .live else { issue = "Reconnect before reviewing this notification."; return }
        if data["type"] == "push_test" { return }
        if data["type"] == "push" {
            guard data["gateway"]?.caseInsensitiveCompare(profile?.gatewayID ?? "") == .orderedSame,
                  data["target"] == targetID,
                  let thread = data["thread"], threads.contains(where: { $0.id == thread }) else {
                issue = "Choose the notification's paired workspace, then refresh to review its current state."
                notificationNeedsWorkspace = true
                return
            }
            if notificationNeedsWorkspace { clearIssue() }
            notificationThreadID = thread
            return
        }
        guard data["gateway"] == profile?.gatewayID, data["target"] == targetID,
              data["instance"] == instanceID, data["epoch"] == epoch,
              let thread = data["thread"], threads.contains(where: { $0.id == thread }) else {
            issue = "This notification belongs to an older or different connection. Open the session to review current requests."
            notificationNeedsWorkspace = true
            return
        }
        if notificationNeedsWorkspace { clearIssue() }
        await select(thread)
        guard state == .live, issue.isEmpty, data["gateway"] == profile?.gatewayID, data["target"] == targetID,
              data["instance"] == instanceID, data["epoch"] == epoch, thread == selectedThreadID else { return }
        notificationThreadID = thread
        guard action == "approve" || action == "deny" else { return }
        guard let approval = snapshot?.pendingApprovals.first(where: {
            $0.id == data["approval"] && String($0.turnID ?? -1) == data["turn"] && ($0.subagentID ?? "") == data["child"]
        }), approval.authorizationKind == "permission_grant", !approval.detailsTruncated,
        let decision = approval.decisions.first(where: {
            $0.optionID == data[action] && $0.optionKind == (action == "approve" ? "allow_once" : "reject_once")
                && $0.choiceIndex == nil && $0.selectedPatternIndices.isEmpty && $0.action == nil
        }) else {
            issue = "This approval changed or was already resolved. Review the current session."
            return
        }
        await respond(to: approval, with: decision)
    }

    func respond(to approval: NativeApproval, with decision: NativeApprovalDecision) async {
        guard state == .live, capabilities.contains("approval.respond"), !resolvingApprovals.contains(approval.id), let client, let instanceID, let epoch,
              let threadID = selectedThreadID, let turnID = approval.turnID,
              snapshot?.pendingApprovals.contains(where: { $0.id == approval.id }) == true else { return }
        let scope = operationScope
        resolvingApprovals.insert(approval.id)
        defer { resolvingApprovals.remove(approval.id) }
        var params: [String: Any] = [
            "instance_id": instanceID, "epoch": epoch, "thread_id": threadID,
            "turn_id": turnID, "approval_id": approval.id, "option_id": decision.optionID
        ]
        if let choiceIndex = decision.choiceIndex { params["choice_index"] = choiceIndex }
        if !decision.selectedPatternIndices.isEmpty {
            params["selected_pattern_indices"] = decision.selectedPatternIndices
        }
        if let subagentID = approval.subagentID { params["subagent_id"] = subagentID }
        do {
            let result = try await client.rpc("approval.respond", params: params)
            guard scope == operationScope else { return }
            guard result["outcome"] as? String == "resolved" else { throw GatewayFailure.invalidResponse }
            delivery = "Sent “\(decision.displayLabel)” to desktop Zed."
            try await loadSnapshot(threadID)
        } catch {
            guard scope == operationScope else { return }
            issue = error.localizedDescription
            try? await loadSnapshot(threadID)
        }
    }

    func confirmLocalCommand() async {
        guard localCommandConfirmation != nil, localCommandScope == operationScope, draft.trimmingCharacters(in: .whitespacesAndNewlines) == localCommandText else { localCommandConfirmation = nil; return }
        localCommandConfirmation = nil
        await send(localConfirmed: true)
    }

    func send(localConfirmed: Bool = false) async {
        guard canSend, let client, let profile, let instanceID, let epoch,
              let threadID = selectedThreadID else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty || !contextPaths.isEmpty else { return }
        if let command = commands.first(where: { "/" + $0.name == text && $0.execution == "local" }) {
            guard attachments.isEmpty, contextPaths.isEmpty else { issue = "Run local commands without attachments."; return }
            if !localConfirmed { localCommandScope = operationScope; localCommandText = text; localCommandConfirmation = command; return }
        }
        guard attachments.count + contextPaths.count <= 8 else { issue = "A prompt can include at most eight attachments."; return }
        guard attachments.isEmpty || supportsImages != false else { issue = "The selected model does not support images. Remove the image or select a supported model."; return }
        if !attachments.isEmpty || !contextPaths.isEmpty {
            let command = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if commands.contains(where: { "/" + $0.name == command && $0.category == "native" }) {
                issue = "Send attachments with a normal prompt; run the native slash command separately."; return
            }
        }
        pending = PendingSend(id: UUID().uuidString, instanceID: instanceID,
                              epoch: epoch, threadID: threadID, text: text, contextPaths: Array(contextPaths), attachments: attachments)
        pending?.localConfirmed = localConfirmed ? true : nil
        persistPending(for: profile)
        delivery = "Sending to native Zed…"
        await retryPending()
    }

    func retryPending() async {
        guard state == .live, let client, let pending, pending.text != nil, pending.threadID == selectedThreadID,
              pending.instanceID == instanceID, pending.epoch == epoch else { return }
        let scope = operationScope
        do {
            let result = try await client.rpc("thread.send", params: pending.submissionParams, requestID: pending.id)
            guard scope == operationScope, self.pending?.id == pending.id else { return }
            let outcome = result["outcome"] as? String ?? "received"
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == pending.text { draft = "" }
            contextPaths.subtract(pending.contextPaths)
            let sentImages = Set(pending.attachments.map(\.id))
            attachments.removeAll { sentImages.contains($0.id) }
            settlePending()
            delivery = outcome == "queued"
                ? "Queued in desktop Zed. Native execution is being observed."
                : "Received by desktop Zed. Watching the native conversation for progress."
            if outcome == "local_completed" || outcome == "desktop_review_required" {
                delivery = outcome == "desktop_review_required" ? "Complete the feedback form in desktop Zed." : "Desktop action completed."
                if pending.text == "/remote-control" { localExposureStopped = true; selectedThreadID = nil; try await loadThreads(); return }
            }
            try await loadSnapshot(pending.threadID)
        } catch {
            guard scope == operationScope, self.pending?.id == pending.id else { return }
            delivery = "Delivery unknown: \(error.localizedDescription) No new request ID was sent."
        }
    }

    func reconcilePending() async {
        guard let client, let pending else { return }
        guard pending.instanceID == instanceID, pending.epoch == epoch else {
            delivery = "Zed restarted. Delivery remains unknown; inspect the desktop thread."
            return
        }
        do {
            let result = try await client.rpc("request.status", params: [
                "instance_id": pending.instanceID, "epoch": pending.epoch,
                "original_request_id": pending.id
            ])
            if result["known"] as? Bool == true {
                delivery = "Zed knows this request (\(result["outcome"] as? String ?? "unknown")); native acceptance remains provisional."
            } else {
                delivery = "Request status is unknown. It was not resent."
            }
        } catch { delivery = "Request status unavailable: \(error.localizedDescription)" }
    }

    func clearPending() {
        pending = nil
        if let profile { UserDefaults.standard.removeObject(forKey: pendingKey(profile)) }
        delivery = "Uncertain delivery cleared locally. Check desktop Zed before sending similar text."
    }

    func insertCommand(_ command: NativeCommand) {
        draft = "/\(command.name)\(command.requiresArgument ? " " : "")"
    }

    func prepareSubagentTask() {
        draft = "Use the native spawn_agent tool to delegate the following task to a child Zed Agent. Keep the child scoped to this project and return its result in this conversation:\n\nTask: "
    }

    private func settlePending() {
        pending = nil
        if let profile { UserDefaults.standard.removeObject(forKey: pendingKey(profile)) }
    }

    private static func jsonText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let value = value as? String { return value }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(data: data, encoding: .utf8)
    }

    private func targetKey(_ profile: ConnectionProfile) -> String { "zedlink.target.\(profile.id)" }

    private func selectedThreadKey(_ profile: ConnectionProfile, targetID: String) -> String {
        "zedlink.selected.\(profile.gatewayID.lowercased()).\(targetID)"
    }

    private func scheduleCacheSave() {
        guard cacheTask == nil else { return }
        cacheTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            await self.persistConversation()
            self.cacheTask = nil
        }
    }

    func persistConversation() async {
        guard let profile, let targetID, let snapshot,
              let cached = CachedConversation(gatewayID: profile.gatewayID, targetID: targetID, snapshot: snapshot) else { return }
        let scope = operationScope
        await ConversationCache.shared.save(cached)
        let saved = await ConversationCache.shared.list(gatewayID: profile.gatewayID, targetID: targetID)
        guard scope == operationScope else { return }
        cachedConversations = saved
    }

    private func pendingKey(_ profile: ConnectionProfile) -> String {
        "zedlink.pending.\(profile.id).\(targetID ?? "default")"
    }

    private func draftKey(profileID: UUID, targetID: String?, threadID: String) -> String {
        "zedlink.draft.\(profileID.uuidString).\(targetID ?? "default").\(threadID)"
    }

    private func persistPending(for profile: ConnectionProfile) {
        if let pending, let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: pendingKey(profile))
        }
    }

    private func restorePending(for profile: ConnectionProfile) {
        if let data = UserDefaults.standard.data(forKey: pendingKey(profile)) {
            pending = try? JSONDecoder().decode(PendingSend.self, from: data)
            if pending != nil { delivery = "Previous send has uncertain delivery. Check its status before another send." }
        }
    }
}
