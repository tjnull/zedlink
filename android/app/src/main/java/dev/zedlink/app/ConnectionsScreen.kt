package dev.zedlink.app

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.border
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch

/** Pairing codes are memory-only and never stored in preferences or logs. */
data class ConnectionDraft(
    val name: String = "Desktop", val endpoint: String = "", val gateway: String = "",
    val code: String = "", val device: String = "Android phone", val route: String = "Private HTTPS",
    val id: String = java.util.UUID.randomUUID().toString(), val editing: Boolean = false,
) {
    fun profile() = ConnectionProfile(name.trim(), endpoint.trim(), gateway.trim().lowercase(), id, route)
    companion object {
        fun edit(profile: ConnectionProfile) = ConnectionDraft(name = profile.name, endpoint = profile.endpoint,
            gateway = profile.gatewayId, route = profile.route, id = profile.id, editing = true)
    }
}

@Composable internal fun ConnectionsScreen(state: AppState, model: ZedLinkViewModel) {
    var adding by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(model.pairingImportRevision) { if (model.pairingImportPending) { adding = true; model.pairingImportPending = false } }
    var selected by remember { mutableStateOf<String?>(null) }
    if (adding) ConnectionEditor(state, model, model.pairingDraft, { model.pairingDraft = it }, { adding = false })
    selected?.let { id -> state.profiles.firstOrNull { it.id == id }?.let { profile ->
        ConnectionDetail(state, model, profile) { selected = null }
    } }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("Connections", "") {
            IconButton(onClick = { adding = true }, enabled = !state.connectionBusy && !state.connecting) { Icon(Icons.Default.Add, "Add connection", tint = Ink) }
        }
        Column(Modifier.padding(horizontal = 16.dp)) {
            ConnectionSection("Saved connections")
            if (state.profiles.isEmpty()) {
                Text("No connections", fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(vertical = 8.dp))
                Text("Add your workstation using its private pairing QR or link.", color = Muted)
                TextButton(onClick = { adding = true }) { Text("Add connection") }
            }
            state.profiles.forEach { profile ->
                val active = state.profile?.id == profile.id
                val shape = RoundedCornerShape(16.dp)
                Row(Modifier.fillMaxWidth().padding(vertical = 5.dp).clip(shape).background(Surface)
                    .border(1.dp, if (active) Blue.copy(alpha = 0.45f) else Line, shape)
                    .clickable { selected = profile.id }.padding(horizontal = 14.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(profile.name, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                            Text(if (active) state.status else "Saved", color = if (active && state.live) Green else Muted, fontSize = 11.sp, modifier = Modifier.widthIn(max = 140.dp))
                        }
                        Text(profile.route, color = Muted, fontSize = 12.sp)
                        Text(profile.endpoint, color = Muted, fontSize = 12.sp, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                    }
                    Icon(Icons.Default.ChevronRight, "Connection details", tint = Muted, modifier = Modifier.padding(start = 8.dp).size(18.dp))
                }
            }
            state.profile?.let { profile ->
                ConnectionSection("Workspaces · ${profile.name}")
                if (state.targets.isEmpty()) Text("Connect to load workspaces.", color = Muted)
                state.targets.forEach { target ->
                    val canSwitch = (state.live || state.targetId == null) && target.available && target.id != state.targetId && !state.connectionBusy && !state.connecting
                    val shape = RoundedCornerShape(14.dp)
                    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp).heightIn(min = 56.dp).clip(shape).background(Surface)
                        .clickable(enabled = canSwitch) { model.selectTarget(target.id) }.padding(horizontal = 14.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(target.label)
                            Text((if (state.live) "" else "Last known · ") + if (target.available) "Available" else "Unavailable", color = Muted, fontSize = 12.sp)
                        }
                        Icon(if (target.id == state.targetId) Icons.Default.Check else Icons.Default.ChevronRight,
                            if (target.id == state.targetId) "Selected workspace" else "Switch workspace",
                            tint = if (target.id == state.targetId) Blue else Muted, modifier = Modifier.size(20.dp))
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable private fun ConnectionDetail(state: AppState, model: ZedLinkViewModel, profile: ConnectionProfile, close: () -> Unit) {
    var editing by remember { mutableStateOf(false) }
    var draft by remember(profile.id) { mutableStateOf(ConnectionDraft.edit(profile)) }
    var removing by remember { mutableStateOf(false) }
    var identity by remember { mutableStateOf(false) }
    var checkingHTTPS by remember(profile.id) { mutableStateOf(false) }
    var httpsResult by remember(profile.id) { mutableStateOf("") }
    val checkScope = rememberCoroutineScope()
    if (editing) ConnectionEditor(state, model, draft, { draft = it }, { editing = false })
    if (removing) AlertDialog(onDismissRequest = { removing = false }, title = { Text("Remove saved connection?") }, text = {
        val linked = state.profiles.any { it.id != profile.id && it.gatewayId.equals(profile.gatewayId, true) }
        Text(if (linked) "Only this address is removed. Other addresses retain the shared gateway credential. Remote access is not revoked."
            else "This removes the saved address and its local credential. Pair again to reconnect. Remote access is not revoked; revoke the device separately on the workstation.")
    }, confirmButton = { TextButton(onClick = { model.removeConnection(profile); close() }) { Text("Remove", color = MaterialTheme.colorScheme.error) } }, dismissButton = { TextButton(onClick = { removing = false }) { Text("Cancel") } })
    ConnectionPage("Connection details", close) {
        Text(profile.name, fontWeight = FontWeight.SemiBold)
        Text(profile.route, color = Muted)
        if (state.profile?.id == profile.id) {
            Text(state.status)
            if (state.issue.isNotBlank()) Text(state.issue, color = MaterialTheme.colorScheme.error)
        } else Text("Saved · status not checked", color = Muted)
        TextButton(onClick = { model.connect(profile) }, enabled = !state.connecting && !state.connectionBusy) { Text(if (state.profile?.id == profile.id) "Reconnect" else "Connect") }
        TextButton(onClick = {
            checkingHTTPS = true; httpsResult = ""
            checkScope.launch {
                try {
                    val observed = GatewayClient(profile, null).gatewayId()
                    httpsResult = if (observed.equals(profile.gatewayId, true)) "HTTPS route and gateway identity verified now."
                        else "HTTPS reached a different gateway identity. Review this saved address."
                } catch (error: Exception) { httpsResult = connectionFailure(error) }
                finally { checkingHTTPS = false }
            }
        }, enabled = !checkingHTTPS) { Text(if (checkingHTTPS) "Checking HTTPS…" else "Check HTTPS and identity") }
        if (httpsResult.isNotBlank()) Text(httpsResult, color = if (httpsResult.startsWith("HTTPS route")) Muted else MaterialTheme.colorScheme.error, fontSize = 12.sp)
        TextButton(onClick = { draft = ConnectionDraft.edit(profile); editing = true }, enabled = !state.connecting && !state.connectionBusy) { Text("Edit connection") }
        TextButton(onClick = { identity = !identity }) { Text(if (identity) "Hide address & identity" else "Address & identity") }
        if (identity) {
            Text(profile.endpoint)
            Text(profile.gatewayId, color = Muted, fontSize = 12.sp)
            Text("HTTPS and gateway identity are checked before the credential is sent. Manage remote permissions in desktop Zed.", color = Muted, fontSize = 12.sp)
        }
        TextButton(onClick = { removing = true }, enabled = !state.connecting && !state.connectionBusy) { Text("Remove saved connection", color = MaterialTheme.colorScheme.error) }
    }
}

@Composable private fun ConnectionEditor(state: AppState, model: ZedLinkViewModel, draft: ConnectionDraft, change: (ConnectionDraft) -> Unit, close: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    val activity = androidx.activity.compose.LocalActivity.current as? MainActivity
    var observed by remember { mutableStateOf("") }
    var tested by remember { mutableStateOf<ConnectionProfile?>(null) }
    var issue by remember { mutableStateOf("") }
    var testing by remember { mutableStateOf(false) }
    var advanced by remember { mutableStateOf(false) }
    val latest by rememberUpdatedState(draft)
    val scope = rememberCoroutineScope()
    val busy = testing || model.pairingScanInFlight || state.connectionBusy || state.connecting
    fun applyLink(value: String) {
        runCatching { ConnectionLinks.parse(value) }.onSuccess { (profile, code) ->
            model.clearPairingScanIssue()
            change(latest.copy(endpoint = profile.endpoint, gateway = profile.gatewayId, code = code.orEmpty()))
            observed = ""; tested = null; issue = "Pairing link loaded. Test HTTPS before continuing."
        }.onFailure { issue = it.message ?: "Pairing link could not be read." }
    }
    ConnectionPage(if (draft.editing) "Edit connection" else "Add connection", { if (!busy) close() }) {
        if (!draft.editing) {
            TextButton(onClick = { activity?.scanPairingQR() }, enabled = !busy && activity != null) { Text("Scan workstation QR") }
            TextButton(onClick = { applyLink(clipboard.getText()?.text.orEmpty()) }, enabled = !busy) { Text("Paste pairing link") }
        }
        OutlinedTextField(draft.name, { change(draft.copy(name = it)) }, label = { Text("Name") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
        var routeMenu by remember { mutableStateOf(false) }
        Box {
            TextButton(onClick = { routeMenu = true }, enabled = !busy) { Text("Route · ${draft.route}") }
            DropdownMenu(routeMenu, { routeMenu = false }) {
                listOf("Tailscale", "WireGuard", "Other VPN", "Local HTTPS", "Custom HTTPS", "Private HTTPS").forEach { route ->
                    DropdownMenuItem(text = { Text(route) }, onClick = { change(draft.copy(route = route)); routeMenu = false })
                }
            }
        }
        Text("Connect your private route separately. ZedLink checks HTTPS and pairing; it does not turn your VPN on.", color = Muted, fontSize = 12.sp)
        OutlinedTextField(draft.endpoint, { change(draft.copy(endpoint = it)); observed = ""; tested = null }, label = { Text("HTTPS address") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
        TextButton(onClick = { advanced = !advanced }) { Text(if (advanced) "Hide gateway identity" else "Gateway identity") }
        if (advanced) OutlinedTextField(draft.gateway, { change(draft.copy(gateway = it)); observed = ""; tested = null }, label = { Text("Expected identity from workstation") }, enabled = !busy && !draft.editing, modifier = Modifier.fillMaxWidth())
        TextButton(onClick = {
            val candidate = draft.profile()
            testing = true; issue = ""
            scope.launch {
                try {
                    observed = GatewayClient(candidate, null).gatewayId()
                    tested = candidate
                    issue = if (observed.equals(candidate.gatewayId, true)) "HTTPS and gateway identity verified." else "HTTPS reached, but identity must match the workstation value."
                } catch (error: Exception) { issue = connectionFailure(error) }
                finally { testing = false }
            }
        }, enabled = !busy && draft.endpoint.isNotBlank()) { Text(if (testing) "Checking…" else "Test HTTPS endpoint") }
        if (advanced && observed.isNotBlank()) Text("Observed identity · $observed", fontSize = 12.sp)
        val verified = tested?.endpoint == draft.profile().endpoint && tested?.gatewayId == draft.profile().gatewayId && observed.equals(draft.profile().gatewayId, true) && observed.isNotBlank()
        val paired = state.profiles.any { it.gatewayId.equals(draft.gateway.trim(), true) }
        if (!draft.editing) {
            OutlinedTextField(draft.device, { change(draft.copy(device = it)) }, label = { Text("Device name") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(draft.code, { change(draft.copy(code = it)) }, label = { Text("One-use pairing code") }, visualTransformation = PasswordVisualTransformation(), enabled = !busy, modifier = Modifier.fillMaxWidth())
            TextButton(onClick = { model.pair(draft.profile(), draft.code, draft.device) { saved -> if (saved) { change(ConnectionDraft()); close() } } }, enabled = !busy && verified && draft.name.isNotBlank() && draft.code.isNotBlank()) { Text("Pair and save") }
        }
        if (paired) TextButton(onClick = { model.updateRoute(draft.profile()) { saved -> if (saved) { change(ConnectionDraft()); close() } } }, enabled = !busy && verified && draft.name.isNotBlank()) { Text(if (draft.editing) "Save changes and connect" else "Save another address") }
        if (!draft.editing && model.pairingScanIssue.isNotBlank()) Text(model.pairingScanIssue, color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
        if (issue.isNotBlank()) Text(issue, fontSize = 12.sp)
        if (state.connectionIssue.isNotBlank()) Text(state.connectionIssue, color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
    }
}

@Composable private fun ConnectionSection(title: String) {
    Text(title.uppercase(), color = Muted, fontSize = 10.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
        letterSpacing = 1.sp, modifier = Modifier.padding(top = 16.dp, bottom = 6.dp))
}
@Composable private fun ConnectionPage(title: String, close: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
            Column {
                Row(Modifier.fillMaxWidth().padding(8.dp)) {
                    IconButton(onClick = close) { Icon(Icons.Default.ArrowBack, "Back") }
                    Text(title, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(12.dp))
                }
                HorizontalDivider(color = Line)
                Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).imePadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = content)
            }
        }
    }
}
