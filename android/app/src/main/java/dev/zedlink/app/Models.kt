package dev.zedlink.app

data class ConnectionProfile(
    val name: String,
    val endpoint: String,
    val gatewayId: String,
    val id: String = java.util.UUID.randomUUID().toString(),
    val route: String = "Private HTTPS",
)

data class ZedTarget(val id: String, val label: String, val available: Boolean)
data class AgentOption(val id: String, val name: String, val kind: String)

data class NativeThread(
    val id: String,
    val title: String,
    val status: String,
    val currentTurnId: Int?,
    val agentName: String = "Zed Agent", val retrying: Boolean = false, val failed: Boolean = false,
    val approvalCount: Int? = null, val inputCount: Int? = null,
)

enum class SessionActivity(val label: String) {
    APPROVAL("Approval needed"), INPUT("Input needed"), FAILED("Request failed"),
    RETRYING("Retrying"), GENERATING("Generating"), READY("Ready"), UNKNOWN("Unknown");
    val attention get() = this in listOf(APPROVAL, INPUT, FAILED)
    val running get() = this in listOf(RETRYING, GENERATING)
    val group get() = if (attention) "Needs attention" else if (running) "Running" else "Ready & other"
    companion object {
        fun from(thread: NativeThread) = when {
            (thread.approvalCount ?: 0) > 0 -> APPROVAL
            (thread.inputCount ?: 0) > 0 -> INPUT
            thread.retrying -> RETRYING
            thread.status == "Idle" && thread.failed -> FAILED
            thread.status == "Generating" -> GENERATING
            thread.status == "Idle" -> READY
            else -> UNKNOWN
        }
    }
}

data class NativeCommand(
    val name: String,
    val description: String,
    val category: String,
    val requiresArgument: Boolean,
    val inputHint: String? = null, val execution: String = "prompt",
    val confirmation: String? = null, val warning: String? = null,
)

data class NativeApproval(
    val id: String,
    val turnId: Int?,
    val toolName: String,
    val display: String,
    val rawInput: String?,
    val detailsTruncated: Boolean,
    val subagentId: String?,
    val authorizationKind: String,
    val decisions: List<NativeApprovalDecision>,
)

data class NativeApprovalDecision(
    val optionId: String,
    val label: String,
    val optionKind: String,
    val choiceIndex: Int?,
    val selectedPatternIndices: List<Int>,
    val action: String?,
) {
    val isRejecting: Boolean get() = optionKind.startsWith("reject")
    val displayLabel: String get() = action?.let { "${if (it == "allow") "Allow" else "Deny"} · $label" } ?: label
}

data class NativeElicitationField(
    val id: String, val title: String, val type: String, val required: Boolean, val choices: List<String>,
    val defaultValue: String? = null, val defaultArray: List<String>? = null,
    val minimum: Double? = null, val maximum: Double? = null,
    val minLength: Int? = null, val maxLength: Int? = null,
)
data class NativeElicitation(
    val id: String, val message: String, val url: String?, val fields: List<NativeElicitationField>,
)
data class NativeQueueEntry(val id: Int, val preview: String, val steer: Boolean)
data class NativeEditReview(val changedFiles: Int, val linesAdded: Int, val linesRemoved: Int)
data class NativeModelOption(val id: String, val modelId: String, val providerId: String, val name: String)
data class NativeAgentProfile(val id: String, val name: String)
data class NativeThreadSettings(
    val modelId: String?, val providerId: String?, val models: List<NativeModelOption>,
    val usedTokens: Int?, val maxTokens: Int?,
    val profileId: String? = null, val profiles: List<NativeAgentProfile> = emptyList(),
    val thinkingEnabled: Boolean? = null, val thinkingSupported: Boolean = false, val thinkingCanDisable: Boolean = false,
)
data class NativeRewindPoint(val id: String, val entryIndex: Int, val entriesRemoved: Int)
data class NativeSubagent(val id: String, val title: String, val status: String, val currentTurnId: Int?, val entries: List<String>,
    val entryStartIndex: Int = 0, val totalEntries: Int = 0, val entriesTruncated: Boolean = false) {
    val isActive: Boolean get() = currentTurnId != null || status.lowercase() in listOf("pending", "running", "inprogress", "in progress", "waiting", "generating")
}
data class NativeProjectFile(val id: String, val kind: String, val size: Int?)
data class NativeChange(val id: String, val status: String, val staging: String)
data class NativeEntryMeta(val kind: String, val callId: String?, val elicitationId: String?) {
    companion object {
        fun page(value: org.json.JSONArray?, count: Int): List<NativeEntryMeta?> {
            if (value == null || value.length() != count) return List(count) { null }
            return (0 until count).map { index ->
                value.optJSONObject(index)?.let { row ->
                    NativeEntryMeta(row.optString("kind"), row.optString("call_id").takeIf(String::isNotBlank),
                        row.optString("elicitation_id").takeIf(String::isNotBlank))
                }
            }
        }
    }
}
data class PromptImageAttachment(val id: String = java.util.UUID.randomUUID().toString(), val name: String, val mimeType: String, val data: ByteArray)

data class NativeAgentError(val kind: String, val title: String, val message: String, val retrying: Boolean) {
    companion object {
        fun decode(snapshot: org.json.JSONObject): NativeAgentError? {
            val error = snapshot.optJSONObject("agent_error")
            if (error != null && error.opt("title") is String && error.opt("message") is String) {
                return NativeAgentError(error.optString("kind", "agent_error"), error.getString("title"),
                    error.getString("message"), error.optBoolean("retrying"))
            }
            return if (snapshot.optBoolean("had_error")) NativeAgentError("agent_error", "Agent request failed",
                "The last native Zed Agent turn failed. Open desktop Zed for additional details.", false) else null
        }
    }
}

data class ThreadSnapshot(
    val threadId: String,
    val title: String,
    val status: String,
    val currentTurnId: Int?,
    val instanceId: String,
    val epoch: String,
    val lastSequence: Int,
    val entries: List<String>,
    val entryStartIndex: Int,
    val totalEntries: Int,
    val hasOlderEntries: Boolean,
    val activityEntries: List<String>,
    val truncated: Boolean,
    val activityTruncated: Boolean,
    val approvals: List<NativeApproval>,
    val rewindPoints: List<NativeRewindPoint>,
    val subagents: List<NativeSubagent>,
    val agentError: NativeAgentError? = null,
    val entryMeta: List<NativeEntryMeta?> = emptyList(),
) { val isBusy: Boolean get() = status == "Generating" || currentTurnId != null }

enum class EntryKind { USER, ASSISTANT, TOOL, PLAN, APPROVAL, CONTEXT, OTHER }

data class NativeTerminal(
    val id: String,
    val title: String,
    val workingDirectory: String?,
    val taskLabel: String?,
    val taskState: String?,
)
data class NativeTerminalRun(val text: String, val foreground: String, val background: String, val bold: Boolean, val italic: Boolean, val underline: Boolean, val dim: Boolean)
data class NativeTerminalSnapshot(val terminal: NativeTerminal, val content: String, val truncated: Boolean, val styledRuns: List<NativeTerminalRun> = emptyList())
data class NativeConfiguredTask(val id: String, val label: String, val source: String)
data class NativeDebugScenario(val id: String, val label: String, val adapter: String, val source: String)
data class NativeDebuggerThread(val id: Long, val name: String, val status: String)
data class NativeDebuggerSession(
    val id: String,
    val label: String,
    val adapter: String,
    val terminated: Boolean,
    val canRestart: Boolean,
    val canStepBack: Boolean,
    val threads: List<NativeDebuggerThread>,
)

data class NativeEntry(
    val kind: EntryKind,
    val label: String,
    val body: String,
    val reasoning: List<String>,
    val toolName: String? = null,
    val toolStatus: String? = null,
) {
    companion object {
        private val prefixes = listOf(
            Triple("## User\n\n", EntryKind.USER, "You"),
            Triple("## User (checkpoint)\n\n", EntryKind.USER, "You · checkpoint"),
            Triple("## Assistant\n\n", EntryKind.ASSISTANT, "Zed Agent"),
            Triple("## Input Requested\n\n", EntryKind.APPROVAL, "Input requested"),
            Triple("## Plan\n\n", EntryKind.PLAN, "Plan"),
            Triple("## Context Compaction", EntryKind.CONTEXT, "Context"),
        )

        fun parse(markdown: String): NativeEntry {
            val match = prefixes.firstOrNull { markdown.startsWith(it.first) }
            if (match != null) {
                val payload = markdown.drop(match.first.length)
                return NativeEntry(match.second, match.third, removeReasoning(payload).trim(), extractReasoning(payload))
            }
            val reasoning = extractReasoning(markdown)
            val cleaned = removeReasoning(markdown).trim()
            if (cleaned.startsWith("**Tool Call: ")) {
                val first = cleaned.lineSequence().firstOrNull().orEmpty()
                val name = first.removePrefix("**Tool Call: ").removeSuffix("**")
                val status = cleaned.lineSequence().firstOrNull { it.startsWith("Status: ") }?.removePrefix("Status: ")
                return NativeEntry(EntryKind.TOOL, "Zed tool", cleaned, reasoning, name, status)
            }
            return NativeEntry(EntryKind.OTHER, "Native entry", cleaned, reasoning)
        }

        private fun extractReasoning(markdown: String): List<String> {
            val values = mutableListOf<String>()
            var cursor = 0
            while (true) {
                val start = markdown.indexOf("<thinking>\n", cursor)
                if (start < 0) break
                val contentStart = start + "<thinking>\n".length
                val end = markdown.indexOf("\n</thinking>", contentStart)
                val value = if (end < 0) markdown.substring(contentStart).trim() else markdown.substring(contentStart, end).trim()
                if (value.isNotEmpty()) values += value
                if (end < 0) break
                cursor = end + "\n</thinking>".length
            }
            return values
        }

        private fun removeReasoning(markdown: String): String {
            var result = markdown
            while (true) {
                val start = result.indexOf("<thinking>\n")
                if (start < 0) break
                val end = result.indexOf("\n</thinking>", start + 11)
                result = if (end < 0) result.substring(0, start)
                else result.removeRange(start, end + "\n</thinking>".length)
            }
            return result
        }
    }
}
