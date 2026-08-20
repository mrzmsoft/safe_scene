#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Unit tests for the Safe Scene *visual ensemble* logic in scanner_engine.py.

Pure-logic only: model discovery, per-frame vote fusion, temporal
confirmation, and label selection. No ONNX model or video is required.

Run from the repository root or anywhere:

    python test/scanner_ensemble_test.py
"""
from __future__ import annotations

import json
import os
import sys
import tempfile

# Allow importing scanner_engine.py from the repository root.
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

import scanner_engine as se  # noqa: E402


def test_defaults():
    cfg = se.load_visual_config(None)
    assert cfg["rule"] == se.DEFAULT_RULE == "consensus"
    assert cfg["confirm_confidence"] == se.DEFAULT_CONFIRM_CONFIDENCE
    assert cfg["hard_confidence"] == se.DEFAULT_HARD_CONFIDENCE
    assert cfg["vote_window"] == se.VOTE_WINDOW
    assert cfg["min_votes"] == se.VOTE_MIN
    print("  ok  defaults")


def test_frame_confirm_rules():
    cfg = se.load_visual_config(None)
    # empty / nothing flagging -> never confirmed
    assert se._frame_confirm([], cfg)[0] is False
    assert se._frame_confirm([(0.0, ""), (0.0, "")], cfg)[0] is False

    # consensus: weak single vote (0.70) is NOT enough -> kills false alert
    assert se._frame_confirm([(0.70, "sexy"), (0.0, "")], cfg)[0] is False

    # consensus: both models agree -> confirmed (all)
    ok, conf = se._frame_confirm([(0.72, "exposed"), (0.68, "exposed")], cfg)
    assert ok is True and conf == 0.72

    # consensus: majority + confirm_confidence -> confirmed
    ok, conf = se._frame_confirm([(0.90, "exposed"), (0.70, "exposed"), (0.0, "")], cfg)
    assert ok is True

    # consensus: single very strong vote (hard_confidence) -> confirmed (recall)
    ok, conf = se._frame_confirm([(0.96, "exposed"), (0.0, "")], cfg)
    assert ok is True and conf == 0.96

    # all / any / majority overrides
    cfg_all = dict(cfg, rule="all")
    assert se._frame_confirm([(0.90, "x"), (0.0, "")], cfg_all)[0] is False
    assert se._frame_confirm([(0.90, "x"), (0.70, "y")], cfg_all)[0] is True

    cfg_any = dict(cfg, rule="any")
    assert se._frame_confirm([(0.70, "x"), (0.0, "")], cfg_any)[0] is True

    cfg_maj = dict(cfg, rule="majority")
    assert se._frame_confirm([(0.80, "x"), (0.0, ""), (0.0, "")], cfg_maj)[0] is False
    assert se._frame_confirm([(0.80, "x"), (0.70, "y"), (0.0, "")], cfg_maj)[0] is True
    print("  ok  _frame_confirm rules")


def test_temporal_confirm():
    # isolated single-sample spike -> dropped (classic false alert)
    assert se._temporal_confirm([50], window=2, min_votes=2) == []
    # a real scene spanning several samples -> kept
    assert se._temporal_confirm([10, 11, 12], window=2, min_votes=2) == [10, 11, 12]
    # two frames within the window survive
    assert se._temporal_confirm([100, 101], window=2, min_votes=2) == [100, 101]
    # spike far from anything dropped, cluster at the other end kept
    kept = se._temporal_confirm([5, 200, 201, 202], window=2, min_votes=2)
    assert kept == [200, 201, 202]
    print("  ok  _temporal_confirm")


def test_best_label():
    assert se._best_label([(0.0, ""), (0.90, "exposed"), (0.80, "sexy")]) == "exposed"
    assert se._best_label([(0.0, ""), (0.0, "")]) == ""
    print("  ok  _best_label")


def test_discovery_and_resolve():
    with tempfile.TemporaryDirectory() as d:
        for fn in ("nudenet.onnx", "yolo_nsfw.onnx", "audio_helper.wav"):
            with open(os.path.join(d, fn), "wb") as fh:
                fh.write(b"\0")

        # Auto-discovery picks the NSFW-named onnx files (nudenet always first).
        paths = se.discover_visual_models(d)
        names = [os.path.basename(p).lower() for p in paths]
        assert names == ["nudenet.onnx", "yolo_nsfw.onnx"], names

        # Config file overrides both threshold and labels per model.
        cfg = {
            "models": [
                {"file": "nudenet.onnx", "threshold": 0.7},
                {"file": "yolo_nsfw.onnx", "labels": "yolo_labels.json"},
            ]
        }
        with open(os.path.join(d, se.VISUAL_CONFIG_NAME), "w", encoding="utf-8") as fh:
            json.dump(cfg, fh)
        specs = se.resolve_visual_specs(d)
        by_name = {os.path.basename(s["path"]).lower(): s for s in specs}
        assert by_name["nudenet.onnx"]["threshold"] == 0.7
        assert by_name["nudenet.onnx"]["labels"] is None
        assert by_name["yolo_nsfw.onnx"]["threshold"] == se.VISUAL_THRESHOLD
        assert by_name["yolo_nsfw.onnx"]["labels"] == "yolo_labels.json"

        # A missing model in the config is skipped but others still load.
        cfg["models"].append({"file": "missing.onnx"})
        with open(os.path.join(d, se.VISUAL_CONFIG_NAME), "w", encoding="utf-8") as fh:
            json.dump(cfg, fh)
        specs = se.resolve_visual_specs(d)
        assert len(specs) == 2
    print("  ok  discovery + resolve")


def test_config_override_path():
    with tempfile.TemporaryDirectory() as d:
        cfg_path = os.path.join(d, "custom.json")
        with open(cfg_path, "w", encoding="utf-8") as fh:
            json.dump({"rule": "all", "vote_window": 5}, fh)
        cfg = se.load_visual_config(None, override_path=cfg_path)
        assert cfg["rule"] == "all" and cfg["vote_window"] == 5
        # other fields fall back to defaults
        assert cfg["min_votes"] == se.VOTE_MIN
    print("  ok  config override path")


def test_shipped_visual_config():
    """The active visual_models.json ships with the second model registered so
    cross-model confirmation activates the moment the user drops the .onnx in."""
    models_dir = os.path.join(_ROOT, "assets", "models")
    cfg = se.load_visual_config(models_dir)
    assert cfg["rule"] == "consensus"
    assert isinstance(cfg["confirm_confidence"], float)
    assert isinstance(cfg["hard_confidence"], float)
    files = [str(m.get("file")) for m in cfg["models"]]
    assert "nudenet.onnx" in files, files
    assert "yolo_nsfw.onnx" in files, files
    print("  ok  shipped visual config")


def main():
    se._log = lambda *a, **k: None  # silence discovery "not found" warnings
    tests = [
        test_defaults,
        test_frame_confirm_rules,
        test_temporal_confirm,
        test_best_label,
        test_discovery_and_resolve,
        test_config_override_path,
        test_shipped_visual_config,
    ]
    failures = 0
    for fn in tests:
        try:
            fn()
        except AssertionError as exc:
            failures += 1
            print(f"FAIL {fn.__name__}: {exc}")
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print(f"ERROR {fn.__name__}: {type(exc).__name__}: {exc}")
    print(f"\n{len(tests) - failures}/{len(tests)} tests passed.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
