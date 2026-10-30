#!/usr/bin/env python3
"""Personal, local-only auto-compaction for explicitly exposed ZedLink threads.

Uses Zed's native /compact command. It never calls a model directly or retries an
uncertain submission. The private state file contains only opaque IDs and counts.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import tempfile
import time
import uuid


def rpc(socket_path, method, params, request_id=None):
    request_id = request_id or str(uuid.uuid4())
    request = {"version": 1, "request_id": request_id, "method": method, "params": params}
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(8)
        connection.connect(str(socket_path))
        connection.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
        with connection.makefile("rb") as reader:
            raw = reader.readline(1024 * 1024 + 1)
    if not raw or len(raw) > 1024 * 1024:
        raise RuntimeError("missing or oversized native response")
    response = json.loads(raw)
    if response.get("version") != 1 or response.get("request_id") != request_id:
        raise RuntimeError("native response envelope mismatch")
    if "error" in response:
        code = response["error"].get("code", "unknown")
        raise RuntimeError(f"native {method}: {code}")
    return response["result"]


def read_state(path):
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("invalid local compaction state")
    return data


def save_state(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temp_name = tempfile.mkstemp(prefix=".compaction-", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(data, stream, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def is_context_limit_error(error):
    if not isinstance(error, dict) or error.get("kind") != "provider_rejection":
        return False
    message = error.get("message")
    if not isinstance(message, str):
        return False
    message = message.lower()
    return "maximum context length" in message and "exceeds this limit" in message


def is_empty_summary_error(error):
    return (isinstance(error, dict)
            and error.get("kind") == "other"
            and error.get("message") == "Compaction produced an empty summary")


def check_thread(args, state, identity, thread):
    if thread.get("status") != "Idle" or thread.get("current_turn_id") is not None:
        return "busy"
    thread_id = thread.get("thread_id")
    if not isinstance(thread_id, str) or not thread_id:
        return "invalid"
    base = {**identity, "thread_id": thread_id}
    settings = rpc(args.socket, "thread.settings", base)
    model = settings.get("model") or {}
    if (settings.get("thread_id") != thread_id or settings.get("status") != "Idle"
            or settings.get("configuration_owner") != "zed"
            or model.get("provider_id") != args.provider or model.get("id") != args.model):
        return "other-model"
    snapshot = rpc(args.socket, "thread.snapshot", {"thread_id": thread_id, "tail_entry_count": 1})
    if (snapshot.get("thread_id") != thread_id or snapshot.get("instance_id") != identity["instance_id"]
            or snapshot.get("epoch") != identity["epoch"] or snapshot.get("status") != "Idle"
            or snapshot.get("current_turn_id") is not None or snapshot.get("pending_approvals")):
        return "not-ready"
    error = snapshot.get("agent_error")
    context_limit_error = is_context_limit_error(error)
    empty_summary_error = is_empty_summary_error(error)
    if error and not (context_limit_error or empty_summary_error):
        return "not-ready"
    last_entry = (snapshot.get("entries_markdown") or [""])[-1]
    if last_entry.startswith(("## Context Compaction (Completed)",
                              "## Context Compaction (In Progress)")):
        return "last-entry-compaction"

    usage = settings.get("context_usage") or {}
    used, maximum = usage.get("used_tokens"), usage.get("max_tokens")
    if empty_summary_error:
        # A failed native compaction leaves the thread intact. Retry this exact
        # failure only once; the saved marker prevents a repeating model call.
        marker = ["empty-summary", hashlib.sha256(error["message"].encode()).hexdigest()]
    elif context_limit_error:
        # Zed clears latest_token_usage after a rejected request. Bind the one
        # recovery attempt to this exact rejection, without storing its text.
        marker = ["context-limit", hashlib.sha256(error["message"].encode()).hexdigest()]
    else:
        if not isinstance(used, int) or not isinstance(maximum, int) or maximum <= args.headroom:
            return "no-usage"
        threshold = min(args.threshold, maximum - args.headroom)
        if used < threshold:
            return "below-threshold"
        marker = [usage.get("input_tokens"), usage.get("output_tokens"), used]

    key = hashlib.sha256("\0".join((identity["instance_id"], identity["epoch"], thread_id)).encode()).hexdigest()
    previous = state.get(key)
    if previous and previous.get("marker") == marker:
        if previous.get("status") == "pending":
            result = rpc(args.socket, "request.status", {**identity, "original_request_id": previous["request_id"]})
            if result.get("known"):
                previous["status"] = "sent"
                save_state(args.state, state)
        return "already-reviewed"
    queue = rpc(args.socket, "thread.queue", base)
    if queue.get("entries"):
        return "queued-work"
    commands = rpc(args.socket, "thread.commands", base)
    if not any(command.get("name") == "compact" and command.get("category") == "native"
               and command.get("execution") == "prompt" for command in commands.get("commands", [])):
        return "compact-unavailable"
    if args.dry_run:
        return "would-compact"

    request_id = "local-compact-" + uuid.uuid4().hex
    state[key] = {"marker": marker, "status": "pending", "request_id": request_id}
    save_state(args.state, state)
    result = rpc(args.socket, "thread.send", {**base, "text": "/compact"}, request_id)
    if result.get("outcome") in ("unknown", "queued", "local_completed"):
        state[key]["status"] = "sent"
        save_state(args.state, state)
        return "sent"
    return "needs-review"


def poll(args):
    info = rpc(args.socket, "instance.info", {})
    listing = rpc(args.socket, "thread.list", {})
    identity = {"instance_id": info["instance_id"], "epoch": info["epoch"]}
    if listing.get("instance_id") != identity["instance_id"] or listing.get("epoch") != identity["epoch"]:
        raise RuntimeError("native instance changed during polling")
    args.capabilities = set(info.get("capabilities", []))
    if not {"thread.settings", "thread.commands", "thread.send", "thread.snapshot", "thread.queue"}.issubset(args.capabilities):
        raise RuntimeError("native compaction capabilities unavailable")
    state = read_state(args.state)
    if args.wait_for_new_instance:
        current_instance = [identity["instance_id"], identity["epoch"]]
        baseline = state.get("_baseline_instance")
        if baseline is None:
            state["_baseline_instance"] = current_instance
            save_state(args.state, state)
            return ["waiting-for-clean-restart"] * len(listing.get("threads", []))
        if baseline == current_instance:
            return ["waiting-for-clean-restart"] * len(listing.get("threads", []))
        if baseline != "ready":
            state["_baseline_instance"] = "ready"
            save_state(args.state, state)
    threads = listing.get("threads", [])
    results = []
    for thread in threads:
        try:
            results.append(check_thread(args, state, identity, thread))
        except (OSError, ValueError, KeyError, RuntimeError) as error:
            results.append("needs-review")
            print(f"Thread check needs review: {error}", flush=True)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--provider", default="cali-llm")
    parser.add_argument("--model", default="brain")
    parser.add_argument("--threshold", type=int, default=49152)
    parser.add_argument("--headroom", type=int, default=16384)
    parser.add_argument("--interval", type=float, default=10)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--wait-for-new-instance", action="store_true")
    args = parser.parse_args()
    if args.threshold <= 0 or args.headroom <= 0 or args.interval < 2:
        parser.error("threshold and headroom must be positive; interval must be at least 2 seconds")
    last_error = None
    while True:
        try:
            results = poll(args)
            last_error = None
            if args.once:
                print(json.dumps({"exposed_threads": len(results), "outcomes": results}))
            elif "sent" in results:
                print("Native /compact requested on an idle, explicitly exposed thread.", flush=True)
        except (OSError, ValueError, KeyError, RuntimeError) as error:
            if args.once:
                raise SystemExit(f"NOT RUN: {error}") from error
            if str(error) != last_error:
                print(f"Local compaction waiting: {error}", flush=True)
                last_error = str(error)
        if args.once:
            break
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
