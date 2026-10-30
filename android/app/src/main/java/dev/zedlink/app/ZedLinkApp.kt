package dev.zedlink.app

import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.activity.compose.BackHandler
import androidx.compose.ui.platform.LocalContext
import androidx.activity.compose.LocalActivity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip

private enum class Tab { Sessions, Connections, Settings }

@Composable
fun ZedLinkApp(model: ZedLinkViewModel) {
    val state = model.state
    var tab by rememberSaveable { mutableStateOf(Tab.Sessions) }
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    fun selectTab(next: Tab) {
        focus.clearFocus()
        keyboard?.hide()
        tab = next
    }
    LaunchedEffect(model.pairingImportRevision) { if (model.pairingImportRevision > 0) selectTab(Tab.Connections) }
    BackHandler(state.selectedThreadId == null && tab != Tab.Sessions) { selectTab(Tab.Sessions) }
    ZedLinkTheme(state.appearance) {
        Surface(modifier = Modifier.fillMaxSize(), color = Black) {
            BoxWithConstraints(Modifier.fillMaxSize().statusBarsPadding()) {
                val wide = maxWidth >= 600.dp
                val destination: @Composable () -> Unit = {
                    when {
                        state.selectedThreadId != null -> ConversationScreen(state, model)
                        tab == Tab.Sessions -> SessionsScreen(state, model) { selectTab(Tab.Connections) }
                        tab == Tab.Connections -> ConnectionsScreen(state, model)
                        else -> SettingsScreen(state, model) { selectTab(Tab.Connections) }
                    }
                }
                if (state.selectedThreadId != null) destination()
                else if (wide) Row(Modifier.fillMaxSize()) {
                    PrimaryRail(tab, ::selectTab)
                    Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.TopCenter) {
                        Box(Modifier.widthIn(max = 900.dp).fillMaxSize()) { destination() }
                    }
                } else Column(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f)) { destination() }
                    PrimaryBar(tab, ::selectTab)
                }
            }
        }
    }
}

@Composable
private fun PrimaryBar(selected: Tab, onSelect: (Tab) -> Unit) {
    HorizontalDivider(color = Line)
    NavigationBar(containerColor = Surface, tonalElevation = 0.dp) {
        listOf(Triple(Tab.Sessions, Icons.Default.Forum, "Sessions"), Triple(Tab.Connections, Icons.Default.Language, "Connections"),
            Triple(Tab.Settings, Icons.Default.Settings, "Settings")).forEach { (tab, icon, label) ->
            NavigationBarItem(selected = selected == tab, onClick = { onSelect(tab) },
                icon = { Icon(icon, contentDescription = null) }, label = { Text(label) })
        }
    }
}

@Composable
private fun PrimaryRail(selected: Tab, onSelect: (Tab) -> Unit) {
    NavigationRail(Modifier.navigationBarsPadding(), containerColor = Surface, windowInsets = WindowInsets(0, 0, 0, 0)) {
        Spacer(Modifier.height(16.dp))
        listOf(Triple(Tab.Sessions, Icons.Default.Forum, "Sessions"), Triple(Tab.Connections, Icons.Default.Language, "Connections"),
            Triple(Tab.Settings, Icons.Default.Settings, "Settings")).forEach { (tab, icon, label) ->
            NavigationRailItem(selected = selected == tab, onClick = { onSelect(tab) },
                icon = { Icon(icon, contentDescription = null) }, label = { Text(label) })
        }
    }
}

@Composable
private fun SessionsScreen(state: AppState, model: ZedLinkViewModel, showConnections: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf("All") }
    var showingNew by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    val threads = state.threads.filter {
        val activity = SessionActivity.from(it)
        ("${it.title} ${it.agentName} ${it.id}".contains(query, true)) &&
            (filter == "All" || filter == "Needs attention" && activity.attention || filter == "Running" && activity.running || filter == "Pinned" && it.id in state.pinnedThreads)
    }.sortedWith(compareByDescending<NativeThread> { it.id in state.pinnedThreads }.thenBy { it.title.lowercase() })
    val recentThreads = if (query.isBlank() && filter == "All") state.recentThreadIds.mapNotNull { id -> threads.firstOrNull { it.id == id } }.take(3) else emptyList()
    val recentIds = recentThreads.map { it.id }.toSet()
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Header("Sessions", "") {
                Row {
                    IconButton(onClick = { showingNew = true }, enabled = state.live && "thread.create" in state.capabilities) { Icon(Icons.Default.Add, "Create Agent session", tint = Ink) }
                    IconButton(onClick = model::refresh, enabled = state.profile != null) { Icon(Icons.Default.Refresh, "Refresh", tint = Ink) }
                }
            }
            if (state.profile == null) TextButton(onClick = showConnections) { Text("Choose a connection") } else ConnectionStrip(state, model)
            if (state.issue.isNotBlank()) Notice(state.issue)
            OutlinedTextField(query, { query = it }, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                placeholder = { Text("Search sessions or agents") }, leadingIcon = { Icon(Icons.Default.Search, null) },
                singleLine = true, shape = RoundedCornerShape(16.dp))
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("All", "Needs attention", "Running", "Pinned").forEach { label ->
                    FilterChip(selected = filter == label, onClick = { filter = label; focusManager.clearFocus() },
                        label = { Text(label) }, shape = RoundedCornerShape(12.dp))
                }
            }
            Spacer(Modifier.height(6.dp))
            if (state.live && "thread.create" in state.capabilities) {
                OutlinedButton(onClick = { showingNew = true }, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
                    Icon(Icons.Default.Add, null); Spacer(Modifier.width(8.dp)); Text("New Agent session")
                }
            }
        }
        if (recentThreads.isNotEmpty()) {
            item { SectionHeading("RECENTLY OPENED", recentThreads.size.toString()) }
            items(recentThreads, key = { "recent:${it.id}" }) { thread ->
                ThreadRow(thread, state.live, thread.id in state.pinnedThreads, thread.id in state.updatedThreads, { model.toggleSessionPin(thread.id) }) {
                    focusManager.clearFocus(force = true); model.selectThread(thread.id)
                }
            }
        }
        if (threads.isEmpty()) item {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(if (state.profile == null) "Choose a connection" else if (state.threads.isEmpty()) { if (state.live) "No exposed sessions" else "Sessions unavailable" } else "No matching sessions", fontSize = 19.sp)
                Text(if (state.threads.isEmpty()) "Expose a conversation with /remote-control in desktop Zed, or create a session using +." else "Try another search or filter.", color = Muted)
            }
        }
        listOf("Needs attention", "Running", "Ready & other").forEach { group ->
            val rows = threads.filter { SessionActivity.from(it).group == group && it.id !in recentIds }
            if (rows.isNotEmpty()) {
                item { SectionHeading(group.uppercase(), rows.size.toString()) }
                items(rows, key = { it.id }) { thread ->
                    ThreadRow(thread, state.live, thread.id in state.pinnedThreads, thread.id in state.updatedThreads, { model.toggleSessionPin(thread.id) }) {
                        focusManager.clearFocus(force = true); model.selectThread(thread.id)
                    }
                }
            }
        }
    }
    if (showingNew) NewSessionDialog(state, model) { showingNew = false }
}

@Composable
private fun NewSessionDialog(state: AppState, model: ZedLinkViewModel, dismiss: () -> Unit) {
    var title by remember { mutableStateOf("") }
    var agentId by remember { mutableStateOf("zed-agent") }
    var expanded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { model.loadCreateOptions() }
    LaunchedEffect(state.createAgents) {
        if (state.createAgents.none { it.id == agentId }) agentId = state.createAgents.firstOrNull()?.id ?: "zed-agent"
    }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("New Agent session") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(title, { title = it }, label = { Text("Optional title") }, singleLine = true)
                Box {
                    OutlinedButton(onClick = { expanded = true }, Modifier.fillMaxWidth()) {
                        Text(state.createAgents.firstOrNull { it.id == agentId }?.name ?: "Choose agent")
                    }
                    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                        state.createAgents.forEach { agent ->
                            DropdownMenuItem(text = { Text("${agent.name}${if (agent.kind == "external_acp") " · ACP" else ""}") },
                                onClick = { agentId = agent.id; expanded = false })
                        }
                    }
                }
                Text("The agent, model, tools, permissions, and project remain configured in desktop Zed.", color = Muted, fontSize = 12.sp)
            }
        },
        confirmButton = {
            TextButton(enabled = state.createAgents.isNotEmpty() && !state.creatingThread, onClick = {
                model.createThread(title, agentId); dismiss()
            }) { Text("CREATE") }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text("CANCEL") } },
        containerColor = Surface,
    )
}

@Composable
private fun ConnectionStrip(state: AppState, model: ZedLinkViewModel) {
    var expanded by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)
        .clip(RoundedCornerShape(14.dp)).background(Surface).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) {
            TextButton(onClick = { expanded = true }) {
                Text("${state.profile?.name} › ${state.targets.firstOrNull { it.id == state.targetId }?.label ?: "Workspace"} ▾", color = Ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                DropdownMenuItem(text = { Text(state.profile?.endpoint.orEmpty()) }, onClick = {}, enabled = false)
                state.targets.forEach { target -> DropdownMenuItem(text = { Text(target.label + if (target.available) "" else " · unavailable") }, enabled = target.available, onClick = { expanded = false; model.selectTarget(target.id) }) }
            }
        }
        Box(Modifier.size(7.dp).background(if (state.live) Green else Warning, CircleShape))
        Spacer(Modifier.width(6.dp))
        Text(if (state.live) "Live" else state.status, color = if (state.live) Green else Warning,
            fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 104.dp))
        Spacer(Modifier.width(8.dp))
    }
}

@Composable
internal fun ThreadRow(thread: NativeThread, live: Boolean, pinned: Boolean, updated: Boolean, togglePin: () -> Unit, open: () -> Unit) {
    val activity = SessionActivity.from(thread)
    val tint = if (activity.attention) Warning else if (activity.running) Blue else Muted
    val shape = RoundedCornerShape(16.dp)
    Row(Modifier.padding(horizontal = 16.dp, vertical = 5.dp).fillMaxWidth()
        .clip(shape).background(Surface).border(1.dp, Line, shape),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).clickable(onClick = open).padding(start = 16.dp, end = 4.dp, top = 14.dp, bottom = 14.dp),
            verticalArrangement = Arrangement.spacedBy(7.dp)) {
            val count = when {
                activity == SessionActivity.APPROVAL && thread.approvalCount != null -> " (${thread.approvalCount})"
                activity == SessionActivity.INPUT && thread.inputCount != null -> " (${thread.inputCount})"
                else -> ""
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(7.dp).background(tint, CircleShape))
                Text(thread.agentName.uppercase(), style = monoLabel(), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                if (live && activity.running) CircularProgressIndicator(color = tint, strokeWidth = 1.5.dp, modifier = Modifier.size(12.dp))
                Text("${if (live) "" else "Last known · "}${activity.label}$count", color = tint, fontSize = 11.sp, modifier = Modifier.widthIn(max = 150.dp))
            }
            Text(thread.title, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            if (updated) Text("New activity", color = Blue, fontSize = 12.sp)
        }
        IconButton(onClick = togglePin) { Icon(Icons.Default.PushPin, if (pinned) "Unpin session" else "Pin session", tint = if (pinned) Blue else Subtle, modifier = Modifier.size(18.dp)) }
    }
}

@Composable
private fun ConversationScreen(state: AppState, model: ZedLinkViewModel) {
    val snapshot = state.snapshot
    val context = LocalContext.current
    val imageScope = rememberCoroutineScope()
    var imageToReview by remember(state.selectedThreadId) { mutableStateOf<Bitmap?>(null) }
    var imageLoading by remember { mutableStateOf(false) }
    fun reviewImage(uri: android.net.Uri?) {
        if (uri == null || imageLoading) return
        imageLoading = true
        imageScope.launch {
            imageToReview = runCatching { loadPromptBitmap(context, uri) }.getOrNull()
            if (imageToReview == null) model.reportIssue("This image could not be opened. Check the source app's sharing permission.")
            imageLoading = false
        }
    }
    val imagePicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { reviewImage(it) }
    fun pasteImage() {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val uri = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
        if (uri == null) model.reportIssue("The phone clipboard does not contain an image.") else reviewImage(uri)
    }
    imageToReview?.let { bitmap -> ImageAnnotationDialog(bitmap, { imageToReview = null }) { data ->
        model.addImage(data); imageToReview = null
    } }
    var showCommands by remember { mutableStateOf(false) }
    var chosenSlashDraft by remember { mutableStateOf("") }
    LaunchedEffect(state.draft) {
        if (state.draft.startsWith("/") && state.draft != chosenSlashDraft && state.draft.none { it.isWhitespace() }) { showCommands = true; model.refreshCommands() }
    }
    state.localConfirmation?.let { command -> AlertDialog(onDismissRequest = model::dismissLocalCommand, title = { Text("Run desktop action?") },
        text = { Text(command.confirmation ?: "Confirm this desktop action.") },
        confirmButton = { TextButton(onClick = model::confirmLocalCommand) { Text("Run /${command.name}") } },
        dismissButton = { TextButton(onClick = model::dismissLocalCommand) { Text("Cancel") } }) }
    var showClipboard by remember { mutableStateOf(false) }
    if (showClipboard) RemoteClipboardDialog(state, model, model::setDraft, { showClipboard = false }, "prompt")
    var showActions by remember { mutableStateOf(false) }
    var showRename by remember { mutableStateOf(false) }
    var showUnexpose by remember { mutableStateOf(false) }
    var showContextPage by remember { mutableStateOf<String?>(null) }
    var showAgentHistory by remember { mutableStateOf(false) }
    var historyChildId by remember(state.selectedThreadId) { mutableStateOf<String?>(null) }
    var lastKnownTitle by remember(state.selectedThreadId, state.instanceId, state.epoch) { mutableStateOf(state.threads.firstOrNull { it.id == state.selectedThreadId }?.title ?: "Agent thread") }
    LaunchedEffect(snapshot?.title) { if (snapshot?.threadId == state.selectedThreadId) snapshot?.title?.takeIf { it.isNotBlank() }?.let { lastKnownTitle = it } }
    if (showAgentHistory) Dialog(onDismissRequest = { showAgentHistory = false }) {
        Column(Modifier.fillMaxWidth().heightIn(max = 600.dp).background(Black)) {
            Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Agent history", modifier = Modifier.weight(1f)); TextButton(onClick = { showAgentHistory = false }) { Text("Close") }
            }
            LazyColumn { items(snapshot?.subagents.orEmpty(), key = { it.id }) { child ->
                TextButton(onClick = { historyChildId = child.id; showAgentHistory = false }, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.fillMaxWidth()) { Text(child.title); Text(child.status, color = Muted, style = monoLabel()) }
                }
            }
                if (snapshot?.subagents.isNullOrEmpty()) item { Text("No parallel agents in this conversation yet.", modifier = Modifier.padding(16.dp), color = Muted) }
            }
        }
    }
    historyChildId?.let { id -> SubagentReader(id, model) { historyChildId = null } }
    var showAgentSettings by remember { mutableStateOf(false) }
    if (showAgentSettings) AgentSettingsDialog(state, model) { showAgentSettings = false }
    var proposedTitle by remember(snapshot?.threadId) { mutableStateOf(snapshot?.title.orEmpty()) }
    if (showContextPage != null) {
        ProjectContextScreen(state, model, showContextPage ?: "Terminal") { showContextPage = null }
        return
    }
    Column(Modifier.fillMaxSize().navigationBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = model::closeThread) { Icon(Icons.Default.ArrowBack, "Sessions", tint = Ink) }
            Column(Modifier.weight(1f)) {
                val activity = state.threads.firstOrNull { it.id == state.selectedThreadId }?.let { SessionActivity.from(it) }
                Text(if (!state.live) state.status else if (snapshot == null) "Loading conversation…" else activity?.label ?: snapshot.status,
                    color = if (!state.live) Warning else if (snapshot?.isBusy == true) Blue else Muted,
                    fontSize = 11.sp)
            }
            Row {
                IconButton(onClick = { showContextPage = "Changes"; model.loadProjectContext() }) { Icon(Icons.Default.Edit, "Project changes", tint = Ink) }
                IconButton(onClick = { showContextPage = "Terminal"; model.loadProjectContext() }) { Icon(Icons.Default.GridView, "Workspace", tint = Ink) }
            }
            Box {
                IconButton(onClick = { showActions = true }) { Icon(Icons.Default.MoreVert, "Session actions", tint = Ink) }
                DropdownMenu(expanded = showActions, onDismissRequest = { showActions = false }) {
                    DropdownMenuItem(text = { Text("Agent history") }, onClick = { showActions = false; showAgentHistory = true })
                    DropdownMenuItem(text = { Text("Agent settings") }, onClick = { showActions = false; showAgentSettings = true })
                    if (state.delivery.startsWith("Delivery unknown") && state.live && !state.sending) {
            TextButton(onClick = { model.retryPending() }) { Text("Retry original request") }
        }
        if (state.delivery.isNotBlank()) DropdownMenuItem(text = { Text(state.delivery) }, enabled = false, onClick = {})
                    DropdownMenuItem(text = { Text("Rename session") }, leadingIcon = { Icon(Icons.Default.Edit, null) },
                        enabled = "thread.rename" in state.capabilities,
                        onClick = { proposedTitle = snapshot?.title.orEmpty(); showActions = false; showRename = true })
                    DropdownMenuItem(text = { Text("Stop exposing") }, leadingIcon = { Icon(Icons.Default.VisibilityOff, null) },
                        enabled = "thread.unexpose" in state.capabilities,
                        onClick = { showActions = false; showUnexpose = true })
                }
            }
        }
        Text(lastKnownTitle, fontWeight = FontWeight.SemiBold, fontSize = 18.sp,
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 10.dp))
        Rule()
        if (state.issue.isNotBlank()) Notice(state.issue)
        if (snapshot == null) Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Ink) }
        else Messages(snapshot, model, Modifier.weight(1f))
        snapshot?.agentError?.let { error ->
            Column(Modifier.fillMaxWidth().background(Surface).padding(12.dp)) {
                Text(error.title, color = Warning, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
                SelectionContainer {
                    Column(Modifier.heightIn(max = 100.dp).verticalScroll(rememberScrollState())) {
                        Text(error.message, color = Warning, fontSize = 12.sp)
                    }
                }
                if (error.retrying) Text("Desktop Zed is retrying this request.", color = Muted, fontSize = 12.sp)
            }
        }
        if (state.attachments.isNotEmpty() || state.contextPaths.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 10.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                state.attachments.forEach { image -> AssistChip(onClick = { model.removeImage(image.id) },
                    label = { Text(image.name) }, leadingIcon = { Icon(Icons.Default.Close, "Remove image", Modifier.size(16.dp)) }) }
                state.contextPaths.sorted().forEach { path -> AssistChip(onClick = { model.toggleContextPath(path) },
                    label = { Text(path, maxLines = 1) }, leadingIcon = { Icon(Icons.Default.Close, "Remove file", Modifier.size(16.dp)) }) }
            }
        }
        if (showCommands) CommandList(state.commands, {
            model.prepareSubagentTask(); showCommands = false
        }, { showClipboard = true; showCommands = false }, {
            showCommands = false; imagePicker.launch("image/*")
        }, { showCommands = false; pasteImage() }, { model.refresh(); showCommands = false }) { model.insertCommand(it); chosenSlashDraft = model.state.draft; showCommands = false }
        if (state.delivery.isNotBlank() && (!state.live || state.sending || state.delivery.startsWith("Delivery unknown"))) Text(state.delivery, color = Warning, fontSize = 11.sp,
            modifier = Modifier.fillMaxWidth().background(Surface).padding(8.dp))
        Composer(state, model, { showCommands = !showCommands; if (showCommands) model.refreshCommands() },
            { imagePicker.launch("image/*") }, imageLoading)
    }
    if (showRename) AlertDialog(
        onDismissRequest = { showRename = false },
        title = { Text("Rename session") },
        text = { OutlinedTextField(proposedTitle, { proposedTitle = it }, label = { Text("Session title") }, singleLine = true) },
        confirmButton = { TextButton(enabled = proposedTitle.isNotBlank(), onClick = {
            model.renameSelectedThread(proposedTitle); showRename = false
        }) { Text("RENAME") } },
        dismissButton = { TextButton(onClick = { showRename = false }) { Text("CANCEL") } },
        containerColor = Surface,
    )
    if (showUnexpose) AlertDialog(
        onDismissRequest = { showUnexpose = false },
        title = { Text("Stop exposing this session?") },
        text = { Text("The Agent keeps running in desktop Zed. Remote access to this session stops.") },
        confirmButton = { TextButton(onClick = { model.unexposeSelectedThread(); showUnexpose = false }) { Text("STOP EXPOSING") } },
        dismissButton = { TextButton(onClick = { showUnexpose = false }) { Text("CANCEL") } },
        containerColor = Surface,
    )
}

@Composable
internal fun ProjectContextScreen(state: AppState, model: ZedLinkViewModel, initialPage: String = "Terminal", close: () -> Unit) {
    var page by rememberSaveable(state.selectedThreadId, initialPage) { mutableStateOf(initialPage) }
    var selectedDiffPath by remember(state.selectedThreadId) { mutableStateOf<String?>(null) }
    var fullFiles by remember { mutableStateOf(false) }
    var terminalOnly by rememberSaveable { mutableStateOf(false) }
    val keyboardVisible = WindowInsets.ime.getBottom(androidx.compose.ui.platform.LocalDensity.current) > 0
    if (fullFiles) ProjectFileBrowser(state, model) { fullFiles = false }
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current
    fun closeWorkspace() { keyboard?.hide(); focus.clearFocus(); close() }
    BackHandler(onBack = ::closeWorkspace)
    // Use the activity window and its IME insets, rather than a second dialog window.
    Box(Modifier.fillMaxSize()) {
        Surface(color = Black, modifier = Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().systemBarsPadding().imePadding()) {
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(if (terminalOnly) "Terminal" else "Workspace", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    if (page == "Terminal") IconButton(onClick = { terminalOnly = !terminalOnly }) {
                        Icon(if (terminalOnly) Icons.Default.FullscreenExit else Icons.Default.Fullscreen,
                            if (terminalOnly) "Show workspace tabs" else "Expand terminal")
                    }
                    IconButton(onClick = ::closeWorkspace) { Icon(Icons.Default.Close, "Close workspace") }
                }
                if (!terminalOnly && !(page == "Terminal" && keyboardVisible)) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
                    listOf("Files", "Changes", "Terminal", "Tasks", "Debug").forEach { label ->
                        val selected = page == label
                        val underline = Ink
                        TextButton(onClick = { page = label }, shape = RectangleShape,
                            modifier = Modifier.heightIn(min = 44.dp).drawBehind {
                                if (selected) drawRect(underline, topLeft = androidx.compose.ui.geometry.Offset(0f, size.height - 2.dp.toPx()),
                                    size = androidx.compose.ui.geometry.Size(size.width, 2.dp.toPx()))
                            }) { Text(label, color = if (selected) Ink else Muted, fontSize = 12.sp) }
                    }
                }
                Rule()
                if (page != "Terminal" && state.issue.isNotBlank()) Notice(state.issue)
                if (page == "Terminal") {
                    Box(Modifier.weight(1f)) { TerminalScreen(state, model) }
                } else Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp)) {
                    when (page) {
                        "Files" -> {
                            Text("PROJECT FILES", style = monoLabel(), modifier = Modifier.padding(top = 12.dp))
                            TextButton(onClick = { fullFiles = true }) { Icon(Icons.Default.FolderOpen, null); Text("Browse files and folders") }
                        }
                        "Changes" -> {
                            Text("GIT CHANGES · ${state.changes.size} ${if (state.changes.size == 1) "FILE" else "FILES"}",
                                style = monoLabel(), modifier = Modifier.padding(top = 12.dp))
                            TextButton(onClick = model::loadDiff, enabled = state.live && state.changesRevision != null && "changes.diff" in state.capabilities && !state.previewLoading) { Text("LOAD FULL DIFF") }
                            if (state.previewLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
                            if (state.changes.isEmpty()) Text("No working tree changes", color = Muted)
                            state.changes.forEach { change ->
                                Row(Modifier.fillMaxWidth().heightIn(min = 52.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f).clickable { selectedDiffPath = change.id; if (state.previewTitle != "Working tree diff") model.loadDiff() }) {
                                        Text(change.id, maxLines = 2, overflow = TextOverflow.Ellipsis, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
                                        Text("${change.status} · ${change.staging}", color = Muted, fontSize = 11.sp)
                                    }
                                    TextButton(onClick = { model.mutateChange(change) },
                                        enabled = state.live && ((if (change.staging == "staged") "changes.unstage" else "changes.stage") in state.capabilities)) {
                                        Text(if (change.staging == "staged") "UNSTAGE" else "STAGE")
                                    }
                                }
                                Rule()
                            }
                            if (state.previewTitle == "Working tree diff" && state.previewContent.isNotEmpty()) {
                                val selected = selectedDiffPath?.let { path -> diffSection(state.previewContent, path) }
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(selectedDiffPath ?: state.previewTitle, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f).padding(top = 14.dp))
                                    if (selectedDiffPath != null) TextButton(onClick = { selectedDiffPath = null }) { Text("ALL FILES") }
                                }
                                if (selectedDiffPath != null && selected == null) Text("This file is outside the loaded diff. Showing the available diff.", color = Warning, fontSize = 11.sp)
                                if (state.previewTruncated) Text("Partial diff · native size limit", color = Warning, fontSize = 11.sp)
                                val shown = selected ?: state.previewContent
                                val added = shown.lineSequence().count { it.startsWith("+") && !it.startsWith("+++") }
                                val removed = shown.lineSequence().count { it.startsWith("-") && !it.startsWith("---") }
                                Text("+$added  −$removed in loaded diff", color = Muted, fontSize = 11.sp)
                                SelectionContainer { Text(shown, fontFamily = FontFamily.Monospace, fontSize = 11.sp) }
                            }
                        }
                        "Tasks" -> {
                            if ("task.catalog" in state.capabilities) {
                                Text("RUN CONFIGURED TASK", style = monoLabel(), modifier = Modifier.padding(top = 12.dp))
                                if (state.configuredTasks.isEmpty()) {
                                    Text("No configured Zed tasks are available for this project.", color = Muted, fontSize = 12.sp)
                                }
                                state.configuredTasks.forEach { task ->
                                    TextButton(onClick = { model.runConfiguredTask(task) }, enabled = "task.run" in state.capabilities,
                                        modifier = Modifier.fillMaxWidth()) {
                                        Row(Modifier.fillMaxWidth()) {
                                            Text(task.label, modifier = Modifier.weight(1f), maxLines = 1)
                                            Text(task.source.uppercase(), color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
                                        }
                                    }
                                }
                            }
                            if ("task.catalog" !in state.capabilities) Text("Enable Start Configured Tasks in desktop ZedLink settings.", color = Muted)
                        }
                        "Debug" -> {
                            Text("DEBUGGER", style = monoLabel(), modifier = Modifier.padding(top = 12.dp))
                            if ("debugger.catalog" !in state.capabilities) {
                                Text("Enable Start Configured Debuggers in desktop ZedLink settings and restart patched Zed.", color = Muted, fontSize = 12.sp)
                            } else if (state.debuggerCatalog.isEmpty()) {
                                Text("No configured Zed debuggers are available for this project.", color = Muted, fontSize = 12.sp)
                            }
                            state.debuggerCatalog.forEach { scenario ->
                                TextButton(onClick = { model.launchDebugger(scenario) }, enabled = "debugger.launch" in state.capabilities,
                                    modifier = Modifier.fillMaxWidth()) {
                                    Row(Modifier.fillMaxWidth()) {
                                        Text(scenario.label, modifier = Modifier.weight(1f), maxLines = 1)
                                        Text(scenario.adapter.uppercase(), color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
                                    }
                                }
                            }
                            if ("debugger.snapshot" !in state.capabilities) {
                                Text("Enable View Debugger Sessions in desktop ZedLink settings and restart patched Zed.", color = Muted, fontSize = 12.sp)
                            } else if (state.debuggerSessions.isEmpty()) {
                                Text("No debugger session is running in this Zed project.", color = Muted, fontSize = 12.sp)
                            }
                            state.debuggerSessions.forEach { debugger ->
                                Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                        Column(Modifier.weight(1f)) {
                                            Text(debugger.label, fontWeight = FontWeight.SemiBold)
                                            Text(debugger.adapter, color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
                                        }
                                        if (!debugger.terminated) {
                                            if (debugger.canRestart) {
                                                TextButton(onClick = { model.controlDebugger(debugger, "restart") }, enabled = "debugger.control" in state.capabilities) { Text("RESTART") }
                                            }
                                            TextButton(onClick = { model.controlDebugger(debugger, "stop") }, enabled = "debugger.control" in state.capabilities) { Text("STOP", color = MaterialTheme.colorScheme.error) }
                                        }
                                    }
                                    debugger.threads.forEach { thread ->
                                        Column(Modifier.fillMaxWidth().padding(start = 12.dp, top = 6.dp)) {
                                            Text("${thread.name} · ${thread.status.uppercase()}", fontSize = 12.sp)
                                            Row(Modifier.horizontalScroll(rememberScrollState())) {
                                                if (thread.status == "running") {
                                                    TextButton(onClick = { model.controlDebugger(debugger, "pause", thread) }, enabled = "debugger.control" in state.capabilities) { Text("PAUSE") }
                                                } else if (thread.status == "stopped") {
                                                    listOf("continue" to "CONTINUE", "step_over" to "OVER", "step_in" to "INTO", "step_out" to "OUT").forEach { (action, label) ->
                                                        TextButton(onClick = { model.controlDebugger(debugger, action, thread) }, enabled = "debugger.control" in state.capabilities) { Text(label) }
                                                    }
                                                    if (debugger.canStepBack) {
                                                        TextButton(onClick = { model.controlDebugger(debugger, "step_back", thread) }, enabled = "debugger.control" in state.capabilities) { Text("BACK") }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun diffSection(content: String, path: String): String? {
    val sections = content.split(Regex("(?m)(?=^diff --git )"))
    return sections.firstOrNull { section ->
        val header = section.lineSequence().firstOrNull().orEmpty()
        header.endsWith(" b/$path") || header.endsWith(" \"b/$path\"")
    }?.takeIf { it.startsWith("diff --git ") }
}

@Composable
private fun Messages(snapshot: ThreadSnapshot, model: ZedLinkViewModel, modifier: Modifier = Modifier) {
    var selectedChildId by remember(snapshot.threadId) { mutableStateOf<String?>(null) }
    val list = rememberLazyListState()
    val scrollScope = rememberCoroutineScope()
    var rewindPoint by remember { mutableStateOf<NativeRewindPoint?>(null) }
    var following by remember(snapshot.threadId) { mutableStateOf(true) }
    var lastReadTotal by remember(snapshot.threadId) { mutableIntStateOf(snapshot.totalEntries) }
    var searchOpen by rememberSaveable(snapshot.threadId) { mutableStateOf(false) }
    var searchQuery by rememberSaveable(snapshot.threadId) { mutableStateOf("") }
    var chosenMatch by remember(snapshot.threadId) { mutableIntStateOf(-1) }
    val matches = remember(snapshot.entries, snapshot.entryStartIndex, searchQuery) {
        if (searchQuery.isBlank()) emptyList() else snapshot.entries.indices
            .filter { snapshot.entries[it].contains(searchQuery, ignoreCase = true) }
            .map { snapshot.entryStartIndex + it }
    }
    val activeChildren = snapshot.subagents.filter { child -> child.isActive || snapshot.approvals.any { it.subagentId == child.id } }
    val headerCount = (if (snapshot.hasOlderEntries) 1 else 0) + (if (activeChildren.isNotEmpty()) 1 else 0) + activeChildren.size
    val rootApprovals = snapshot.approvals.filter { it.subagentId == null }
    val linkedApprovalIds = snapshot.entryMeta.mapNotNull { it?.callId }.toSet()
    val linkedQuestionIds = snapshot.entryMeta.mapNotNull { it?.elicitationId }.toSet()
    val fallbackApprovals = snapshot.approvals.filter { it.subagentId != null || it.id !in linkedApprovalIds }
    val fallbackQuestions = model.state.elicitations.filter { it.id !in linkedQuestionIds }
    val firstApproval = snapshot.approvals.firstOrNull()
    val firstQuestion = model.state.elicitations.firstOrNull()
    val reviewTargetIndex = when {
        firstApproval != null -> snapshot.entryMeta.indexOfFirst { it?.callId == firstApproval.id }
            .takeIf { it >= 0 }?.let { headerCount + it }
            ?: fallbackApprovals.indexOfFirst { it.id == firstApproval.id }.takeIf { it >= 0 }
                ?.let { headerCount + snapshot.entries.size + it }
        firstQuestion != null -> snapshot.entryMeta.indexOfFirst { it?.elicitationId == firstQuestion.id }
            .takeIf { it >= 0 }?.let { headerCount + it }
            ?: fallbackQuestions.indexOfFirst { it.id == firstQuestion.id }.takeIf { it >= 0 }
                ?.let { headerCount + snapshot.entries.size + fallbackApprovals.size + it }
        else -> null
    }
    fun jumpToMatch(index: Int) {
        val absolute = matches.getOrNull(index) ?: return
        chosenMatch = absolute
        following = false
        scrollScope.launch { list.scrollToItem(headerCount + absolute - snapshot.entryStartIndex) }
    }
    LaunchedEffect(list) {
        snapshotFlow { list.isScrollInProgress to list.canScrollForward }.collect { (scrolling, canScroll) ->
            if (scrolling) following = !canScroll
        }
    }
    LaunchedEffect(snapshot.totalEntries, following) { if (following) lastReadTotal = snapshot.totalEntries }
    LaunchedEffect(snapshot.entries, following) {
        if (following && snapshot.entries.isNotEmpty()) list.scrollToItem(maxOf(0, list.layoutInfo.totalItemsCount - 1))
    }
    Column(modifier.fillMaxWidth()) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = { searchOpen = !searchOpen; if (!searchOpen) { searchQuery = ""; chosenMatch = -1 } }) {
            Text(if (searchOpen) "Close search" else "Search conversation")
        }
        if (searchOpen) Text("Loaded entries only", color = Muted, fontSize = 11.sp)
    }
    if (searchOpen) {
        OutlinedTextField(searchQuery, { searchQuery = it; chosenMatch = -1 }, modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            label = { Text("Find in loaded conversation") }, singleLine = true)
        if (searchQuery.isNotBlank()) Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            val selected = matches.indexOf(chosenMatch)
            Text(if (matches.isEmpty()) "No matches in loaded entries" else "${if (selected < 0) 0 else selected + 1} of ${matches.size}",
                color = Muted, fontSize = 12.sp, modifier = Modifier.weight(1f))
            TextButton(onClick = { jumpToMatch(if (selected <= 0) matches.lastIndex else selected - 1) }, enabled = matches.isNotEmpty()) { Text("Previous") }
            TextButton(onClick = { jumpToMatch(if (selected < 0 || selected == matches.lastIndex) 0 else selected + 1) }, enabled = matches.isNotEmpty()) { Text("Next") }
        }
    }
    LazyColumn(Modifier.fillMaxWidth().weight(1f), state = list, contentPadding = PaddingValues(bottom = 10.dp)) {
        if (snapshot.hasOlderEntries) item {
            TextButton(onClick = model::loadEarlierHistory, shape = androidx.compose.ui.graphics.RectangleShape) {
                Text("LOAD EARLIER CONVERSATION · ${snapshot.entryStartIndex} REMAINING", color = Muted)
            }
        }
        if (activeChildren.isNotEmpty()) item("child-heading") {
            Text("PARALLEL AGENTS · ${snapshot.subagents.count { it.isActive }} ACTIVE", color = Muted, style = monoLabel(), modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
        }
        items(activeChildren, key = { "subagent:${it.id}" }) { child ->
            val needsApproval = snapshot.approvals.any { it.subagentId == child.id }
            Row(Modifier.fillMaxWidth().clickable { selectedChildId = child.id }.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                if (needsApproval) { Icon(Icons.Default.Warning, contentDescription = "Approval needed", tint = Warning); Spacer(Modifier.width(10.dp)) }
                else if (child.isActive) { CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp); Spacer(Modifier.width(10.dp)) }
                Column(Modifier.weight(1f)) {
                    Text(child.title, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text("${if (needsApproval) "Approval needed" else child.status} · ${if (child.totalEntries > 0) child.totalEntries else child.entries.size} entries", color = Muted, style = monoLabel())
                }
                Icon(Icons.Default.ChevronRight, contentDescription = "View agent activity")
            }
            HorizontalDivider(color = Line)
        }
        itemsIndexed(snapshot.entries, key = { index, _ -> snapshot.entryStartIndex + index }) { index, markdown ->
            val absoluteIndex = snapshot.entryStartIndex + index
            val meta = snapshot.entryMeta.getOrNull(index)
            val question = model.state.elicitations.firstOrNull { it.id == meta?.elicitationId }
            if (question == null) Message(NativeEntry.parse(markdown), snapshot.isBusy && index == snapshot.entries.lastIndex)
            question?.let { ElicitationCard(it, model) }
            rootApprovals.firstOrNull { it.id == meta?.callId }?.let { ApprovalCard(it, model::respondApproval) }
            snapshot.rewindPoints.firstOrNull { it.entryIndex == absoluteIndex }?.let { point ->
                if (!snapshot.isBusy && "thread.rewind" in model.state.capabilities) {
                    TextButton(onClick = { rewindPoint = point }) { Text("REWIND CONVERSATION HERE", color = Warning) }
                }
            }
        }
        items(fallbackApprovals, key = { "approval:${it.subagentId}:${it.turnId}:${it.id}" }) { ApprovalCard(it, model::respondApproval) }
        items(fallbackQuestions, key = { "elicitation:${it.id}" }) { ElicitationCard(it, model) }
        model.state.editReview?.let { review -> item("edit-review") { EditReviewCard(review, model) } }
        if (model.state.queuedMessages.isNotEmpty()) item("queue") { QueueCard(model.state.queuedMessages, model) }
    }
    if (reviewTargetIndex != null && list.layoutInfo.visibleItemsInfo.none { it.index == reviewTargetIndex }) {
        TextButton(onClick = { scrollScope.launch { list.animateScrollToItem(reviewTargetIndex) } }, modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp)) {
            Icon(Icons.Default.Warning, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text("Review pending action")
        }
    }
    if (!following) TextButton(onClick = { following = true }, modifier = Modifier.fillMaxWidth()) {
        val unread = (snapshot.totalEntries - lastReadTotal).coerceAtLeast(0)
        Text(if (unread > 0) "Latest ↓ · $unread new" else "Latest ↓")
    }
    }
    selectedChildId?.let { id ->
        SubagentReader(id, model) { selectedChildId = null }
    }
    rewindPoint?.let { point -> AlertDialog(
        onDismissRequest = { rewindPoint = null }, title = { Text("Rewind this conversation?") },
        text = { Text("Messages and Agent edits after this point may be removed.") },
        confirmButton = { TextButton(onClick = { rewindPoint = null; model.rewind(point) }) { Text("REWIND") } },
        dismissButton = { TextButton(onClick = { rewindPoint = null }) { Text("CANCEL") } }, containerColor = Surface,
    ) }
}

@Composable
private fun ElicitationCard(item: NativeElicitation, model: ZedLinkViewModel) {
    val scope = listOf(model.state.profile?.gatewayId, model.state.targetId, model.state.instanceId, model.state.epoch, model.state.selectedThreadId)
    val values = remember(item.id, scope) { mutableStateMapOf<String, String>() }
    val selections = remember(item.id, scope) { mutableStateMapOf<String, Set<String>>() }
    var validation by remember(item.id, scope) { mutableStateOf("") }
    val submitting = (scope + item.id).joinToString("\n") in model.state.resolvingElicitations
    val enabled = model.state.live && "elicitation.respond" in model.state.capabilities && !submitting
    Column(Modifier.fillMaxWidth().background(Surface).border(1.dp, Warning).padding(14.dp)) {
        Text("INPUT REQUESTED", color = Warning, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
        Text(item.message, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(vertical = 8.dp))
        item.url?.let { Text(it, color = Blue, fontSize = 12.sp) }
        item.fields.forEach { field ->
            val title = field.title + if (field.required) " *" else ""
            when {
                field.type == "boolean" -> Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(ElicitationForm.value(field, values) == "true", { values[field.id] = it.toString() }, enabled = enabled)
                    Text(title)
                }
                field.type == "array" && field.choices.isNotEmpty() -> {
                    Text(title)
                    field.choices.forEach { choice ->
                        val selected = selections[field.id] ?: field.defaultArray.orEmpty().toSet()
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(choice in selected, { selections[field.id] = if (it) selected + choice else selected - choice }, enabled = enabled)
                            Text(choice)
                        }
                    }
                }
                field.choices.isNotEmpty() -> {
                    var expanded by remember(item.id, field.id) { mutableStateOf(false) }
                    Box {
                        TextButton(onClick = { expanded = true }, enabled = enabled) { Text("$title: ${ElicitationForm.value(field, values).ifEmpty { "No value" }}") }
                        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                            if (!field.required) DropdownMenuItem(text = { Text("No value") }, onClick = { values[field.id] = ""; expanded = false })
                            field.choices.forEach { choice -> DropdownMenuItem(text = { Text(choice) }, onClick = { values[field.id] = choice; expanded = false }) }
                        }
                    }
                }
                else -> OutlinedTextField(ElicitationForm.value(field, values), { values[field.id] = it }, label = { Text(title) }, enabled = enabled, modifier = Modifier.fillMaxWidth())
            }
        }
        if (validation.isNotEmpty()) Text(validation, color = Warning)
        if (submitting) LinearProgressIndicator(Modifier.fillMaxWidth())
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = { model.respondElicitation(item, "decline") }, enabled = enabled) { Text("DECLINE") }
            Button(onClick = {
                try { val content = ElicitationForm.content(item.fields, values, selections); validation = ""; model.respondElicitation(item, "accept", org.json.JSONObject(content)) }
                catch (error: IllegalArgumentException) { validation = error.message.orEmpty() }
            }, enabled = enabled, shape = androidx.compose.ui.graphics.RectangleShape) { Text("SUBMIT") }
        }
    }
}

@Composable
private fun EditReviewCard(review: NativeEditReview, model: ZedLinkViewModel) {
    Column(Modifier.fillMaxWidth().background(Surface).border(1.dp, Line).padding(14.dp)) {
        Text("REVIEW AGENT EDITS", style = monoLabel())
        Text("${review.changedFiles} files · +${review.linesAdded} −${review.linesRemoved}", color = Muted)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = { model.resolveEditReview("reject_all") }) { Text("REJECT ALL") }
            Button(onClick = { model.resolveEditReview("keep_all") }, shape = androidx.compose.ui.graphics.RectangleShape) { Text("KEEP ALL") }
        }
    }
}

@Composable
private fun QueueCard(entries: List<NativeQueueEntry>, model: ZedLinkViewModel) {
    Column(Modifier.fillMaxWidth().background(Surface).border(1.dp, Line).padding(14.dp)) {
        Text("${entries.size} QUEUED MESSAGE${if (entries.size == 1) "" else "S"}", style = monoLabel())
        entries.forEach { Text(it.preview, maxLines = 2, overflow = TextOverflow.Ellipsis, color = Muted, fontSize = 12.sp) }
        TextButton(onClick = model::clearQueue) { Text("CLEAR QUEUE") }
    }
}

@Composable
private fun ActivityPanel(snapshot: ThreadSnapshot) {
    var expanded by remember { mutableStateOf(true) }
    val activity = snapshot.activityEntries.map(NativeEntry::parse).flatMap { entry ->
        entry.reasoning.map { "Reasoning" to it } + if (entry.kind == EntryKind.TOOL || entry.kind == EntryKind.PLAN) listOf(entry.label to entry.body) else emptyList()
    }
    Column(Modifier.fillMaxWidth().padding(12.dp).border(1.dp, Line).background(Surface)) {
        Row(Modifier.fillMaxWidth().clickable { expanded = !expanded }.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(if (snapshot.isBusy) "●" else "○", color = if (snapshot.isBusy) Green else Subtle)
            Text(" Zed is working", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text(if (expanded) "HIDE" else "SHOW", color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
        }
        if (expanded) {
            Rule()
            activity.forEach { (label, body) ->
                Text(label.uppercase(), color = Subtle, fontSize = 10.sp, fontFamily = FontFamily.Monospace,
                    modifier = Modifier.padding(start = 12.dp, end = 12.dp, top = 10.dp))
                Text(body, color = Muted, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 12.dp, vertical = 5.dp))
            }
            if (activity.isEmpty()) Text("Waiting for native activity…", color = Muted, modifier = Modifier.padding(12.dp))
        }
    }
}

@Composable
private fun Message(entry: NativeEntry, thinkingLive: Boolean = false) {
    var reasoningExpanded by remember(entry.reasoning, thinkingLive) { mutableStateOf(thinkingLive) }
    when (entry.kind) {
        EntryKind.TOOL -> ToolCard(entry)
        EntryKind.USER -> Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
            Spacer(Modifier.width(42.dp))
            Column(Modifier.weight(1f).wrapContentWidth(Alignment.End).widthIn(max = 760.dp)
                .background(Raised).padding(horizontal = 14.dp, vertical = 11.dp)) {
                Text(entry.label.uppercase(), color = Subtle, fontSize = 10.sp, fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold)
                SelectionContainer { MarkdownLikeText(entry.body) }
            }
        }
        else -> Column(Modifier.fillMaxWidth().padding(16.dp)) {
            Text(entry.label.uppercase(), color = if (entry.kind == EntryKind.ASSISTANT) Blue else Subtle,
                fontSize = 10.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold)
            if (entry.reasoning.isNotEmpty()) {
                TextButton(onClick = { reasoningExpanded = !reasoningExpanded }, shape = androidx.compose.ui.graphics.RectangleShape) {
                    Text(if (reasoningExpanded) "HIDE THINKING" else "SHOW THINKING", color = Muted)
                }
                if (reasoningExpanded) entry.reasoning.forEach { thought ->
                    SelectionContainer { MarkdownLikeText(thought, Modifier.padding(vertical = 6.dp)) }
                }
            }
            SelectionContainer { MarkdownLikeText(entry.body) }
        }
    }
    Rule(14.dp)
}

@Composable
private fun ToolCard(entry: NativeEntry) {
    var expanded by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(12.dp).border(1.dp, Line).background(Surface)) {
        Text("ZED TOOL", color = Subtle, fontSize = 10.sp, fontFamily = FontFamily.Monospace, modifier = Modifier.padding(12.dp, 10.dp, 12.dp, 0.dp))
        Text(entry.toolName ?: "Native tool", fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp))
        Text(entry.toolStatus ?: "Native status", color = Green, fontFamily = FontFamily.Monospace, fontSize = 11.sp, modifier = Modifier.padding(horizontal = 12.dp))
        TextButton(onClick = { expanded = !expanded }, shape = androidx.compose.ui.graphics.RectangleShape) { Text(if (expanded) "HIDE OUTPUT" else "SHOW OUTPUT", color = Ink) }
        if (expanded) SelectionContainer { MarkdownLikeText(entry.body, Modifier.padding(12.dp)) }
    }
}

@Composable
private fun MarkdownLikeText(text: String, modifier: Modifier = Modifier) {
    NativeMarkdown(text, modifier, Ink, Muted, Line, Surface)
}

@Composable
private fun ApprovalCard(approval: NativeApproval, respond: (NativeApproval, NativeApprovalDecision) -> Unit) {
    Column(Modifier.fillMaxWidth().background(Surface).border(1.dp, Warning).padding(14.dp)) {
        Text(if (approval.authorizationKind == "action_choice") "CHOOSE AN ACTION" else "PERMISSION REQUESTED",
            color = Warning, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
        Text(approval.toolName, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 7.dp))
        Text(approval.display, color = Muted)
        approval.rawInput?.let { SelectionContainer { Text(it, fontFamily = FontFamily.Monospace, fontSize = 11.sp, modifier = Modifier.padding(top = 8.dp)) } }
        if (approval.decisions.isEmpty()) {
            Text("Update patched Zed to resolve this request remotely.", color = Warning, fontSize = 11.sp, modifier = Modifier.padding(top = 8.dp))
        } else approval.decisions.forEach { decision ->
            Button(
                onClick = { respond(approval, decision) },
                enabled = !approval.detailsTruncated || (decision.isRejecting && approval.authorizationKind != "action_choice"),
                shape = androidx.compose.ui.graphics.RectangleShape,
                modifier = Modifier.fillMaxWidth().padding(top = 7.dp),
            ) { Text(decision.displayLabel) }
        }
    }
}

@Composable
private fun CommandList(commands: List<NativeCommand>, delegate: () -> Unit, clipboard: () -> Unit,
    attachImage: () -> Unit, pasteImage: () -> Unit, recover: () -> Unit, choose: (NativeCommand) -> Unit) {
    var search by remember { mutableStateOf("") }
    Column(Modifier.fillMaxWidth().heightIn(max = 260.dp).border(1.dp, Line).background(Raised).verticalScroll(rememberScrollState())) {
        OutlinedTextField(search, { search = it }, label = { Text("Search commands and skills") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Row(Modifier.fillMaxWidth().clickable(onClick = delegate).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.AccountTree, null, tint = Blue, modifier = Modifier.size(19.dp))
            Column(Modifier.padding(start = 11.dp)) {
                Text("Delegate a parallel task", fontWeight = FontWeight.SemiBold)
                Text("Ask native Zed to use spawn_agent", color = Muted, fontSize = 12.sp)
            }
        }
        Rule()
        TextButton(onClick = attachImage) { Icon(Icons.Default.AddPhotoAlternate, null); Text("Attach and annotate image") }
        TextButton(onClick = pasteImage) { Icon(Icons.Default.ContentPaste, null); Text("Paste image from phone") }
        TextButton(onClick = clipboard) { Text("Remote clipboard") }
        TextButton(onClick = recover) { Text("Recover session") }
        if (commands.isEmpty()) Text("No commands are advertised by this native thread.", color = Muted, modifier = Modifier.padding(14.dp))
        commands.filter { search.isBlank() || it.name.contains(search, true) || it.description.contains(search, true) }.forEach { command ->
            Column(Modifier.fillMaxWidth().clickable { choose(command) }.padding(12.dp)) {
                Text("/${command.name}", fontFamily = FontFamily.Monospace, modifier = Modifier.fillMaxWidth())
                Column(Modifier.fillMaxWidth()) {
                    Text(command.description, color = Muted, fontSize = 12.sp)
                    command.inputHint?.let { Text(it, color = Blue, fontSize = 11.sp) }
                    command.warning?.let { Text(it, color = Warning, fontSize = 11.sp) }
                    Text(command.category, color = Muted, fontSize = 10.sp)
                }
            }
            Rule()
        }
    }
}

@Composable
private fun Composer(state: AppState, model: ZedLinkViewModel, commands: () -> Unit, attachImage: () -> Unit, imageLoading: Boolean) {
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val submit = {
        if (state.live && (state.draft.isNotBlank() || state.attachments.isNotEmpty() || state.contextPaths.isNotEmpty()) && !state.sending) {
            focusManager.clearFocus(force = true)
            keyboard?.hide()
            model.send()
        }
    }
    val canCancel = state.live && state.snapshot?.currentTurnId != null && "thread.cancel" in state.capabilities
    val sendEnabled = state.live && (state.draft.isNotBlank() || state.attachments.isNotEmpty() || state.contextPaths.isNotEmpty()) && !state.sending
    val shape = RoundedCornerShape(22.dp)
    Column(Modifier.fillMaxWidth()) {
    if (state.live) state.threadSettings?.let { settings ->
        val agent = state.threads.firstOrNull { it.id == state.selectedThreadId }?.agentName ?: "Zed Agent"
        val modelName = settings.models.firstOrNull { it.modelId == settings.modelId && it.providerId == settings.providerId }?.name ?: settings.modelId
        Text(agent + (modelName?.let { " · $it" } ?: ""), color = Muted, fontSize = 11.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 2.dp))
    }
    BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp)) {
        val narrow = maxWidth < 420.dp
        val actions: @Composable () -> Unit = {
            IconButton(onClick = commands) { Icon(Icons.Default.Add, "Commands and context", tint = Ink) }
            IconButton(onClick = attachImage, enabled = !imageLoading && "thread.attachments" in state.capabilities && state.supportsImages != false) {
                if (imageLoading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                else Icon(Icons.Default.AddPhotoAlternate, "Attach or annotate image", tint = Ink)
            }
        }
        val finish: @Composable () -> Unit = {
            VoiceDraftButton(state.draft, "${state.targetId}.${state.instanceId}.${state.epoch}.${state.selectedThreadId}", model::setDraft)
            IconButton(onClick = { if (canCancel) model.cancel() else submit() }, enabled = if (canCancel) !state.sending else sendEnabled,
                modifier = Modifier.size(44.dp).background(if (canCancel || sendEnabled) Ink else Line, CircleShape)) {
                Icon(if (canCancel) Icons.Default.Stop else Icons.Default.ArrowUpward, if (canCancel) "Stop current turn" else "Send",
                    tint = if (canCancel || sendEnabled) Black else Subtle)
            }
        }
        if (narrow) Column(Modifier.fillMaxWidth().clip(shape).background(Surface).border(1.dp, Line, shape).padding(5.dp)) {
            ComposerDraftField(state, model, Modifier.fillMaxWidth().heightIn(min = 44.dp, max = 140.dp).padding(horizontal = 12.dp, vertical = 8.dp), submit)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                actions()
                Spacer(Modifier.weight(1f))
                finish()
            }
        } else Row(Modifier.fillMaxWidth().clip(shape).background(Surface).border(1.dp, Line, shape).padding(5.dp),
            verticalAlignment = Alignment.Bottom) {
            actions()
            ComposerDraftField(state, model, Modifier.weight(1f).heightIn(min = 44.dp, max = 140.dp).padding(11.dp), submit)
            finish()
        }
    }
    }
}

@Composable
private fun ComposerDraftField(state: AppState, model: ZedLinkViewModel, modifier: Modifier, submit: () -> Unit) {
    BasicTextField(state.draft, model::setDraft, modifier, textStyle = TextStyle(color = Ink, fontSize = 16.sp),
        cursorBrush = SolidColor(Ink), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = { submit() }),
        decorationBox = { inner -> Box { if (state.draft.isEmpty()) Text("Message Zed Agent…", color = Subtle); inner() } })
}

@Composable internal fun Header(title: String, subtitle: String, action: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().heightIn(min = 68.dp).padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) { Text(title, fontSize = 28.sp, fontWeight = FontWeight.SemiBold); if (subtitle.isNotBlank()) Text(subtitle, color = Muted, fontSize = 12.sp) }
        action()
    }
}
@Composable private fun SectionHeading(label: String, value: String) { Row(Modifier.fillMaxWidth().padding(16.dp, 14.dp, 16.dp, 7.dp)) { Text(label, style = monoLabel()); Spacer(Modifier.weight(1f)); Text(value, color = Subtle, style = monoLabel()) } }
@Composable internal fun Notice(text: String) {
    var expanded by remember(text) { mutableStateOf(false) }
    var dismissed by remember(text) { mutableStateOf(false) }
    if (!dismissed) Row(Modifier.fillMaxWidth().background(Surface), verticalAlignment = Alignment.CenterVertically) {
        Text(text, color = Warning, fontSize = 12.sp, maxLines = if (expanded) Int.MAX_VALUE else 2,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).heightIn(max = 120.dp)
                .verticalScroll(rememberScrollState()).clickable { expanded = !expanded }.padding(12.dp))
        IconButton(onClick = { dismissed = true }) { Icon(Icons.Default.Close, "Dismiss notice", tint = Muted, modifier = Modifier.size(18.dp)) }
    }
}
@Composable private fun Rule(start: androidx.compose.ui.unit.Dp = 0.dp) { HorizontalDivider(Modifier.padding(start = start), color = Line, thickness = 1.dp) }
@Composable private fun FlatButton(label: String, modifier: Modifier = Modifier, enabled: Boolean = true, action: () -> Unit) { Button(action, modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = enabled, shape = androidx.compose.ui.graphics.RectangleShape, colors = ButtonDefaults.buttonColors(containerColor = Ink, contentColor = Black)) { Text(label, fontWeight = FontWeight.Bold) } }
@Composable private fun FlatIconButton(label: String, action: () -> Unit) { Box(Modifier.size(44.dp).border(1.dp, Line).clickable(onClick = action), contentAlignment = Alignment.Center) { Text(label, fontFamily = FontFamily.Monospace, fontSize = 20.sp) } }
@Composable private fun monoLabel() = TextStyle(color = Subtle, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, fontSize = 10.sp, letterSpacing = 1.sp)


@Composable
private fun TerminalScreen(state: AppState, model: ZedLinkViewModel) {
    var input by remember { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    var tools by remember { mutableStateOf(false) }
    var clipboard by remember { mutableStateOf(false) }
    var browsingFiles by remember { mutableStateOf(false) }
    var inputFocused by remember { mutableStateOf(false) }
    val keyboardVisible = WindowInsets.ime.getBottom(androidx.compose.ui.platform.LocalDensity.current) > 0
    if (browsingFiles) ProjectFileBrowser(state, model) { browsingFiles = false }
    val preferences = LocalContext.current.getSharedPreferences("zedlink-terminal", 0)
    var wrapOutput by remember { mutableStateOf(preferences.getBoolean("wrap", true)) }
    var terminalFontSize by remember { mutableStateOf(preferences.getInt("font-size", 14).coerceIn(12, 20)) }
    if (clipboard) RemoteClipboardDialog(state, model, { input = it }, { clipboard = false })
    val scrollScope = rememberCoroutineScope()
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current
    val terminalScroll = rememberScrollState()
    val horizontalScroll = rememberScrollState()
    val latestState by rememberUpdatedState(state)
    val canType = state.live && state.terminalSnapshot != null && "terminal.input" in state.capabilities
    val inputFocus = remember { FocusRequester() }
    fun showTerminalKeyboard() {
        if (canType) {
            inputFocus.requestFocus()
            keyboard?.show()
        }
    }
    var followOutput by remember(state.terminalSnapshot?.terminal?.id) { mutableStateOf(true) }
    val draftKey = terminalDraftKey(state)
    var loadedDraftKey by remember { mutableStateOf("") }
    var terminalSending by remember(draftKey) { mutableStateOf(false) }
    fun updateTerminalDraft(value: String) {
        input = value
        if (loadedDraftKey == draftKey && state.terminalSnapshot != null) preferences.edit().putString(draftKey, value).apply()
    }
    LaunchedEffect(draftKey) { input = preferences.getString(draftKey, "").orEmpty(); loadedDraftKey = draftKey }
    LaunchedEffect(input, loadedDraftKey) { if (loadedDraftKey == draftKey && state.terminalSnapshot != null) preferences.edit().putString(draftKey, input).apply() }
    LaunchedEffect(state.terminalAcceptedDraft, loadedDraftKey) {
        if (state.terminalAcceptedDraft != null && input == state.terminalAcceptedDraft && loadedDraftKey == draftKey) input = ""
    }
    LaunchedEffect(terminalScroll) {
        snapshotFlow { terminalScroll.isScrollInProgress to (terminalScroll.value >= terminalScroll.maxValue - 40) }
            .collect { (scrolling, nearBottom) -> if (scrolling) followOutput = nearBottom }
    }
    LaunchedEffect(state.terminalSnapshot?.content, input, inputFocused, followOutput) {
        if (followOutput) {
            withFrameNanos { }
            terminalScroll.scrollTo(terminalScroll.maxValue)
        }
    }
    LaunchedEffect(state.terminals, state.live) {
        if (state.live && state.terminalSnapshot == null) state.terminals.firstOrNull()?.let { model.loadTerminal(it) }
    }
    LaunchedEffect(state.terminalSnapshot?.terminal?.id, state.live) {
        while (true) {
            if (latestState.live) latestState.terminalSnapshot?.terminal?.let { model.loadTerminal(it, refresh = true).join() }
            delay(1000)
        }
    }
    fun sendTerminal(bytes: String) {
        if (!canType || loadedDraftKey != draftKey || terminalSending || state.terminalInputPending || state.terminalInputUncertain) return
        val draft = input
        val scopeKey = draftKey
        terminalSending = true
        scrollScope.launch {
            try {
                if (model.sendTerminalInput(draft + bytes, appendReturn = false, draft = draft).await() &&
                    loadedDraftKey == scopeKey && input == draft) input = ""
            } finally { terminalSending = false }
        }
    }
    val content: @Composable () -> Unit = {
        Surface(color = Black, modifier = Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize()) {
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) {
                        TextButton(onClick = { menu = true }, enabled = state.live && !state.creatingTerminal && state.terminals.isNotEmpty()) { Text(state.terminalSnapshot?.terminal?.title ?: "Choose terminal", maxLines = 1, overflow = TextOverflow.Ellipsis) }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            state.terminals.forEachIndexed { index, terminal ->
                                DropdownMenuItem(text = { Text("${index + 1}. ${terminal.title}", maxLines = 2) },
                                    leadingIcon = { Icon(if (state.terminalSnapshot?.terminal?.id == terminal.id) Icons.Default.Check else Icons.Default.Terminal, null) },
                                    onClick = { menu = false; keyboard?.hide(); focus.clearFocus(); model.loadTerminal(terminal) })
                            }
                        }
                    }
                    IconButton(onClick = { keyboard?.hide(); focus.clearFocus(); model.createTerminal() },
                        enabled = state.live && !state.creatingTerminal && "terminal.create" in state.capabilities) {
                        if (state.creatingTerminal) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        else Icon(Icons.Default.Add, "New terminal")
                    }
                    Text(if (!state.live) "Offline" else if ("terminal.input" in state.capabilities) "Interactive" else "Read only",
                        color = if (canType) Green else Muted, fontSize = 10.sp)
                    IconButton(onClick = { keyboard?.hide(); focus.clearFocus(); browsingFiles = true },
                        enabled = "project.directory" in state.capabilities || "project.files" in state.capabilities) {
                        Icon(Icons.Default.FolderOpen, "Browse project files")
                    }
                    IconButton(onClick = {
                        if (keyboardVisible) { keyboard?.hide(); focus.clearFocus() } else showTerminalKeyboard()
                    }, enabled = canType) {
                        Icon(if (keyboardVisible) Icons.Default.KeyboardHide else Icons.Default.Keyboard,
                            if (keyboardVisible) "Hide keyboard" else "Type in terminal")
                    }
                    if (state.terminalSnapshot?.terminal?.taskState == "running" && "task.stop" in state.capabilities) {
                        IconButton(onClick = model::stopTerminalTask, enabled = state.live) { Icon(Icons.Default.Stop, "Stop task", tint = MaterialTheme.colorScheme.error) }
                    }
                    Box {
                        IconButton(onClick = { tools = true }) { Icon(Icons.Default.MoreVert, "Terminal tools") }
                        DropdownMenu(expanded = tools, onDismissRequest = { tools = false }) {
                            DropdownMenuItem(text = { Text("Refresh terminals") }, onClick = { model.loadProjectContext(); tools = false }, enabled = state.live)
                            DropdownMenuItem(text = { Text("List files one per line") }, enabled = canType && input.isBlank() && loadedDraftKey == draftKey && !state.terminalInputPending && !state.terminalInputUncertain,
                                onClick = { updateTerminalDraft("ls -1F"); tools = false; showTerminalKeyboard() })
                            DropdownMenuItem(text = { Text(if (wrapOutput) "Keep original columns (scroll sideways)" else "Wrap long lines") }, onClick = { wrapOutput = !wrapOutput; preferences.edit().putBoolean("wrap", wrapOutput).apply(); tools = false })
                            DropdownMenuItem(text = { Text("Larger text") }, enabled = terminalFontSize < 20, onClick = {
                                terminalFontSize += 2; preferences.edit().putInt("font-size", terminalFontSize).apply()
                            })
                            DropdownMenuItem(text = { Text("Smaller text") }, enabled = terminalFontSize > 12, onClick = {
                                terminalFontSize -= 2; preferences.edit().putInt("font-size", terminalFontSize).apply()
                            })
                            DropdownMenuItem(text = { Text("Remote clipboard") }, onClick = { clipboard = true; tools = false })
                            DropdownMenuItem(text = { Text("Recover session") }, onClick = { model.refresh(); tools = false })
                            if (state.terminalInputUncertain) DropdownMenuItem(text = { Text("I checked previous input in Zed") },
                                onClick = { model.acknowledgeTerminalDelivery(); tools = false })
                        }
                    }
                    if (!followOutput) IconButton(onClick = { followOutput = true; scrollScope.launch { terminalScroll.scrollTo(terminalScroll.maxValue) } }) { Icon(Icons.Default.ArrowDownward, "Latest output") }
                }
                Rule()
                if (state.terminalDelivery.isNotBlank() && (state.terminalInputPending || state.terminalInputUncertain)) {
                    Text(state.terminalDelivery, color = Warning, fontSize = 12.sp, modifier = Modifier.padding(10.dp))
                }
                if (state.issue.isNotBlank() && !state.terminalInputPending && !state.terminalInputUncertain) Notice(state.issue)
                if ("terminal.input" in state.capabilities) {
                    if (keyboardVisible || inputFocused) Row(Modifier.fillMaxWidth().background(Surface), verticalAlignment = Alignment.CenterVertically) {
                        VoiceDraftButton(input, draftKey) { updateTerminalDraft(it) }
                        TerminalKeyStrip(canType && !terminalSending && !state.terminalInputPending && !state.terminalInputUncertain,
                            Modifier.weight(1f)) { bytes -> sendTerminal(bytes) }
                    }
                } else { Text("Enable Send Terminal Input in desktop ZedLink settings.", color = Muted, modifier = Modifier.padding(12.dp)) }
                Rule()
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    if (state.terminals.isEmpty() && state.terminalSnapshot == null) Column(
                        Modifier.align(Alignment.Center).padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("No terminals open", fontWeight = FontWeight.SemiBold)
                        if ("terminal.create" in state.capabilities) TextButton(onClick = { model.createTerminal() }, enabled = state.live && !state.creatingTerminal) {
                            Text(if (state.creatingTerminal) "Starting terminal…" else "New terminal")
                        } else Text("Open a terminal in desktop Zed. Remote creation requires an updated bridge and terminal viewing/input permissions.", color = Muted)
                    } else BoxWithConstraints(Modifier.fillMaxSize()) {
                        val columns = (((maxWidth.value - 20f) / (terminalFontSize * 0.62f)).toInt()).coerceIn(24, 120)
                        val rows = (((maxHeight.value - 20f) / (terminalFontSize + 4f)).toInt()).coerceIn(8, 80)
                        LaunchedEffect(state.terminalSnapshot?.terminal?.id, columns, rows, state.live) {
                            if (state.live && state.terminalSnapshot != null) model.resizeTerminal(columns, rows)
                        }
                        TerminalOutput(if (state.terminalSnapshot != null) terminalText(state.terminalSnapshot, input,
                            inputFocused && canType && !state.terminalInputPending && !state.terminalInputUncertain) else AnnotatedString(
                        if ("terminal.list" !in state.capabilities) "Enable View Project Terminals in desktop ZedLink settings."
                        else if (!state.live) "Reconnect to view live terminal output."
                        else if (state.terminals.isEmpty()) "Open a terminal in this Zed workspace."
                        else "Loading terminal…"), terminalScroll, horizontalScroll, wrapOutput, canType, fontSize = terminalFontSize) { showTerminalKeyboard() }
                        if ("terminal.input" in state.capabilities) BasicTextField(value = input,
                            onValueChange = ::updateTerminalDraft, enabled = canType,
                            modifier = Modifier.align(Alignment.BottomStart).size(1.dp).focusRequester(inputFocus)
                                .onFocusChanged { inputFocused = it.isFocused }
                                .onPreviewKeyEvent { event ->
                                    if (event.type == KeyEventType.KeyDown && event.key == Key.Enter) {
                                        sendTerminal("\r"); true
                                    } else false
                                }
                                .semantics { contentDescription = "Type directly in terminal" },
                            singleLine = true,
                            textStyle = TextStyle(color = Color.Transparent, fontSize = 1.sp),
                            cursorBrush = SolidColor(Color.Transparent),
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send, autoCorrectEnabled = false),
                            keyboardActions = KeyboardActions(onSend = { sendTerminal("\r") }))
                    }
                }
            }
        }
    }
    content()
}

@Composable internal fun TerminalOutput(text: AnnotatedString, vertical: ScrollState, horizontal: ScrollState,
    wrap: Boolean, canType: Boolean, fontSize: Int = 14, onType: () -> Unit) {
    SelectionContainer(Modifier.fillMaxSize()) {
        Text(text, color = Ink, fontFamily = FontFamily.Monospace, fontSize = fontSize.sp, lineHeight = (fontSize + 4).sp, softWrap = wrap,
            modifier = Modifier.fillMaxSize().testTag("terminal-output").verticalScroll(vertical)
                .then(if (wrap) Modifier else Modifier.horizontalScroll(horizontal))
                .clickable(enabled = canType, onClickLabel = "Type in terminal", onClick = onType).padding(10.dp))
    }
}

@Composable internal fun TerminalKeyStrip(enabled: Boolean, modifier: Modifier = Modifier, onKey: (String) -> Unit) {
    Row(modifier.fillMaxWidth().background(Surface).horizontalScroll(rememberScrollState()).padding(5.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        listOf("Enter" to "\r", "Esc" to "\u001b", "Tab" to "\t", "Ctrl C" to "\u0003", "↑" to "\u001b[A", "↓" to "\u001b[B", "←" to "\u001b[D", "→" to "\u001b[C").forEach { (label, bytes) ->
            TextButton(onClick = { onKey(bytes) }, enabled = enabled, shape = RectangleShape,
                modifier = Modifier.sizeIn(minWidth = 44.dp, minHeight = 44.dp)) {
                Text(label, fontFamily = FontFamily.Monospace, fontSize = 13.sp)
            }
        }
    }
}


private fun terminalColor(hex: String): Color? = if (Regex("#[0-9a-fA-F]{6}").matches(hex)) Color(0xff000000L or hex.drop(1).toLong(16)) else null
@Composable private fun terminalText(snapshot: NativeTerminalSnapshot?, localDraft: String = "", showCursor: Boolean = false): AnnotatedString {
    val defaultInk = Ink
    return buildAnnotatedString {
        if (snapshot == null) return@buildAnnotatedString
        val runs = snapshot.styledRuns.ifEmpty { listOf(NativeTerminalRun(snapshot.content, "", "", false, false, false, false)) }
        runs.forEach { run ->
            val start = length
            append(run.text)
            val foreground = terminalColor(run.foreground) ?: defaultInk
            addStyle(SpanStyle(color = if (run.dim) foreground.copy(alpha = 0.7f) else foreground,
                background = terminalColor(run.background) ?: Color.Unspecified,
                fontWeight = if (run.bold) FontWeight.Bold else FontWeight.Normal,
                fontStyle = if (run.italic) FontStyle.Italic else FontStyle.Normal,
                textDecoration = if (run.underline) TextDecoration.Underline else TextDecoration.None), start, length)
            var index = 0
            while (index < run.text.length) {
                val code = run.text.codePointAt(index)
                val size = Character.charCount(code)
                if (code in 0xe5fa..0xe6b7 || code in 0xe700..0xe8ef || code in 0xf000..0xf2e0 || code in 0xf400..0xf533 || code in 0xf0001..0xf1af0) {
                    addStyle(SpanStyle(fontFamily = FontFamily(Font(R.font.terminal_icons))), start + index, start + index + size)
                }
                index += size
            }
        }
        if (localDraft.isNotEmpty()) {
            val start = length
            append(localDraft)
            addStyle(SpanStyle(color = defaultInk), start, length)
        }
        if (showCursor) {
            val start = length
            append("▌")
            addStyle(SpanStyle(color = Green), start, length)
        }
    }

}

@Composable
private fun SubagentReader(childId: String, model: ZedLinkViewModel, dismiss: () -> Unit) {
    val child = model.state.snapshot?.subagents?.firstOrNull { it.id == childId }
    val list = rememberLazyListState()
    var following by remember(childId) { mutableStateOf(true) }
    LaunchedEffect(list) { snapshotFlow { list.isScrollInProgress to list.canScrollForward }.collect { (scrolling, canScroll) -> if (scrolling) following = !canScroll } }
    LaunchedEffect(child?.entries, following) { if (following && list.layoutInfo.totalItemsCount > 0) list.scrollToItem(list.layoutInfo.totalItemsCount - 1) }
    Dialog(onDismissRequest = dismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(Modifier.fillMaxSize().background(Black).windowInsetsPadding(WindowInsets.safeDrawing)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = dismiss) { Text("← Back") }
                Text(child?.title ?: "Agent unavailable", modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(child?.status.orEmpty(), color = Muted, style = monoLabel())
            }
            HorizontalDivider(color = Line)
            if (child != null) {
                LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list) {
                    if (child.entryStartIndex > 0 && "thread.history" in model.state.capabilities) item("history") {
                        TextButton(enabled = !model.loadingChildHistory, onClick = { following = false; model.loadEarlierSubagent(child.id) }) { Text(if (model.loadingChildHistory) "Loading…" else "Load earlier activity") }
                    } else if (child.entriesTruncated) item("truncated") { Text("Earlier activity requires an updated desktop bridge.", color = Muted, modifier = Modifier.padding(16.dp)) }
                    itemsIndexed(child.entries, key = { index, _ -> child.entryStartIndex + index }) { index, markdown ->
                        Message(NativeEntry.parse(markdown), child.isActive && index == child.entries.lastIndex)
                    }
                    items(model.state.snapshot?.approvals?.filter { it.subagentId == childId }.orEmpty(), key = { "approval:${it.subagentId}:${it.turnId}:${it.id}" }) { ApprovalCard(it, model::respondApproval) }
                    if (child.entries.isEmpty()) item("waiting") { Text("Waiting for the first activity…", color = Muted, modifier = Modifier.padding(16.dp)) }
                }
                if (!following) TextButton(onClick = { following = true }, modifier = Modifier.fillMaxWidth()) { Text("Latest ↓") }
                HorizontalDivider(color = Line)
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton(onClick = { model.setDraft("Use the native spawn_agent tool with session_id \"${child.id}\" to continue this existing child agent. Return its result in this conversation:\n\nTask: "); dismiss() }) { Text("Continue agent") }
                    if (child.currentTurnId != null && "subagent.cancel" in model.state.capabilities) TextButton(onClick = { model.cancelSubagent(child) }) { Text("Stop agent", color = Warning) }
                }
            } else Spacer(Modifier.weight(1f))
        }
    }
}
