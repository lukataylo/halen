#!/usr/bin/env python3
"""Unit suite for the Reasoning Compactor's pure logic. No network, no model,
no host — just the deterministic functions. Run with:

    python3 test_plugin.py

Covers: token estimation, reasoning detection, code-aware segmentation
(including unclosed fences), paragraph chunking, ratio-vs-absolute-budget
targeting (incl. per-passage split), step splitting, the extractive
keep-index parser (standalone-number parsing, embedded-number rejection,
prose -> parse-failure, forced answer/conclusion keep), and load_config
robustness against malformed config.json values."""
import importlib.util
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load():
    spec = importlib.util.spec_from_file_location("rc_under_test",
                                                   os.path.join(_HERE, "plugin.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


rc = _load()


class TokenEstimation(unittest.TestCase):
    def test_floor_is_one(self):
        self.assertEqual(rc.estimate_tokens(""), 1)
        self.assertEqual(rc.estimate_tokens("a"), 1)

    def test_roughly_four_chars_per_token(self):
        self.assertEqual(rc.estimate_tokens("x" * 400), 100)


class ReasoningDetection(unittest.TestCase):
    def test_two_markers_trip_signal(self):
        self.assertGreaterEqual(rc.reasoning_signal("Let me think. Therefore the answer is 4."), 2)

    def test_plain_prose_is_not_reasoning(self):
        self.assertEqual(rc.reasoning_signal("The cat sat on the mat. It was warm."), 0)

    def test_numbered_scaffolding_counts(self):
        txt = "1. first\n2. second\n3. third\n"
        self.assertGreaterEqual(rc.reasoning_signal(txt), 1)

    def test_looks_like_reasoning_needs_length_and_signal(self):
        short = "Let me think. Therefore 4."
        self.assertFalse(rc.looks_like_reasoning(short, min_chars=480))
        long = ("Let me think about this carefully. " * 30) + "Therefore the answer is 4."
        self.assertTrue(rc.looks_like_reasoning(long, min_chars=480))


class Segmentation(unittest.TestCase):
    def test_prose_only(self):
        segs = rc.segment("just some prose\nmore prose")
        self.assertEqual([k for k, _ in segs], ["prose"])

    def test_code_fence_isolated_as_code(self):
        segs = rc.segment("before\n```\ncode()\n```\nafter")
        kinds = [k for k, _ in segs]
        self.assertEqual(kinds, ["prose", "code", "prose"])
        code = [c for k, c in segs if k == "code"][0]
        self.assertIn("code()", code)

    def test_unclosed_fence_is_treated_as_code(self):
        segs = rc.segment("intro\n```\nhalf open code\nno closing fence")
        self.assertEqual(segs[-1][0], "code")
        self.assertIn("half open code", segs[-1][1])


class ChunkProse(unittest.TestCase):
    def test_chunks_respect_budget(self):
        paras = ["x" * 400 for _ in range(5)]   # ~100 tokens each
        text = "\n\n".join(paras)
        chunks = rc.chunk_prose(text, budget=150)
        # No chunk exceeds the budget by more than one paragraph's worth.
        for ch in chunks:
            self.assertLessEqual(rc.estimate_tokens(ch), 250)
        # Reassembly preserves all paragraphs.
        self.assertEqual(sum(ch.count("x" * 400) for ch in chunks), 5)


class TargetBudget(unittest.TestCase):
    def setUp(self):
        self._saved = dict(rc.CFG)

    def tearDown(self):
        rc.CFG.clear(); rc.CFG.update(self._saved)

    def test_ratio_mode(self):
        rc.CFG["target_tokens"] = 0
        rc.CFG["target_keep_ratio"] = 0.45
        self.assertEqual(rc.target_tokens_for(1000), 450)

    def test_absolute_global_caps_to_input(self):
        rc.CFG["target_tokens"] = 500
        self.assertEqual(rc.target_tokens_for(300), 300)   # never more than input
        self.assertEqual(rc.target_tokens_for(2000), 500)  # capped at budget

    def test_per_passage_absolute_overrides_global(self):
        rc.CFG["target_tokens"] = 500
        # A chunk's proportional slice (166) is honored over the global 500.
        self.assertEqual(rc.target_tokens_for(300, 166), 166)

    def test_never_zero(self):
        rc.CFG["target_tokens"] = 0
        rc.CFG["target_keep_ratio"] = 0.1
        self.assertGreaterEqual(rc.target_tokens_for(1), 1)


class StepSplitting(unittest.TestCase):
    def test_numbered_steps_split(self):
        prose = "1. First do this. 2. Then that. 3. Finally done."
        steps = rc.split_steps(prose)
        self.assertGreaterEqual(len(steps), 3)


class SelectKeptSteps(unittest.TestCase):
    def setUp(self):
        # 10 steps, none answer-bearing so we isolate the parser; final step
        # is always force-kept (index 9).
        self.steps = [f"step {i} does a thing" for i in range(1, 11)]

    def _idxs(self, raw):
        return rc.select_kept_steps(raw, self.steps)

    def test_clean_comma_separated(self):
        self.assertEqual(self._idxs("1, 2, 5"), [0, 1, 4, 9])  # 9 forced (last)

    def test_no_spaces(self):
        self.assertEqual(self._idxs("1,2,5"), [0, 1, 4, 9])

    def test_embedded_number_rejected(self):
        # "x=42" must NOT become step 42; only standalone 1,2,5 count.
        out = self._idxs("Keep 1, 2, 5 (x=42 matters)")
        self.assertEqual(out, [0, 1, 4, 9])

    def test_label_prefix_tolerated(self):
        self.assertEqual(self._idxs("Keep: 1, 2, 5, 8"), [0, 1, 4, 7, 9])

    def test_prose_dump_is_parse_failure(self):
        out = self._idxs("I think we should keep the important early ones and the conclusion")
        self.assertIs(out, rc._PARSE_FAILED)

    def test_no_numbers_is_parse_failure(self):
        self.assertIs(self._idxs("none of them really"), rc._PARSE_FAILED)

    def test_out_of_range_filtered(self):
        # 99 is out of range (only 10 steps); ignored, not crash.
        self.assertEqual(self._idxs("1, 99, 3"), [0, 2, 9])

    def test_answer_step_forced_in(self):
        steps = ["reasoning a", "reasoning b", "The answer is 42.", "more", "tail"]
        # Model keeps only step 1; answer step (idx 2) + final (idx 4) forced.
        out = rc.select_kept_steps("1", steps)
        self.assertIn(2, out)   # answer-bearing
        self.assertIn(4, out)   # final/conclusion


class LoadConfigRobustness(unittest.TestCase):
    """A malformed config.json value must fall back to the default, never crash
    the plugin at import."""
    def setUp(self):
        self.path = os.path.join(_HERE, "config.json")
        self._backup = None
        if os.path.exists(self.path):
            with open(self.path) as fh:
                self._backup = fh.read()

    def tearDown(self):
        if self._backup is not None:
            with open(self.path, "w") as fh:
                fh.write(self._backup)
        elif os.path.exists(self.path):
            os.remove(self.path)

    def _load_with(self, json_text):
        with open(self.path, "w") as fh:
            fh.write(json_text)
        return rc.load_config()

    def test_valid_config_passthrough(self):
        cfg = self._load_with('{"target_keep_ratio": 0.3, "min_chars": 600}')
        self.assertEqual(cfg["target_keep_ratio"], 0.3)
        self.assertEqual(cfg["min_chars"], 600)

    def test_string_for_float_falls_back(self):
        cfg = self._load_with('{"target_keep_ratio": "high"}')
        self.assertEqual(cfg["target_keep_ratio"], rc.DEFAULTS["target_keep_ratio"])

    def test_null_for_int_falls_back(self):
        cfg = self._load_with('{"target_tokens": null}')
        self.assertEqual(cfg["target_tokens"], rc.DEFAULTS["target_tokens"])

    def test_infinity_via_1e999_falls_back(self):
        # json.load parses 1e999 to float('inf'); int(inf) raises OverflowError.
        cfg = self._load_with('{"target_tokens": 1e999, "max_single_pass_tokens": 1e999}')
        self.assertEqual(cfg["target_tokens"], rc.DEFAULTS["target_tokens"])
        self.assertEqual(cfg["max_single_pass_tokens"], rc.DEFAULTS["max_single_pass_tokens"])

    def test_ratio_clamped(self):
        self.assertEqual(self._load_with('{"target_keep_ratio": 5.0}')["target_keep_ratio"], 0.95)
        self.assertEqual(self._load_with('{"target_keep_ratio": 0.0001}')["target_keep_ratio"], 0.1)

    def test_chunk_budget_floored_to_one(self):
        self.assertGreaterEqual(self._load_with('{"max_single_pass_tokens": 0}')["max_single_pass_tokens"], 1)

    def test_clipboard_cmd_must_be_nonempty_list(self):
        self.assertEqual(self._load_with('{"clipboard_cmd": []}')["clipboard_cmd"],
                         rc.DEFAULTS["clipboard_cmd"])
        self.assertEqual(self._load_with('{"clipboard_cmd": "pbcopy"}')["clipboard_cmd"],
                         rc.DEFAULTS["clipboard_cmd"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
