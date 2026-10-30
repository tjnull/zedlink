# Mobile Apps

[← Wiki home](README.md)

The SwiftUI and Jetpack Compose apps are native clients for the same ZedLink gateway. They do not contain an LLM runtime or model credentials.

The [UI assessment below](#ui-assessment-of-zed-mobile) compares ZedLink with another Zed Android companion. The source implementation status and remaining device gates are recorded beneath it.

## Release status

| Client | Install path | Current boundary |
| --- | --- | --- |
| Browser / PWA | Open the trusted HTTPS origin; optionally add it to the home screen | Most complete and easiest path |
| iOS | Build and sign locally with macOS and Xcode | Source available; wider simulator and physical-device coverage pending |
| Android | Build a development APK with JDK 17, Android SDK, and Gradle | Source available; terminal and speech reports still need physical-device validation |

There is no documented stable App Store or Play Store release. Treat native packages as development builds.

## Build iOS

You need macOS, Xcode, XcodeGen, a signing team, and a simulator or physical device. From the repository root:

```sh
bash tools/test_ios_local.sh build
```

Open the generated `ZedLink` project/scheme in Xcode, select your team and device, then build and run. Use a disposable Zed project and test pairing for UI tests. Do not point automated tests at an active personal conversation.

Before sharing a build, verify on a physical phone:

- pairing, reconnect, and route switching;
- transcript restoration and live updates;
- keyboard and safe-area layout in portrait and landscape;
- files, changes, terminal selection/creation/input, tasks, and debugger views;
- approvals, Stop, uncertain-delivery recovery, and stale request rejection;
- image selection/annotation, clipboard, dictation, and accessibility; and
- notification behavior while foregrounded, backgrounded, and terminated.

## Build Android

Use an existing JDK 17, Android SDK, and Gradle 8.10.2. Keep caches on disk outside the repository. From the repository root:

```sh
gradle -p android --no-daemon :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

The debug APK is written to:

```text
android/app/build/outputs/apk/debug/app-debug.apk
```

Install it on a disposable test device:

```sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

Android rejects an update signed by a different key. Uninstalling clears app data and requires pairing again.

Every Android UI change must increment version/build metadata. When reporting a problem, copy **Settings → Help & about → Version, build, and interface revision**. The current source declares version **0.2.16 (18)** and interface revision **2026.10.30.2**; that identifies source metadata, not a verified installed APK.

## Pairing

1. Keep patched Zed and the gateway running.
2. Connect the phone to the configured private route.
3. Verify the gateway HTTPS origin loads without a certificate warning.
4. Expose the intended conversation with `/remote-control` in desktop Zed.
5. In **Connections → Add**, scan or paste the pairing link.
6. Test HTTPS, compare the gateway identity, then pair and save.

Camera scanning must produce a reviewable connection draft before a network request. If scanning returns to Sessions, use **Paste pairing link**, record the app version, and include the exact route type in the issue.

## Workspace and terminal behavior

Both native apps expose capability-gated Files, Changes, Terminal, Tasks, Debug, and Activity views. Files are listed one entry per row and stay inside the exposed worktree.

The terminal selects or creates native Zed project terminals. Mobile input remains editable and visible before Return, then the authoritative Zed terminal refresh confirms delivery. Switch terminals by tapping the title. The native PTY is resized to the visible phone grid before subsequent commands so new directory listings fit the screen more naturally.

Terminal output is a bounded styled snapshot. Full-screen terminal applications, mouse input, exact cursor projection, and every custom font glyph are not established as fully supported.

## Dictation and clipboard

Dictation fills an editable draft and never sends automatically. Android provides the device speech popup and an explicit in-app path. Microphone permission alone does not guarantee that the installed speech service can record or transcribe; Android's global microphone control, speech-provider permission, language support, and provider health also matter.

An Android physical-device report of **unable to record audio** remains unresolved. Capture the exact popup text, Android version, device, speech provider, and app metadata. Test both the device popup and in-app option without exposing private transcript content.

Image paste and selection open an annotation review with freehand drawing, Undo, and Clear. Text clipboard actions show a preview. Neither path automatically submits content.

## Notifications and Apple Watch

iOS and Android local Agent alerts can cover approvals, request failures, observed native turn completion or cancellation, pending input, and context compaction while each app receives updates. Android source 0.2.16 (18) retains adaptive Material 3 navigation and a compact composer; the preceding update added loaded-conversation search and an unread count when following is paused. Apple Watch can mirror eligible iPhone notifications through the operating system.

To check mirroring:

1. enable ZedLink notifications on iPhone;
2. open **Settings → Notifications** in ZedLink and schedule the test notification;
3. lock the iPhone and keep the paired watch unlocked and on your wrist; and
4. check **Watch app → Notifications → ZedLink** if it remains on the phone.

The operating system chooses whether an alert appears on iPhone or Watch. ZedLink does not include a dedicated watch app. APNs and FCM background push are not configured, so native local alerts cannot be relied on after the app is suspended or terminated.

## Device test report

Include:

- app version, build, and interface revision;
- phone model and OS version;
- gateway and patched-Zed revisions without private addresses;
- exact steps, expected result, and actual result;
- whether the same action works in the phone browser; and
- a redacted screenshot or exact error text.

Remove pairing codes, device tokens, private hostnames, IP addresses, certificate details, project names, and transcript content before posting.

## UI assessment of zed-mobile

Reviewed [piumalnipun9/zed-mobile at `5028e465`](https://github.com/piumalnipun9/zed-mobile/tree/5028e4652f2ff022b8bd12458020f7e5ed48f947) on 2026-10-30. Its [demo](https://github.com/piumalnipun9/zed-mobile/blob/5028e4652f2ff022b8bd12458020f7e5ed48f947/docs/demo.gif) and Compose source show a connected-desktop card, recent threads and project groups on one home screen, a prominent New thread action, and a compact chat with inline tool steps, plans, questions, and approval choices. An offscreen approval has a jump control. Changes has a dedicated file-review page. The demo and fixed-state screenshot tests show presentation; they do not prove a live Zed round trip. No source or artwork was copied.

The reference uses its own desktop fork and Android protocol. Its project catalog can open recently used projects and its Changes page can Keep/Reject edits. ZedLink has a different exposure policy and Git Stage/Unstage contract, so those operations cannot be imported as UI-only changes.

| Priority | ZedLink today | Proposed improvement | Required boundary |
| --- | --- | --- | --- |
| 1 | Android appends approvals and input requests after transcript entries; iOS shows them in separate stacks. | Place each pending decision beside its matching native tool or question entry. Add a compact **Review pending action** jump control when it is offscreen. | Fall back to a review section for paged-out entries. Preserve exact IDs/options, full decisive arguments, stale-state checks, and native permission behavior. Validate approval races and replay. |
| 2 | Sessions already has search, attention/running groups, and connection status; New session is a small toolbar `+`. | Add **Recent exposed sessions** and a clearly labeled **New session** action, including in the empty state. Show the selected gateway/target/project on each relevant row. | Recents are local display ordering only. Never reveal or open an unexposed project or thread. Keep creation capability-gated. |
| 3 | Changes is nested in Workspace, with bounded diff and Stage/Unstage. | Add a direct conversation shortcut to Changes and a clearer file list with line counts, per-file diff navigation, and truncated-diff labels. | Stage/Unstage must not be relabeled Keep/Reject. Native edit acceptance needs a separately verified, revision-guarded adapter path. |
| 4 | Agent/model settings are in session actions. The composer has limited space. | Show a compact, authoritative agent/model indicator near the composer that opens existing settings when supported. | Keep Send/Stop, attachments, and keyboard-safe layout usable at narrow widths. Do not infer provider health from Idle. |
| 5 | Both apps already pause auto-follow and offer Latest; iOS coalesces scroll updates. | Refine initial positioning and long-stream reading, then compare screenshots for empty, working, approval, question, offline, and long-content states. | Test real paged history and streaming, plus large text, VoiceOver/TalkBack, keyboard and landscape. Label all mock captures. |

Keep ZedLink's platform-native tabs/rail and its light/dark themes. The reference's drawer and mascot are not needed to gain its useful task flow. Keep profile-based HTTPS, pairing, and explicit thread exposure. A shared Kotlin UI rewrite would be separate work; these interaction improvements can be made in the existing SwiftUI and Compose clients.

### Implementation status, 2026-10-30

Both source clients now place root approvals and input requests beside their matching native transcript entries when the patched bridge supplies IDs. Older or paged-out entries use a review section. A pending-action jump control, recent exposed sessions, a labeled New Agent session action, direct Changes access, a file list, and an agent/model label are in source. iOS uses its existing diff file navigation; Android can select a file from the Changes list and shows additions/removals in the loaded diff. Counts describe only the loaded diff, which may be truncated. The session list still shows the selected gateway and target in its header; a per-row project label is not yet supported by the thread summary. A source audit restored the iOS Recently opened row's accessible thread identifier and added opt-in disposable-thread navigation checks for direct Changes and the recent row.

This source has not been compiled or exercised on a physical phone in the current environment. Permission races, replay, paged history, long streaming, accessibility, and home Wi-Fi routing remain to be validated under [TEST_PLAN.md](../docs/TEST_PLAN.md). Android source metadata is 0.2.16 (18), UI revision 2026.10.30.2. No hosted Actions were dispatched.

For the reported route failure with Tailscale connected, the owner initially observed browser/app failure on home Wi-Fi with earlier cellular success. Safari briefly said **“Server cannot be found”** for the same saved `/v1/gateway` URL on both home Wi-Fi and cellular. The saved hostname matches the workstation's current pairing address, and the workstation appears online in the iPhone Tailscale app. **Use Tailscale DNS settings** is enabled; home Wi-Fi DNS is Automatic, no separate DNS app/profile is reported, and iCloud Private Relay is off. Safari reached a certificate warning at the workstation's Tailscale IP and HTTPS port; the owner did not bypass it. That demonstrates private-route and TLS-port reachability for that test. The workstation reports MagicDNS enabled, and its Tailscale hostname matches the enabled route. After refreshing the iPhone's Tailscale DNS preference and tunnel, the normal hostname returned gateway JSON on cellular but still failed on home Wi-Fi. The later home Wi-Fi test below established a timeout by hostname and raw Tailscale IP. [Tailscale says MagicDNS resolves inside the client and bypasses router DNS rebinding filters](https://tailscale.com/docs/reference/faq/dns-rebinding). Do not save the raw IP as a profile or bypass its certificate warning.

The desktop **Review Devices** list is for existing credentials and revocation; **Open Browser QR** shows the current address, gateway identity, and one-time pairing code. The source Settings list is now paged and disambiguates same-name devices by ID suffix, pending a rebuilt patched Zed app. The workstation gateway and one patched Zed target were online at the later host check. Use **Connections → Check connection** on iPhone or **Connections → saved route → Check HTTPS and identity** on Android after hostname resolution works.

The later home Wi-Fi check (cellular off) showed timeout by both hostname and raw Tailscale IP. Host discovery ping to the iPhone worked, but WireGuard-level TSMP failed. A workstation Tailscale socket rebind restored TSMP. The failure had shifted from the earlier DNS symptom to an intermittent home Wi-Fi private path.
After the rebind, Safari loaded the `/v1/gateway` JSON and the native iOS app connected, but the app later dropped Offline and the WireGuard-level failure recurred while the gateway and patched Zed target stayed online. The owner switched the VMware guest from NAT to **Bridged**; its Ethernet address is now on the home LAN. The owner reported the gateway visible, the iOS connection **Live**, and the intended exposed native Agent conversation open with its latest desktop messages. The enabled Tailscale HTTPS route still passes trusted TLS and gateway identity checks. Sustained stability and a new same-thread Agent turn for this build remain unverified; the exact packet-loss mechanism was not isolated.

The iOS source now retries transient private-route failures while foregrounded, with bounded backoff; it does not switch endpoints or replay turns. This change is not in the installed app yet. A separate direct home-LAN profile is supported by the existing iOS and Android connection models, but the gateway still needs a LAN listener and a certificate trusted for a LAN hostname or IP. The current Tailscale certificate cannot validate an unrelated local address. Keep the Tailscale profile for away-from-home use and explicitly select the Local HTTPS profile at home after checking that both show the same gateway identity. No local HTTPS listener or phone trust has been configured yet. Do not save the raw Tailscale IP as an endpoint or bypass its certificate warning.
