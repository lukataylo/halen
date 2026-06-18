#!/usr/bin/env python3
"""Unit tests for the Halen local-compaction plugin's pure logic and WebSocket
frame codec. No Halen, no network, no model — run with:

    python3 test_compaction.py
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts"))
import compaction as C  # noqa: E402
import halen_bridge as B  # noqa: E402


class TokenAndConfig(unittest.TestCase):
    def test_estimate_tokens(self):
        self.assertEqual(C.estimate_tokens(""), 0)
        self.assertEqual(C.estimate_tokens("abcd"), 1)
        self.assertEqual(C.estimate_tokens("a" * 400), 100)

    def test_defaults(self):
        cfg = C.load_config(None)
        self.assertEqual(cfg["frequency"], "auto")
        self.assertEqual(cfg["type"], "extractive")
        self.assertEqual(cfg["model_tier"], "medium")
        self.assertEqual(cfg["bridge_port"], 50765)

    def test_invalid_enums_fall_back(self):
        cfg = C.load_config({"frequency": "weekly", "type": "magic", "model_tier": "xl"})
        self.assertEqual(cfg["frequency"], "auto")
        self.assertEqual(cfg["type"], "extractive")
        self.assertEqual(cfg["model_tier"], "medium")

    def test_valid_enums_applied(self):
        cfg = C.load_config({"frequency": "MANUAL", "type": "Abstractive", "model_tier": "LARGE"})
        self.assertEqual(cfg["frequency"], "manual")
        self.assertEqual(cfg["type"], "abstractive")
        self.assertEqual(cfg["model_tier"], "large")

    def test_numeric_coercion_and_clamp(self):
        cfg = C.load_config({
            "target_keep_ratio": 5.0,    # clamp to 0.95
            "min_tokens": -10,           # clamp to 0
            "target_tokens": "300",      # str → int
            "bridge_port": 0,            # clamp to 1
        })
        self.assertEqual(cfg["target_keep_ratio"], 0.95)
        self.assertEqual(cfg["min_tokens"], 0)
        self.assertEqual(cfg["target_tokens"], 300)
        self.assertEqual(cfg["bridge_port"], 1)

    def test_bad_numbers_use_defaults(self):
        cfg = C.load_config({"target_keep_ratio": "nope", "min_tokens": None, "target_tokens": 1e999})
        self.assertEqual(cfg["target_keep_ratio"], C.DEFAULTS["target_keep_ratio"])
        self.assertEqual(cfg["min_tokens"], C.DEFAULTS["min_tokens"])
        self.assertEqual(cfg["target_tokens"], C.DEFAULTS["target_tokens"])

    def test_preserve_filtered(self):
        cfg = C.load_config({"preserve": ["code", "bogus", 42, "decisions"]})
        self.assertEqual(cfg["preserve"], ["code", "decisions"])
        cfg2 = C.load_config({"preserve": []})
        self.assertEqual(cfg2["preserve"], [])

    def test_load_config_file_missing(self):
        cfg = C.load_config_file("/no/such/path/config.json")
        self.assertEqual(cfg["type"], "extractive")

    def test_load_config_file_roundtrip(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"type": "abstractive", "min_tokens": 1000}, fh)
            path = fh.name
        try:
            cfg = C.load_config_file(path)
            self.assertEqual(cfg["type"], "abstractive")
            self.assertEqual(cfg["min_tokens"], 1000)
        finally:
            os.unlink(path)


class FrequencyGate(unittest.TestCase):
    def test_below_min_tokens_skips(self):
        cfg = C.load_config({"min_tokens": 6000})
        self.assertFalse(C.should_run(cfg, "auto", 100))

    def test_manual_only_skips_auto(self):
        cfg = C.load_config({"frequency": "manual", "min_tokens": 0})
        self.assertFalse(C.should_run(cfg, "auto", 9999))
        self.assertTrue(C.should_run(cfg, "manual", 9999))

    def test_auto_runs_on_both(self):
        cfg = C.load_config({"frequency": "auto", "min_tokens": 0})
        self.assertTrue(C.should_run(cfg, "auto", 9999))
        self.assertTrue(C.should_run(cfg, "manual", 9999))


class TranscriptParsing(unittest.TestCase):
    def test_string_and_block_content(self):
        lines = [
            {"type": "user", "message": {"role": "user", "content": "fix the bug"}},
            {"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "thinking", "thinking": "let me look"},
                {"type": "text", "text": "Found it."},
                {"type": "tool_use", "name": "Edit"},
            ]}},
            {"type": "summary", "summary": "ignore me"},
            {"type": "user", "message": {"role": "user", "content": [
                {"type": "tool_result", "content": "ok"},
            ]}},
        ]
        jsonl = "\n".join(json.dumps(x) for x in lines)
        out = C.parse_transcript(jsonl)
        self.assertIn("User: fix the bug", out)
        self.assertIn("let me look", out)
        self.assertIn("Found it.", out)
        self.assertIn("[called Edit]", out)
        self.assertNotIn("ignore me", out)

    def test_malformed_lines_skipped(self):
        jsonl = 'not json\n{"type":"user","message":{"role":"user","content":"hi there"}}\n{}'
        out = C.parse_transcript(jsonl)
        self.assertEqual(out, "User: hi there")

    def test_empty(self):
        self.assertEqual(C.parse_transcript(""), "")

    def test_split_turns(self):
        t = "User: a\n\nAssistant: b\n\nUser: c"
        self.assertEqual(C.split_turns(t), ["User: a", "Assistant: b", "User: c"])


class ClipTranscript(unittest.TestCase):
    def test_no_clip_when_small(self):
        t = "User: hello\n\nAssistant: hi"
        self.assertEqual(C.clip_transcript(t, 10000), t)

    def test_clips_to_tail_whole_turns(self):
        turns = [f"User: turn number {i} " + "x" * 50 for i in range(20)]
        t = "\n\n".join(turns)
        clipped = C.clip_transcript(t, 300)
        self.assertLessEqual(len(clipped), 300 + len("[... earlier turns omitted ...]") + 4)
        self.assertIn("earlier turns omitted", clipped)
        # The most recent turn must survive.
        self.assertIn("turn number 19", clipped)
        self.assertNotIn("turn number 0 ", clipped)


class PromptBuilding(unittest.TestCase):
    def test_target_budget_ratio_vs_absolute(self):
        cfg = C.load_config({"target_keep_ratio": 0.5, "target_tokens": 0})
        self.assertEqual(C.target_token_budget(cfg, 1000), 500)
        cfg2 = C.load_config({"target_keep_ratio": 0.5, "target_tokens": 120})
        self.assertEqual(C.target_token_budget(cfg2, 1000), 120)

    def test_extractive_prompt_numbers_turns(self):
        cfg = C.load_config({"type": "extractive"})
        t = "User: a\n\nAssistant: b\n\nUser: c"
        prompt, mode = C.build_prompt(t, cfg)
        self.assertEqual(mode, "extractive")
        self.assertIn("[0] User: a", prompt)
        self.assertIn("[2] User: c", prompt)
        self.assertIn("KEEP:", prompt)

    def test_abstractive_prompt(self):
        cfg = C.load_config({"type": "abstractive"})
        prompt, mode = C.build_prompt("User: a\n\nAssistant: b", cfg)
        self.assertEqual(mode, "abstractive")
        self.assertIn("Briefing:", prompt)

    def test_preserve_clause_present(self):
        cfg = C.load_config({"preserve": ["code"]})
        prompt, _ = C.build_prompt("User: a\n\nAssistant: b", cfg)
        self.assertIn("code blocks", prompt)


class ExtractiveReconstruction(unittest.TestCase):
    def setUp(self):
        self.t = "User: a\n\nAssistant: b\n\nUser: c\n\nAssistant: d"

    def test_standalone_numbers_only(self):
        # "step12" / embedded digits ignored; standalone 0 and 2 kept.
        self.assertEqual(C.parse_keep_indices("keep step12 and v2: 0, 2", 4), [0, 2])

    def test_out_of_range_filtered(self):
        self.assertEqual(C.parse_keep_indices("0, 2, 99", 4), [0, 2])

    def test_dedupe_sort(self):
        self.assertEqual(C.parse_keep_indices("3, 1, 1, 0", 4), [0, 1, 3])

    def test_no_numbers_returns_none(self):
        self.assertIsNone(C.parse_keep_indices("I cannot help with that", 4))
        self.assertIsNone(C.parse_keep_indices("", 4))

    def test_reconstruct_forces_last_turn(self):
        out = C.reconstruct_extractive(self.t, "0")
        # last turn (index 3) force-kept even though only 0 selected
        self.assertIn("User: a", out)
        self.assertIn("Assistant: d", out)
        self.assertNotIn("Assistant: b", out)

    def test_reconstruct_none_on_unparseable(self):
        self.assertIsNone(C.reconstruct_extractive(self.t, "no idea"))

    def test_reconstruct_empty_transcript(self):
        self.assertIsNone(C.reconstruct_extractive("", "0"))


class Reporting(unittest.TestCase):
    def test_stats(self):
        s = C.compaction_stats("a" * 400, "a" * 100)
        self.assertEqual(s["original_tokens"], 100)
        self.assertEqual(s["compacted_tokens"], 25)
        self.assertEqual(s["pct_saved"], 75)

    def test_summary_message(self):
        s = C.compaction_stats("a" * 8000, "a" * 2000)
        msg = C.summary_message(s, "extractive")
        self.assertIn("Halen", msg)
        self.assertIn("on-device", msg)


class FrameCodec(unittest.TestCase):
    def test_roundtrip_small(self):
        payload = b'{"hello":"world"}'
        frames, rest = B.decode_frames(B.encode_frame(payload))
        self.assertEqual(rest, b"")
        self.assertEqual(frames, [(B.OP_TEXT, payload)])

    def test_roundtrip_16bit_length(self):
        payload = b"x" * 5000  # > 125 → 16-bit length path
        frames, _ = B.decode_frames(B.encode_frame(payload))
        self.assertEqual(frames[0][1], payload)

    def test_masking_set_on_client_frame(self):
        frame = B.encode_frame(b"hi")
        # second byte high bit = mask bit, must be set
        self.assertTrue(frame[1] & 0x80)

    def test_decode_unmasked_server_frame(self):
        # Server frames are unmasked: 0x81, len, payload
        payload = b"pong-data"
        frame = bytes([0x81, len(payload)]) + payload
        frames, rest = B.decode_frames(frame)
        self.assertEqual(frames, [(B.OP_TEXT, payload)])
        self.assertEqual(rest, b"")

    def test_partial_frame_buffered(self):
        full = B.encode_frame(b"abcdef")
        frames, rest = B.decode_frames(full[:3])
        self.assertEqual(frames, [])
        self.assertEqual(rest, full[:3])
        # Completing the buffer decodes it.
        frames2, rest2 = B.decode_frames(rest + full[3:])
        self.assertEqual(frames2[0][1], b"abcdef")
        self.assertEqual(rest2, b"")

    def test_two_frames_in_one_buffer(self):
        buf = B.encode_frame(b"one") + B.encode_frame(b"two")
        frames, rest = B.decode_frames(buf)
        self.assertEqual([f[1] for f in frames], [b"one", b"two"])
        self.assertEqual(rest, b"")

    def test_close_and_ping_opcodes(self):
        frames, _ = B.decode_frames(B.encode_frame(b"", B.OP_CLOSE))
        self.assertEqual(frames[0][0], B.OP_CLOSE)
        frames2, _ = B.decode_frames(B.encode_frame(b"p", B.OP_PING))
        self.assertEqual(frames2[0][0], B.OP_PING)

    def test_read_token(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as fh:
            fh.write("  deadbeef\n")
            path = fh.name
        try:
            self.assertEqual(B.read_token(path), "deadbeef")
        finally:
            os.unlink(path)
        self.assertIsNone(B.read_token("/no/such/token"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
