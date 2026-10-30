"""State and replay checks for the personal native compaction helper."""

import importlib.util
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("zedlink_user_auto_compact.py")
SPEC = importlib.util.spec_from_file_location("zedlink_user_auto_compact", MODULE_PATH)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


class NativeFixture:
    def __init__(self, *, failed=False, busy_other=False, last_compaction_failed=False,
                 empty_summary=False):
        self.failed = failed
        self.busy_other = busy_other
        self.last_compaction_failed = last_compaction_failed
        self.empty_summary = empty_summary
        self.sends = []

    def rpc(self, _socket, method, params, request_id=None):
        identity = {"instance_id": "instance", "epoch": "epoch"}
        if method == "instance.info":
            return {**identity, "capabilities": ["thread.settings", "thread.commands",
                    "thread.send", "thread.snapshot", "thread.queue"]}
        if method == "thread.list":
            threads = [{"thread_id": "target", "status": "Idle", "current_turn_id": None}]
            if self.busy_other:
                threads.insert(0, {"thread_id": "other", "status": "Generating", "current_turn_id": 1})
            return {**identity, "threads": threads}
        if method == "thread.settings":
            return {"thread_id": "target", "status": "Idle", "configuration_owner": "zed",
                    "model": {"provider_id": "cali-llm", "id": "brain"},
                    "context_usage": None if self.failed or self.empty_summary else {"used_tokens": 45000,
                    "max_tokens": 65536, "input_tokens": 44000, "output_tokens": 1000}}
        if method == "thread.snapshot":
            return {**identity, "thread_id": "target", "status": "Idle",
                    "current_turn_id": None, "pending_approvals": [],
                    "agent_error": ({"kind": "other", "message":
                        "Compaction produced an empty summary"} if self.empty_summary else
                        {"kind": "provider_rejection", "message":
                        "This model's maximum context length is 65536 tokens; input exceeds this limit"}
                        if self.failed else None), "entries_markdown": [
                        "## Context Compaction (Failed)" if self.last_compaction_failed else "## Assistant"]}
        if method == "thread.queue":
            return {"entries": []}
        if method == "thread.commands":
            return {"commands": [{"name": "compact", "category": "native", "execution": "prompt"}]}
        if method == "thread.send":
            self.sends.append((params, request_id))
            return {"outcome": "local_completed"}
        raise AssertionError(method)


class AutoCompactTest(unittest.TestCase):
    def run_poll(self, fixture, state_file):
        args = types.SimpleNamespace(socket=Path("fixture"), state=state_file,
            provider="cali-llm", model="brain", threshold=40960, headroom=16384,
            dry_run=False, wait_for_new_instance=False)
        with patch.object(helper, "rpc", fixture.rpc):
            return helper.poll(args)

    def test_idle_thread_compacts_while_another_thread_is_busy(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = NativeFixture(busy_other=True)
            state_file = Path(directory) / "state.json"
            self.assertEqual(self.run_poll(fixture, state_file), ["busy", "sent"])
            self.assertEqual(self.run_poll(fixture, state_file), ["busy", "already-reviewed"])
            self.assertEqual(len(fixture.sends), 1)
            self.assertEqual(fixture.sends[0][0]["text"], "/compact")

    def test_context_rejection_without_usage_recovers_once(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = NativeFixture(failed=True)
            state_file = Path(directory) / "state.json"
            self.assertEqual(self.run_poll(fixture, state_file), ["sent"])
            self.assertEqual(self.run_poll(fixture, state_file), ["already-reviewed"])
            self.assertEqual(len(fixture.sends), 1)
            self.assertNotIn("maximum context length", state_file.read_text())

    def test_failed_compaction_does_not_loop(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = NativeFixture(failed=True, last_compaction_failed=True)
            self.assertEqual(self.run_poll(fixture, Path(directory) / "state.json"),
                ["sent"])
            self.assertEqual(self.run_poll(fixture, Path(directory) / "state.json"),
                ["already-reviewed"])
            self.assertEqual(len(fixture.sends), 1)

    def test_empty_summary_retries_once_without_usage(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = NativeFixture(empty_summary=True, last_compaction_failed=True)
            state_file = Path(directory) / "state.json"
            self.assertEqual(self.run_poll(fixture, state_file), ["sent"])
            self.assertEqual(self.run_poll(fixture, state_file), ["already-reviewed"])
            self.assertEqual(len(fixture.sends), 1)
            self.assertNotIn("Compaction produced an empty summary", state_file.read_text())

    def test_other_error_does_not_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = NativeFixture(empty_summary=True)
            fixture.empty_summary = False
            original_rpc = fixture.rpc
            def other_error_rpc(socket, method, params, request_id=None):
                result = original_rpc(socket, method, params, request_id)
                if method == "thread.snapshot":
                    result["agent_error"] = {"kind": "other", "message": "Unrelated failure"}
                return result
            with patch.object(helper, "rpc", other_error_rpc):
                args = types.SimpleNamespace(socket=Path("fixture"), state=Path(directory) / "state.json",
                    provider="cali-llm", model="brain", threshold=40960, headroom=16384,
                    dry_run=False, wait_for_new_instance=False)
                self.assertEqual(helper.poll(args), ["not-ready"])
            self.assertEqual(fixture.sends, [])


if __name__ == "__main__":
    unittest.main()
