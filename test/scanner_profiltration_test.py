#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Unit tests for the Safe Scene *profanity matcher* hardening in scanner_engine.py.

Pure-logic only: token normalisation, censored/split spellings, wildcards,
and leetspeak. No model or video is required.

Run from the repository root or anywhere:

    python test/scanner_profiltration_test.py
"""
from __future__ import annotations

import os
import sys

# Allow importing scanner_engine.py from the repository root.
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

import scanner_engine as se  # noqa: E402

D = set(se.DEFAULT_PROFANITY)


def check(token, expected, label=""):
    actual = se.is_profanity(token, D)
    if actual != expected:
        raise AssertionError(
            f"{label}: is_profanity({token!r}) = {actual}, expected {expected}")
    tag = label or repr(token)
    print(f"  ok  {tag:40s} -> {actual}")


def test_direct_and_stems():
    check("fuck", True)
    check("fucking", True)
    check("fucked", True)
    # Moderate profanity that was missing before this hardening:
    check("bastard", True)
    check("damn", True)
    check("hell", True)


def test_leet():
    check("sh1t", True)
    check("4ss", True)
    check("4sshole", True)
    check("d1ck", True)


def test_split_spellings():
    check("f u c k", True)
    check("f.u.c.k", True)
    check("f-u-c-k", True)
    check("s h i t", True)
    check("d-a-r-n", False)  # "darn" is not a token nor contains one


def test_censored_wildcards():
    check("f*ck", True)
    check("f**k", True)
    check("sh*t", True)
    check("b*tch", True)
    check("d*mn", True)


def test_short_tokens_not_substrings():
    # len("ass") == 3 -> never a substring, so ordinary words are left alone.
    check("assistant", False)
    check("pass", False)
    check("class", False)
    check("bass", False)
    check("grass", False)


def test_clean_words_and_empty():
    check("", False)
    check("   ", False)
    check("hello", False)
    check("champion", False)


def main():
    se._log = lambda *a, **k: None
    tests = [
        test_direct_and_stems,
        test_leet,
        test_split_spellings,
        test_censored_wildcards,
        test_short_tokens_not_substrings,
        test_clean_words_and_empty,
    ]
    failures = 0
    for fn in tests:
        print(f"== {fn.__name__} ==")
        try:
            fn()
        except AssertionError as exc:
            failures += 1
            print(f"FAIL {fn.__name__}: {exc}")
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print(f"ERROR {fn.__name__}: {type(exc).__name__}: {exc}")
    print(f"\n{len(tests) - failures}/{len(tests)} groups passed.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()