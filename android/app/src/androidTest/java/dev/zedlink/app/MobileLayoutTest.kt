package dev.zedlink.app

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class MobileLayoutTest {
    @get:Rule val compose = createComposeRule()

    @Test fun changesShortcutOpensFileReviewFixture() {
        val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        val application = instrumentation.targetContext.applicationContext as android.app.Application
        // Presentation fixture only; it must not use an existing paired device.
        org.junit.Assume.assumeTrue(application.getSharedPreferences("zedlink-profile", 0).all.isEmpty())
        val store = androidx.lifecycle.ViewModelStore()
        lateinit var model: ZedLinkViewModel
        compose.runOnIdle { model = ZedLinkViewModel(application); store.put("changes-fixture", model) }
        val fixture = AppState(live = true, selectedThreadId = "fixture", instanceId = "fixture", epoch = "fixture",
            changes = listOf(NativeChange("src/example.kt", "modified", "unstaged")), changesRevision = "fixture",
            previewTitle = "Working tree diff",
            previewContent = "diff --git a/src/example.kt b/src/example.kt\n--- a/src/example.kt\n+++ b/src/example.kt\n-old\n+new\n")
        try {
            compose.setContent { ZedLinkTheme("dark") { ProjectContextScreen(fixture, model, initialPage = "Changes") {} } }
            compose.onNodeWithText("GIT CHANGES · 1 FILE").assertIsDisplayed()
            compose.onNodeWithText("src/example.kt").assertIsDisplayed()
            compose.onNodeWithText("+1  −1 in loaded diff").assertIsDisplayed()
        } finally {
            compose.runOnIdle { store.clear() }
        }
    }

    @Test fun actualWorkspaceKeepsTypedDraftVisibleWithSoftwareKeyboard() {
        val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        val application = instrumentation.targetContext.applicationContext as android.app.Application
        // Run only in an unpaired disposable install. Never connect to a user's gateway.
        org.junit.Assume.assumeTrue(application.getSharedPreferences("zedlink-profile", 0).all.isEmpty())
        val store = androidx.lifecycle.ViewModelStore()
        lateinit var model: ZedLinkViewModel
        compose.runOnIdle { model = ZedLinkViewModel(application); store.put("fixture", model) }
        val terminal = NativeTerminal("keyboard-fixture", "Disposable terminal", null, null, null)
        val fixture = AppState(live = true, selectedThreadId = "fixture", instanceId = "fixture", epoch = "fixture",
            capabilities = setOf("terminal.list", "terminal.input"), terminals = listOf(terminal),
            terminalSnapshot = NativeTerminalSnapshot(terminal,
                "UI fixture only — no native transport\n" + "file.txt    directory/\n".repeat(40), false))
        val automation = instrumentation.uiAutomation
        val previousFlags = automation.serviceInfo.flags
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        }
        try {
            compose.setContent {
                val activity = androidx.activity.compose.LocalActivity.current!!
                androidx.compose.runtime.SideEffect {
                    androidx.core.view.WindowCompat.setDecorFitsSystemWindows(activity.window, false)
                    activity.window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
                }
                ZedLinkTheme("dark") { ProjectContextScreen(fixture, model) {} }
            }
            val field = compose.onNode(hasSetTextAction())
            field.assertIsDisplayed()
            compose.onNodeWithContentDescription("Type directly in terminal").assertIsDisplayed()
            compose.onNodeWithContentDescription("Type in terminal").performClick()
            field.assertIsFocused().performTextInput("printf visible-draft")
            field.assertTextContains("printf visible-draft").assertIsDisplayed()
            compose.onNodeWithTag("terminal-output").assertTextContains("printf visible-draft", substring = true).assertIsDisplayed()
            compose.waitUntil(timeoutMillis = 5000) {
                automation.windows.any { it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            }
            val keyboardBounds = android.graphics.Rect()
            automation.windows.first { it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD }
                .getBoundsInScreen(keyboardBounds)
            val applicationBounds = android.graphics.Rect()
            automation.windows.first { it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_APPLICATION && it.isFocused }
                .getBoundsInScreen(applicationBounds)
            val fieldBounds = field.fetchSemanticsNode().boundsInWindow
            assertTrue("Command field must fit above the visible keyboard",
                fieldBounds.bottom + applicationBounds.top <= keyboardBounds.top + 1)
            compose.waitForIdle()
            val bitmap = instrumentation.uiAutomation.takeScreenshot()
            assertNotNull(bitmap)
            val output = java.io.File(application.getExternalFilesDir(null), "terminal-keyboard-fixture.png")
            output.outputStream().use { bitmap!!.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            bitmap?.recycle()
        } finally {
            automation.serviceInfo = automation.serviceInfo.apply { flags = previousFlags }
            compose.runOnIdle { store.clear() }
        }
    }

    @Test fun tappingTerminalFocusesKeyboardCapture() {
        compose.setContent {
            val requester = remember { FocusRequester() }
            ZedLinkTheme("dark") {
                Surface {
                    Column(Modifier.width(320.dp).height(360.dp)) {
                        Box(Modifier.weight(1f)) {
                            TerminalOutput(AnnotatedString("Disposable terminal prompt $"), rememberScrollState(),
                                rememberScrollState(), true, true) { requester.requestFocus() }
                        }
                        TerminalKeyStrip(true) {}
                        BasicTextField("", {}, Modifier.focusRequester(requester).height(48.dp).testTag("terminal-input"))
                    }
                }
            }
        }
        compose.onNodeWithTag("terminal-input").assertIsDisplayed().assertIsNotFocused()
        compose.onNodeWithText("Disposable terminal prompt $").performClick()
        compose.onNodeWithTag("terminal-input").assertIsFocused()
    }

    @Test fun longSessionTitleWrapsAtLargeTextAndPinDoesNotOpenConversation() {
        val title = "Review the disposable project configuration and explain the remaining changes across mobile clients"
        var opened = 0
        var pinned = 0
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 1.5f)) {
                ZedLinkTheme("light") {
                    Surface(Modifier.width(320.dp)) {
                        Column {
                            ThreadRow(NativeThread("fixture", title, "generating", 1), true, false, true,
                                { pinned++ }, { opened++ })
                        }
                    }
                }
            }
        }
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(title, useUnmergedTree = true)
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertTrue(layouts.single().lineCount > 2)
        assertFalse(layouts.single().hasVisualOverflow)
        compose.onNodeWithContentDescription("Pin session").performClick()
        compose.runOnIdle { assertEquals(1, pinned); assertEquals(0, opened) }
        compose.onNodeWithText(title).performClick()
        compose.runOnIdle { assertEquals(1, opened) }
    }

    @Test fun dismissedNoticeReturnsForNewError() {
        val issue = mutableStateOf("The requested desktop action is unavailable.")
        compose.setContent { ZedLinkTheme("dark") { Surface { Notice(issue.value) } } }
        compose.onNodeWithText(issue.value).assertIsDisplayed()
        compose.onNodeWithContentDescription("Dismiss notice").performClick()
        compose.onNodeWithText(issue.value).assertDoesNotExist()
        compose.runOnIdle { issue.value = "Connection interrupted. Reconnect to continue." }
        compose.onNodeWithText(issue.value).assertIsDisplayed()
    }

    @Test fun terminalKeysRespectInputAvailabilityAndEmitControlBytes() {
        val available = mutableStateOf(false)
        val sent = mutableListOf<String>()
        compose.setContent { ZedLinkTheme("light") { Surface { TerminalKeyStrip(available.value) { sent += it } } } }
        compose.onNodeWithText("Ctrl C").assertIsNotEnabled()
        compose.onNodeWithText("Tab").assertIsNotEnabled()
        compose.runOnIdle { assertTrue(sent.isEmpty()); available.value = true }
        compose.onNodeWithText("Ctrl C").assertIsEnabled().performClick()
        compose.onNodeWithText("Tab").performClick()
        compose.runOnIdle { assertEquals(listOf("\u0003", "\t"), sent) }
    }
}
