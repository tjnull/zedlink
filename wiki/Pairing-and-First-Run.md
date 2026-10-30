# Pairing and First Run

[← Wiki home](README.md)

Complete installation and connection configuration first. Pairing codes and QR links are short-lived credentials; do not post them in screenshots or issue reports.

## 1. Start patched Zed

Open **ZedLink — Patched Zed**. Verify that the intended project, Agent conversation, and model are visible. If `/remote-control` is absent, you opened stock Zed or an outdated patched build.

## 2. Expose one conversation

In the Agent panel:

1. open the conversation you want to continue remotely;
2. focus the message composer;
3. type `/remote-control`; and
4. choose **Remote Control** from the command list.

Zed confirms that the thread is exposed locally. Run `/remote-control` again to stop exposure. Enabling ZedLink does not expose every thread, and restarting patched Zed requires you to expose the desired thread again.

## 3. Start the gateway

Use **Settings → ZedLink → Gateway Control → Start**, or run **ZedLink: Start gateway** from the task picker. Keep patched Zed and the gateway running while using a remote client.

Run **ZedLink: Status**. A ready setup reports the native bridge and gateway online and shows the intended connection profile.

## 4. Create a one-time pairing challenge

Open **Settings → ZedLink → Paired Devices** and choose one of these options:

- **Open Browser QR** shows the private pairing page on the workstation.
- **Show Terminal QR** opens a local Zed terminal and prints a scan-ready QR, HTTPS address, gateway identity, manual code, and expiration.
- **Review Devices** lists credentials that were already issued. It does not show a new pairing challenge. Do not revoke a device to troubleshoot a hostname or Tailscale DNS failure.

The browser pairing page shows the current HTTPS address and gateway identity beside the QR. Compare that address with the phone's saved ZedLink connection. If Safari says “Server cannot be found” for the hostname but reaches a certificate warning for the workstation's Tailscale IP at the same port, the private route and TLS listener are reachable; stop at the warning and troubleshoot name resolution. The IP address is not a replacement saved endpoint because its certificate is issued for the hostname.

The terminal path does not open a browser. From a shell, the equivalent primary-route command is:

```sh
python3 tools/zedlink_manager.py pair-primary-terminal
```

Use `pair-terminal` when you need to choose another configured route. Enlarge a very small terminal before regenerating the QR. The challenge remains active for five minutes, can be used once, and allows at most five attempts.

## 5. Pair a browser or installed web app

1. Connect the phone or computer to the configured private network.
2. Open the trusted HTTPS pairing link or scan the QR.
3. Compare the HTTPS address and gateway identity with the workstation.
4. Enter the manual code when prompted and confirm the gateway.
5. Finish pairing and select the exposed session.

On iPhone or iPad, open the page in Safari and use **Share → Add to Home Screen** for the installed web app. If the app is already installed, keep it open and enter the code there; iOS may otherwise send a scanned link to the default browser.

Normal browser storage preserves the authorization for that exact HTTPS origin. Private browsing, origin changes, or clearing site data can require pairing again.

## 6. Pair a native app

In iOS or Android:

1. open **Connections** and choose **Add**;
2. scan the workstation QR or paste the pairing link;
3. test the HTTPS endpoint and verify the gateway identity;
4. enter a device name and the one-time code if needed; and
5. choose **Pair and save**.

Each HTTPS route is stored separately. Routes that point to the same gateway can reuse its credential after identity verification. Ping alone is insufficient: the phone must resolve the hostname, reach the port, and trust the certificate.

## 7. Prove the same-thread round trip

Use a disposable test conversation:

1. send a short message from the remote client;
2. confirm it appears in the same desktop Zed conversation;
3. wait for the response and confirm it appears on both clients;
4. send a desktop message and verify the remote transcript updates; and
5. stop exposure, refresh the remote client, and confirm the thread is no longer available.

This test proves the selected route and thread. It does not prove every permission, model, terminal, notification, or background-delivery path.

## Creating a session remotely

When the bridge advertises session creation and the permission is enabled, choose **+ New** from Sessions. Select an advertised Agent, optionally enter a title, and create the session. It is created inside the configured Zed project and exposed automatically.

The remote client cannot silently choose another worktree, model provider, credential, or tool policy.

## Notifications

Browser notifications require permission and a configured Web Push path. Native iOS/Android local alerts depend on the app receiving live updates; APNs and FCM background delivery are not configured. See [Mobile apps](Mobile-Apps.md#notifications-and-apple-watch) for the current boundary.

Continue with the [User guide](User-Guide.md).
