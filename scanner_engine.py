#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
scanner_engine.py
=================
Safe Scene -- offline media scanner sidecar.

Scans a single media file locally (no internet access), flags profanity in the
audio track and explicit/nudity in the video track, and emits a
`<video>.safe.json` rule file consumed by the Safe Scene Flutter player.

Designed to be frozen with PyInstaller:

    pyinstaller --onefile --name scanner_engine ^
        --add-binary ffmpeg.exe;. --add-binary ffprobe.exe;. ^
        --add-data ggml-base.bin;models ^
        --add-data nudenet.onnx;models ^
        --add-data profanity.txt;models scanner_engine.py

Behaviours
----------
* ``--input <video>``            media file to scan (required)
* ``--output <json>``            explicit output path (optional; defaults to
                                 ``<video_stem>.safe.json`` next to the input)
* ``--models-dir <dir>``         directory holding the bundled AI assets
                                 (ggml-base.bin, nudenet.onnx, labels.json,
                                  profanity.txt, whisper-cli.exe)
* ``--provider <list>``          comma-separated ONNX Runtime providers in
                                 priority order: cpu,dml,cuda,tensorrt
                                 (default: cpu; unavailable ones are skipped)
* ``--threads <n>``              worker thread count for ONNX inference and
                                 whisper.cpp (default: auto)

Sub-systems (each degrades gracefully if its assets are missing):
  1. Audio  : ffmpeg -> 16 kHz mono WAV -> faster-whisper (word timestamps)
              or whisper.cpp subprocess -> profanity match -> "mute" segments.
  2. Visual : ffmpeg -> 1.5 FPS JPEG frames -> ONNX Runtime NudeNet/NSFW
              classifier/detector -> confidence > 0.65 -> "skip" segments.
  3. Post   : merge same-action segments within 2.5 s, add 750 ms buffer.
  4. IPC    : PROGRESS:<0..1> lines on stdout; result written to disk and
              echoed as a single RESULT:<json> line.

The emitted JSON matches the schema decoded by Safe Scene's
``lib/models/filter_segment.dart`` (see ROADMAP.md "Data Specification").
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import wave
from typing import Any

# ---------------------------------------------------------------------------
# Tuning constants
# ---------------------------------------------------------------------------
VERSION = "1.0.0"
AUDIO_SAMPLE_RATE = 16000          # Hz, per spec
FRAME_FPS = 1.5                    # frames per second, per spec
SAFETY_BUFFER_S = 0.750            # 750 ms, per spec
MERGE_WINDOW_S = 2.5               # merge gap, per spec
VISUAL_THRESHOLD = 0.65            # confidence gate, per spec
DEFAULT_CHUNK = 1 << 20            # 1 MiB, for hashing

# Wall-clock budgets for the long-running child-process stages. They prevent a
# slow or wedged tool from making the whole scan look frozen at one percentage:
# every stage streams live progress (so the bar moves every few seconds) and is
# killed once it exceeds its budget so the scan can always finish.
AUDIO_EXTRACT_RTF = 2.0           # ffmpeg WAV extraction assumed to run >= this x realtime
AUDIO_EXTRACT_BUDGET_MIN = 120.0  # seconds (absolute floor for short clips)
FRAME_EXTRACT_BUDGET_MIN = 180.0  # seconds (absolute floor for frame extraction)
WHISPER_MIN_RTF = 3.0             # whisper.cpp assumed to transcribe >= this x realtime
WHISPER_EST_RTF = 10.0            # optimistic throughput used for the live estimate
WHISPER_STARTUP_S = 20.0          # model load / warm-up allowance in the estimate
WHISPER_BUDGET_MIN = 120.0        # seconds
HEARTBEAT_S = 5.0                 # keep the UI alive even before first real progress

# NudeNet classifier label order (used when labels.json is absent).
CLASSIFIER_DEFAULT_LABELS = ["DRAWING", "HENTAI", "NEUTRAL", "PORN", "SEXY"]
# NudeNet detector label order (used only for display; every class is unsafe).
DETECTOR_DEFAULT_LABELS = [
    "FEMALE_GENITALIA_EXPOSED", "MALE_GENITALIA_EXPOSED", "EXPOSED_ANUS",
    "EXPOSED_BREAST", "EXPOSED_BUTTOCKS", "EXPOSED_FEMALE_GENITALIA",
    "EXPOSED_MALE_GENITALIA", "FEMALE_BREAST_EXPOSED", "MALE_BREAST_EXPOSED",
    "ANUS_EXPOSED", "BUTTOCKS_EXPOSED", "FEMALE_GENITALIA_COVERED",
]

# Default profanity dictionary (offline).  Overridable via profanity.txt in the
# models directory (one token per line, ``#`` starts a comment).
DEFAULT_PROFANITY = {
    # Intentionally kept conservative; the matcher also treats any long token
    # (>= 4 chars) as a substring stem ("fuck" also hits "fucking"/"fucked").
    "anus", "arse", "ass", "asshole", "bitch", "bitchass", "bitches",
    "blowjob", "bollocks", "boner", "boob", "bullshit", "butthole", "clit",
    "clitoris", "cock", "cocksucker", "coon", "crap", "cum", "cunt", "damn",
    "dick", "dickhead", "dildo", "dumbass", "dyke", "fag", "faggot", "fanny",
    "felch", "fellatio", "fuck", "fucked", "fucker", "fucking", "fucktard",
    "fuckwad", "goddamn", "goddamnit", "handjob", "homo", "jackass", "jerk",
    "jizz", "kike", "labia", "masturbat", "muff", "nazi", "nigga", "nigger",
    "niggers", "nipple", "nutsack", "paki", "pecker", "piss", "pisser",
    "pissed", "porn", "porno", "prick", "pube", "pussy", "queef", "queer",
    "rape", "rapist", "retard", "rimjob", "scrotum", "shit", "shitass",
    "shitbag", "shithead", "sperm", "spic", "spunk", "tits", "tit", "titty",
    "turd", "twat", "vagina", "vulva", "wank", "whore", "wtf",
}
# make sure lower-case + strip blank lines from the literal set
DEFAULT_PROFANITY = {w.strip().lower() for w in DEFAULT_PROFANITY if w.strip()}


def _log(msg: str) -> None:
    """Plain human-readable diagnostic line (stderr keeps stdout clean for IPC)."""
    print(f"[scanner] {msg}", file=sys.stderr, flush=True)


def _progress(fraction: float) -> None:
    """Emit the machine-readable progress line the Flutter side watches."""
    fraction = max(0.0, min(1.0, float(fraction)))
    sys.stdout.write(f"PROGRESS:{fraction:.4f}\n")
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# Executable / model resource resolution (bundled, 100% offline)
# ---------------------------------------------------------------------------
def _bundle_roots() -> list:
    """Candidate directories that may hold bundled binaries/models."""
    roots = []
    if hasattr(sys, "_MEIPASS"):            # PyInstaller onefile extraction
        roots.append(sys._MEIPASS)
    try:
        roots.append(os.path.dirname(os.path.abspath(sys.executable)))
    except Exception:
        pass
    roots.append(os.path.dirname(os.path.abspath(__file__)))
    return [r for r in roots if r]


def find_file(name: str, models_dir: str | None = None) -> str | None:
    """Locate ``name`` in the models dir, bundle roots, CWD, then PATH."""
    if os.path.isabs(name) and os.path.isfile(name):
        return name
    candidates = []
    if models_dir:
        candidates.append(os.path.join(models_dir, name))
    for root in _bundle_roots():
        candidates.append(os.path.join(root, name))
        candidates.append(os.path.join(root, "models", name))
        candidates.append(os.path.join(root, "bin", name))
    candidates.append(name)
    for cand in candidates:
        if os.path.isfile(cand):
            return cand
    return None


def _which(name: str, models_dir: str | None = None,
           override: str | None = None) -> str | None:
    if override:
        return override if os.path.isfile(override) else None
    found = find_file(name, models_dir)
    if found:
        return found
    # Windows: also search the same locations using the executable extension
    # (e.g. a whisper.cpp CLI shipped as "whisper-cli.exe" rather than "whisper-cli").
    if os.name == "nt" and not name.lower().endswith(".exe"):
        found = find_file(name + ".exe", models_dir)
        if found:
            return found
    return shutil.which(name)


def run_cmd(argv: list, **kwargs) -> subprocess.CompletedProcess:
    """Run a command; always UTF-8 so non-ASCII media names survive."""
    kwargs.setdefault("encoding", "utf-8")
    kwargs.setdefault("errors", "replace")
    return subprocess.run(argv, **kwargs)


def _run_streamed(argv: list, on_line=None, timeout_s=None, tail_cap=40):
    """
    Run a child process while streaming its line-delimited stdout/stderr.

    ``on_line(text)`` is invoked for every decoded line (both streams are fed
    in---diagnostics live on stderr). A ``timeout_s`` bounds the whole call:
    on expiry the child is killed and ``None`` is returned as the exit code so
    callers can degrade gracefully instead of wedging the scan.

    Returns ``(returncode, tail)`` where ``tail`` is the most recent lines
    (kept for diagnostics). Reads both pipes from daemon threads, so a chatty
    child can never deadlock the parent.
    """
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0
    try:
        proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            creationflags=flags,
        )
    except OSError as exc:
        _log(f"Could not launch {argv[0]!r}: {exc}")
        return None, []

    tail = []

    def _pump(stream):
        try:
            for raw in iter(stream.readline, b""):
                text = raw.decode("utf-8", "replace").rstrip("\r\n")
                if not text:
                    continue
                tail.append(text)
                if len(tail) > tail_cap:
                    del tail[0]
                if on_line:
                    try:
                        on_line(text)
                    except Exception:  # noqa: BLE001
                        pass
        finally:
            try:
                stream.close()
            except Exception:  # noqa: BLE001
                pass

    threads = [
        threading.Thread(target=_pump, args=(proc.stdout,), daemon=True),
        threading.Thread(target=_pump, args=(proc.stderr,), daemon=True),
    ]
    for t in threads:
        t.start()

    try:
        proc.wait(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        _log(f"{argv[0]!r} exceeded its {timeout_s:.0f}s time budget; killing it.")
        proc.kill()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    except Exception:  # noqa: BLE001
        proc.kill()
    for t in threads:
        t.join(timeout=5)
    return proc.returncode, tail


def _ffmpeg_progress_fraction(line: str, state: dict, duration_s: float) -> float | None:
    """
    Parse one ``... -progress pipe:1`` line; return a 0..1 completion fraction
    for the current ffmpeg run, or None when the line carries no timing info.
    ``state`` is the caller-owned key->value map ffmpeg builds across lines.
    """
    key, _, value = line.partition("=")
    if value:
        state[key.strip()] = value.strip()
    if duration_s <= 0.0:
        return None
    if state.get("out_time_us", "").lstrip("+-").isdigit():
        return max(0.0, min(1.0,
                            int(state["out_time_us"]) / (max(duration_s, 1.0) * 1_000_000.0)))
    if state.get("out_time_ms", "").lstrip("+-").isdigit():
        return max(0.0, min(1.0,
                            int(state["out_time_ms"]) / (max(duration_s, 1.0) * 1000.0)))
    return None


def _wav_duration_sec(path: str) -> float:
    """Best-effort WAV duration via the stdlib ``wave`` module (0.0 on any error)."""
    try:
        with wave.open(path, "rb") as wf:
            rate = wf.getframerate() or AUDIO_SAMPLE_RATE
            return wf.getnframes() / float(rate)
    except Exception:  # noqa: BLE001
        return 0.0
# ---------------------------------------------------------------------------
# Media utilities (duration + SHA-256)
# ---------------------------------------------------------------------------
def media_hash(path: str) -> str:
    """Streamed SHA-256 so huge files don't need loading into memory."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            block = fh.read(DEFAULT_CHUNK)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def media_duration(path: str, ffprobe: str | None) -> float:
    """Return the media duration in seconds via ffprobe (or an ffmpeg fallback)."""
    if ffprobe:
        try:
            out = subprocess.run(
                [ffprobe, "-v", "error", "-show_entries",
                 "format=duration", "-of", "default=noprint_wrappers=1:nokey=1",
                 path],
                capture_output=True, text=True, errors="replace",
            )
            if out.returncode == 0 and out.stdout.strip():
                return float(out.stdout.strip().splitlines()[0])
        except Exception as exc:  # noqa: BLE001
            _log(f"ffprobe duration failed ({exc}); trying ffmpeg fallback.")

    ffmpeg = _which("ffmpeg", None)
    if not ffmpeg:
        return 0.0
    try:
        proc = subprocess.run(
            [ffmpeg, "-hide_banner", "-i", path, "-f", "null", "-"],
            capture_output=True, text=True, errors="replace",
        )
        match = re.search(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", proc.stderr)
        if match:
            hh, mm, ss = match.groups()
            return int(hh) * 3600 + int(mm) * 60 + float(ss)
    except Exception as exc:  # noqa: BLE001
        _log(f"ffmpeg duration fallback failed: {exc}")
    return 0.0


# ---------------------------------------------------------------------------
# Profanity dictionary + word normalisation
# ---------------------------------------------------------------------------
_LEET = str.maketrans({
    "4": "a", "@": "a", "8": "b", "3": "e", "1": "i", "!": "i", "0": "o",
    "5": "s", "$": "s", "7": "t", "9": "g", "2": "z",
})


def load_profanity(models_dir: str | None) -> set:
    """Load tokens from profanity.txt if present, else the embedded default."""
    custom = find_file("profanity.txt", models_dir)
    if not custom:
        return set(DEFAULT_PROFANITY)
    tokens = set()
    try:
        with open(custom, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or line.startswith("//"):
                    continue
                tokens.add(line.lower())
    except OSError as exc:  # noqa: BLE001
        _log(f"Could not read {custom}: {exc}; using embedded dictionary.")
        return set(DEFAULT_PROFANITY)
    return tokens


def clean_word(raw: str) -> str:
    """Lower-case, map leetspeak, strip everything that is not a-z."""
    w = raw.lower().translate(_LEET)
    return re.sub(r"[^a-z]", "", w)


def is_profanity(word: str, dictionary: set) -> bool:
    """
    True when the cleaned word is a dictionary token or contains a long
    (>= 4 char) token as a stem.  Short tokens (e.g. "ass") are excluded from
    substring matching so ordinary words like "class"/"pass" are not flagged,
    while "fuck" still catches "fucking"/"fucked".
    """
    w = clean_word(word)
    if not w:
        return False
    if w in dictionary:
        return True
    if any(t in w for t in dictionary if len(t) >= 4):
        return True
    return False
# ---------------------------------------------------------------------------
# Audio analysis
# ---------------------------------------------------------------------------
def extract_audio(ffmpeg: str, video: str, wav_path: str,
                  duration_s: float = 0.0, on_progress=None) -> bool:
    """
    ffmpeg -> 16 kHz mono PCM S16LE WAV (per spec):
        ffmpeg -i <input> -vn -ar 16000 -ac 1 -c:a pcm_s16le <wav>
    Streams ffmpeg's ``-progress pipe:1`` output so ``on_progress(0..1)`` is
    called while extraction runs, and enforces a wall-clock budget so the scan
    can never wedge on a slow/corrupt file.  Returns True on success.
    """
    budget_s = min(3600.0, max(AUDIO_EXTRACT_BUDGET_MIN,
                               duration_s * AUDIO_EXTRACT_RTF))
    start_t = time.monotonic()
    last = 0.0
    state: dict = {}

    def on_line(line: str) -> None:
        nonlocal last
        if not on_progress:
            return
        frac = _ffmpeg_progress_fraction(line, state, duration_s)
        if frac is None:
            # No timing info yet (orphaned/duplicated stream, ffprobe-less
            # duration); nudge forward by wall clock so the bar is never frozen.
            frac = min(1.0, (time.monotonic() - start_t) / 30.0)
        frac = min(1.0, frac)
        if frac - last >= 0.01:
            last = frac
            on_progress(frac)

    cmd = [
        ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
        "-nostats", "-progress", "pipe:1",
        "-i", video,
        "-vn", "-ar", str(AUDIO_SAMPLE_RATE), "-ac", "1",
        "-c:a", "pcm_s16le", wav_path,
    ]
    returncode, tail = _run_streamed(cmd, on_line=on_line, timeout_s=budget_s)
    if returncode is None:
        _log(f"Audio extraction timed out after {budget_s:.0f}s; audio analysis skipped.")
        return False
    if returncode != 0:
        _log(f"Audio extraction failed: {tail[-3] if len(tail) > 2 else ' '.join(tail)}")
        return False
    if not os.path.isfile(wav_path) or os.path.getsize(wav_path) == 0:
        _log("Audio extraction produced an empty file.")
        return False
    return True


def transcribe_faster_whisper(model_dir: str | None, wav_path: str, model_path: str):
    """
    faster-whisper backend: returns a list of (word, start_s, end_s) tuples.
    Uses word-level timestamps via ``word_timestamps=True``.
    """
    from faster_whisper import WhisperModel  # bundled at build time; optional  # type: ignore[import-not-found]

    model = WhisperModel(model_path, device="cpu", compute_type="int8")
    segments, _info = model.transcribe(
        wav_path, word_timestamps=True, vad_filter=True,
    )
    words = []
    for seg in segments:
        for w in getattr(seg, "words", None) or []:
            start = float(getattr(w, "start", 0.0))
            end = float(getattr(w, "end", start))
            text = str(getattr(w, "word", "") or "")
            if text:
                words.append((text, start, end))
    return words


def transcribe_whisper_cpp(cli_path, model_path, wav_path, threads=None,
                           progress=None):
    """
    whisper.cpp subprocess backend: runs the CLI with full JSON output and
    parses word-level timestamps when present; otherwise distributes each
    segment's text evenly across its time window to approximate timestamps.
    Returns a list of (word, start_s, end_s) tuples.

    The runner adds ``-pp`` (print progress) so whisper.cpp's per-batch
    percentage can be parsed from stderr and streamed to ``progress(pct)`` in
    real time (verified: the callback writes to stderr even when redirected).
    A wall-clock budget derived from the WAV length bounds the call, so a
    wedged binary degrades to "audio skipped" instead of freezing the scan at
    5%. A heartbeat keeps ``progress`` moving until the first real percent.
    """
    progress = progress or (lambda _f: None)

    wav_dur = _wav_duration_sec(wav_path)
    budget_s = float(max(WHISPER_BUDGET_MIN, wav_dur / WHISPER_MIN_RTF))
    # Expected wall time used only to animate the pre-first-percent window;
    # real `progress = N%` lines from the CLI replace it as soon as they land.
    est_total = float(max(1.0, wav_dur / WHISPER_EST_RTF + WHISPER_STARTUP_S))

    json_base = os.path.splitext(wav_path)[0] + "_whisper"
    cmd = [
        cli_path, "-m", model_path, "-f", wav_path,
        "-ojf", "-of", json_base,   # -ojf => token-level timestamps
        "-l", "auto", "-np", "-pp", # -pp => live progress lines on stderr
    ]
    if threads and threads > 0:
        cmd += ["-t", str(threads)]

    start_t = time.monotonic()
    reported = [0.0]

    def _emit(pct):
        pct = max(0.0, min(0.9, pct))
        if pct > reported[0]:
            reported[0] = pct
            progress(pct)

    def on_line(line: str) -> None:
        m = re.search(r"progress\s*=\s*(\d{1,3})\s*%", line)
        if m:
            _emit(int(m.group(1)) / 100.0)

    stop_hb = threading.Event()

    def _heartbeat() -> None:
        # whisper.cpp only prints progress when a batch completes; until then
        # (and if a different build skips -pp) move the estimate so the bar
        # never appears frozen.
        while not stop_hb.is_set():
            if stop_hb.wait(HEARTBEAT_S):
                break
            elapsed = time.monotonic() - start_t
            estimate = min(elapsed / est_total, elapsed / budget_s, 0.7)
            if estimate > reported[0]:
                _emit(estimate)

    hb = threading.Thread(target=_heartbeat, daemon=True)
    hb.start()
    try:
        returncode, tail = _run_streamed(cmd, on_line=on_line, timeout_s=budget_s)
    finally:
        stop_hb.set()
        hb.join(timeout=1)

    if returncode is None:
        _log(f"whisper.cpp timed out after {budget_s:.0f}s; audio analysis skipped.")
        return []
    if returncode != 0:
        _log(f"whisper.cpp failed: {tail[-3] if len(tail) > 2 else ' '.join(tail)}")
        return []

    json_path = json_base + ".json"
    if not os.path.isfile(json_path):
        _log("whisper.cpp produced no JSON output.")
        return []

    with open(json_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    return parse_whisper_json(data)


def parse_whisper_json(data: dict) -> list:
    """Parse word timestamps from either whisper.cpp JSON layout.

    New format (>= 1.7): ``data["transcription"]`` is a *list* of segments;
    each segment carries ``offsets.{from,to}`` (ms) and a ``tokens`` array of
    ``{text, offsets}`` entries.
    Old format: ``data["transcription"]["segments"]`` (a dict) with ``t1/t2``
    (seconds) and ``words`` as ``{w, t: [start, end]}``.

    Returns a list of (word, start_s, end_s) tuples.
    """
    root = data.get("transcription") or data.get("result") or data
    if isinstance(root, list):
        return _parse_whisper_segments_new(root)
    if isinstance(root, dict):
        return _parse_whisper_segments_old(root)
    return []


def _parse_whisper_segments_new(segments: list) -> list:
    """whisper.cpp >= 1.7: transcription is a list; times are ms in `offsets`."""
    words: list = []
    for seg in segments:
        if not isinstance(seg, dict):
            continue
        seg_text = str(seg.get("text", "") or "")
        offs = seg.get("offsets") or {}
        seg_from = float(offs.get("from", 0)) / 1000.0 if offs else 0.0
        seg_to = float(offs.get("to", 0)) / 1000.0 if offs else seg_from

        toks = seg.get("tokens") or seg.get("words") or []
        if toks:
            for w in toks:
                if not isinstance(w, dict):
                    continue
                wtext = str(w.get("text") or w.get("w") or "")
                if not wtext:
                    continue
                woffs = w.get("offsets") or {}
                if woffs:
                    start = float(woffs.get("from", 0)) / 1000.0
                    end = float(woffs.get("to", start)) / 1000.0
                else:
                    ts = w.get("t")
                    if isinstance(ts, (list, tuple)) and len(ts) == 2:
                        start, end = float(ts[0]), float(ts[1])
                    else:
                        continue
                words.append((wtext, start, end))
        else:
            _distribute_words(seg_text, seg_from, seg_to, words)
    return words


def _parse_whisper_segments_old(root: dict) -> list:
    """whisper.cpp < 1.7: transcription is a dict with a `segments` list."""
    words: list = []
    for seg in root.get("segments") or []:
        seg_words = seg.get("words") or []
        t1 = float(seg.get("t1", 0.0))
        t2 = float(seg.get("t2", t1))
        if seg_words:
            for w in seg_words:
                wtext = str(w.get("w", "") or "")
                ts = w.get("t") or [t1, t2]
                words.append((wtext, float(ts[0]), float(ts[1])))
        else:
            _distribute_words(str(seg.get("text", "") or ""), t1, t2, words)
    return words


def _distribute_words(text: str, t1: float, t2: float, out: list) -> None:
    """Evenly distribute ``text``'s tokens across ``[t1, t2]``."""
    tokens = [t for t in re.split(r"\s+", text) if t]
    if tokens and t2 > t1:
        span = (t2 - t1) / len(tokens)
        for i, tok in enumerate(tokens):
            out.append((tok, t1 + i * span, t1 + (i + 1) * span))
    elif tokens:
        for tok in tokens:
            out.append((tok, t1, t1))


def run_audio_analysis(ffmpeg, video, tmpdir, models_dir, whisper_cpp,
                       threads=None, progress=None, duration_s=0.0):
    """
    Returns a list of raw mute segments [(start_s, end_s, word)] discovered by
    transcribing the audio and matching words against the profanity dictionary.

    ``progress(fraction)`` receives the *overall* completion fraction for this
    stage (5%..40% of the whole scan) so the UI never sits frozen at 5%.
    """
    report = progress or _progress
    dictionary = load_profanity(models_dir)
    hits = []

    wav_path = os.path.join(tmpdir, "temp_audio.wav")
    if not extract_audio(ffmpeg, video, wav_path, duration_s=duration_s,
                         on_progress=lambda f: report(0.05 + 0.07 * f)):
        _log("Skipping audio analysis (could not extract audio).")
        return hits
    report(0.12)

    transcription = _transcribe(wav_path, models_dir, whisper_cpp, threads=threads,
                                progress=lambda f: report(0.12 + 0.26 * f))
    for word, start, end in transcription:
        if is_profanity(word, dictionary):
            hits.append((start, end, word))

    _log(f"Audio: transcribed {len(transcription)} words, "
         f"{len(hits)} profanity hits.")
    return hits


def _transcribe(wav_path, models_dir, whisper_cpp, threads=None, progress=None):
    """Prefer the bundled whisper.cpp CLI (the roadmap audio engine), falling
    back to faster-whisper (which requires a CTranslate2-format model)."""
    model_file = find_file("ggml-base.bin", models_dir)
    if whisper_cpp and model_file:
        return transcribe_whisper_cpp(
            whisper_cpp, model_file, wav_path, threads=threads, progress=progress)
    try:
        return transcribe_faster_whisper(models_dir, wav_path, model_file or "")
    except Exception as exc:  # noqa: BLE001
        _log(f"faster-whisper unavailable ({exc}); audio analysis skipped.")
    _log("No working transcription backend found; audio analysis skipped.")
    return []
# ---------------------------------------------------------------------------
# Visual analysis
# ---------------------------------------------------------------------------
def extract_frames(ffmpeg: str, video: str, frames_dir: str,
                   duration_s: float = 0.0, on_progress=None) -> list:
    """
    ffmpeg -> 1.5 FPS JPEG frames (per spec):
        ffmpeg -i <input> -vf "fps=1.5" -q:v 2 temp_frames/frame_%06d.jpg
    Streams live completion through ``on_progress(0..1)`` and enforces a
    wall-clock budget so a slow/corrupt file cannot wedge the scan.
    Returns the sorted list of extracted frame paths (oldest first).
    """
    os.makedirs(frames_dir, exist_ok=True)
    pattern = os.path.join(frames_dir, "frame_%06d.jpg")

    budget_s = min(3600.0, max(FRAME_EXTRACT_BUDGET_MIN,
                               duration_s * AUDIO_EXTRACT_RTF))
    start_t = time.monotonic()
    last = 0.0
    state: dict = {}

    def on_line(line: str) -> None:
        nonlocal last
        if not on_progress:
            return
        frac = _ffmpeg_progress_fraction(line, state, duration_s)
        if frac is None:
            frac = min(1.0, (time.monotonic() - start_t) / 30.0)
        frac = min(1.0, frac)
        if frac - last >= 0.01:
            last = frac
            on_progress(frac)

    cmd = [
        ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
        "-nostats", "-progress", "pipe:1",
        "-i", video,
        "-vf", f"fps={FRAME_FPS}", "-q:v", "2", pattern,
    ]
    returncode, tail = _run_streamed(cmd, on_line=on_line, timeout_s=budget_s)
    if returncode is None:
        _log(f"Frame extraction timed out after {budget_s:.0f}s; using partial frames.")
    elif returncode != 0:
        _log(f"Frame extraction failed: {tail[-3] if len(tail) > 2 else ' '.join(tail)}")

    frames = sorted(
        p for p in _walk_frames(frames_dir)
        if re.search(r"frame_\d{6}\.jpg$", p, re.IGNORECASE)
    )
    _log(f"Visual: extracted {len(frames)} frames.")
    return frames


def _walk_frames(frames_dir: str):
    for entry in os.listdir(frames_dir):
        yield os.path.join(frames_dir, entry)


def _frame_number(path: str) -> int:
    """Extract the 1-based frame index from ``frame_000123.jpg``."""
    m = re.search(r"frame_(\d+)\.jpg$", path, re.IGNORECASE)
    return int(m.group(1)) if m else 0


def load_model(onnx_path: str, models_dir: str | None,
               providers_req: str | None = None, threads: int | None = None):
    """Load the ONNX session + labels; returns (session, labels, model_type)."""
    try:
        import onnxruntime as ort  # bundled at build time; optional  # type: ignore[import-not-found]
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(f"onnxruntime not available: {exc}")

    providers = resolve_providers(providers_req)
    if providers_req and providers_req.lower().strip() not in ("", "cpu"):
        _log(f"Requested ONNX providers '{providers_req}'; using {providers}.")

    sess_options = build_session_options(threads)
    try:
        session = ort.InferenceSession(
            onnx_path, sess_options=sess_options, providers=providers)
    except Exception as exc:  # noqa: BLE001
        _log(f"Session creation failed with {providers} ({exc}); retrying CPU.")
        session = ort.InferenceSession(
            onnx_path, sess_options=sess_options,
            providers=["CPUExecutionProvider"])

    active = session.get_providers()
    _log("ONNX active providers: " + ", ".join(active)
         + (f"; threads={threads}" if threads else "; threads=auto"))
    model_type = _classify_model(session)
    labels = _load_labels(models_dir, model_type)
    return session, labels, model_type


def build_session_options(threads: int | None):
    """ONNX Runtime session options with explicit worker-thread tuning."""
    import onnxruntime as ort
    opts = ort.SessionOptions()
    if threads and threads > 0:
        opts.intra_op_num_threads = threads
        opts.inter_op_num_threads = max(1, (threads + 1) // 2)
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    return opts


def resolve_providers(requested: str | None) -> list:
    """Map a comma-separated provider request to installed onnxruntime
    provider names (in priority order), always keeping CPU as the fallback.

    ``--provider cpu,dml`` tries DirectML first (needs the onnxruntime-directml
    build) and falls back to CPU when the provider is not installed.
    """
    import onnxruntime as ort
    available = set(ort.get_available_providers())
    if not requested:
        return ["CPUExecutionProvider"]
    names = {
        "cpu": "CPUExecutionProvider",
        "dml": "DmlExecutionProvider",
        "directml": "DmlExecutionProvider",
        "cuda": "CUDAExecutionProvider",
        "tensorrt": "TensorrtExecutionProvider",
        "coreml": "CoreMLExecutionProvider",
    }
    providers = []
    for key in (p.strip().lower() for p in requested.split(",") if p.strip()):
        name = names.get(key)
        if name and name in available and name not in providers:
            providers.append(name)
    if "CPUExecutionProvider" not in providers:
        providers.append("CPUExecutionProvider")
    return providers


def _load_labels(models_dir: str | None, model_type: str) -> list:
    custom = find_file("labels.json", models_dir)
    if custom:
        try:
            with open(custom, "r", encoding="utf-8") as fh:
                raw = json.load(fh)
            if isinstance(raw, list):
                return raw
            if isinstance(raw, dict) and isinstance(raw.get("labels"), list):
                return raw["labels"]
        except (OSError, ValueError) as exc:  # noqa: BLE001
            _log(f"Could not read {custom}: {exc}")
    if model_type == "detector":
        return list(DETECTOR_DEFAULT_LABELS)
    return list(CLASSIFIER_DEFAULT_LABELS)


def _classify_model(session) -> str:
    """Heuristic: detector graphs emit 2 outputs (boxes + [N,25200,C] scores)."""
    outputs = session.get_outputs()
    for out in outputs:
        shape = out.shape
        if len(shape) == 3 and len(shape) >= 2 and shape[-2] == 25200:
            return "detector"
        if len(shape) == 3 and shape[0] == 25200:
            return "detector"
    return "classifier"


def _input_spatial(session) -> tuple:
    """Return (height, width, channels_first) matching the model's first input."""
    inp = session.get_inputs()[0]
    shape = inp.shape
    # Try to resolve a concrete spatial size (None/0 mean dynamic).
    dims = [int(d) if isinstance(d, int) and d and d > 0 else None for d in shape]
    if len(dims) >= 3 and dims[-1] in (3, 1):            # NHWC
        h, w = dims[-3], dims[-2]
        c = dims[-1]
        return (h or 320, w or 320, False), c
    if len(dims) >= 3 and dims[-3] in (3, 1):            # NCHW
        c, h, w = dims[-3], dims[-2], dims[-1]
        return (h or 320, w or 320, True), c
    return (320, 320, True), 3


# numpy is only needed for the visual path; onnxruntime also requires it.
try:
    import numpy as np  # type: ignore[import-not-found]
except Exception:  # noqa: BLE001
    np = None


def _decode_pil(frames, out_w, out_h):
    """Yield (frame_index, rgb HxWx3 uint8) decoding the extracted JPEGs."""
    try:
        from PIL import Image
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(f"Pillow not available: {exc}")

    for i, path in enumerate(frames):
        with Image.open(path) as im:
            if im.mode != "RGB":
                im = im.convert("RGB")
            im = im.resize((out_w, out_h), Image.BILINEAR)
            yield i, (np.asarray(im, dtype=np.uint8), path)


def _decode_raw(ffmpeg, video, out_w, out_h):
    """Yield (frame_index, rgb HxWx3 uint8) resized via a single ffmpeg pipe."""
    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-i", video,
        "-vf", f"fps={FRAME_FPS},scale={out_w}:{out_h}",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
    ]
    frame_bytes = out_w * out_h * 3
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    i = 0
    try:
        while True:
            chunk = proc.stdout.read(frame_bytes)
            if len(chunk) < frame_bytes:
                break
            arr = np.frombuffer(chunk, dtype=np.uint8).reshape(out_h, out_w, 3)
            yield i, (arr, f"frame_{i+1:06d}")
            i += 1
    finally:
        proc.stdout.close()
        proc.wait()


def _make_input(arr, nchw: bool) -> Any:
    """Normalise to [0,1] float and add the NCHW/NHWC batch dim as required."""
    a = np.asarray(arr, dtype=np.float32) / 255.0
    if nchw:
        a = a.transpose(2, 0, 1)          # HWC -> CHW
    return a[None, ...]                    # add batch


def _interpret_detector(outs, labels, threshold):
    """Best-effort detector parse. Returns (conf, label) or (0.0, '')."""
    best = None
    for o in outs:
        a = None
        try:
            a = np.asarray(o, dtype=np.float32)
        except Exception:  # noqa: BLE001
            continue
        if a.ndim >= 2 and 25200 in a.shape:
            if best is None or a.shape[-1] > best[1]:
                best = (a, a.shape[-1])
    if best is None:
        return 0.0, ""
    arr = best[0].reshape(-1, best[1])
    flat = arr.max(axis=1)                 # high score per anchor
    anchor = int(flat.argmax())
    conf = float(flat[anchor])
    label_idx = int(arr[anchor].argmax())
    label = labels[label_idx] if label_idx < len(labels) else f"class_{label_idx}"
    return conf, label


def _interpret_classifier(outs, labels, threshold, safe_idx):
    """Classifier output -> (conf, label). Every non-neutral class is unsafe."""
    raw = None
    for o in outs:
        try:
            raw = np.asarray(o, dtype=np.float32)
            break
        except Exception:  # noqa: BLE001
            continue
    if raw is None:
        return 0.0, ""
    probs = raw.reshape(-1)
    idx = int(probs.argmax())
    conf = float(probs[idx])
    label = labels[idx] if idx < len(labels) else f"class_{idx}"
    if idx in safe_idx:
        return 0.0, label
    return conf, label


def run_visual_analysis(ffmpeg, video, tmpdir, models_dir, frames,
                        providers_req=None, threads=None,
                        progress=None, progress_floor=0.42):
    """
    Return a list of raw skip segments
    [(start_s, end_s, confidence, label)] for frames whose NSFW confidence
    exceeds VISUAL_THRESHOLD.

    ``progress(fraction)`` receives the *overall* completion fraction while the
    inference loop runs (starting at ``progress_floor``, ending at 95%), so the
    animation hand-off from frame extraction is seamless.
    """
    report = progress or _progress
    onnx_path = find_file("nudenet.onnx", models_dir)
    if not onnx_path:
        _log("No nudenet.onnx model found; visual analysis skipped.")
        return []

    try:
        session, labels, model_type = load_model(
            onnx_path, models_dir,
            providers_req=providers_req, threads=threads)
    except Exception as exc:  # noqa: BLE001
        _log(f"ONNX session load failed ({exc}); visual analysis skipped.")
        return []

    (out_h, out_w, nchw), _c = _input_spatial(session)
    input_name = session.get_inputs()[0].name
    safe_idx = _safe_indices(labels)

    try:
        decoder = lambda: _decode_pil(frames, out_w, out_h)
        next(decoder())                     # verify Pillow works
        source = decoder()
    except Exception:  # noqa: BLE001
        _log("Pillow unavailable; using ffmpeg raw frame pipe.")
        source = _decode_raw(ffmpeg, video, out_w, out_h)

    hits = []
    total = max(1, len(frames))
    for i, (arr, _path) in source:
        feed = _make_input(arr, nchw)
        if feed is None:
            continue
        try:
            outs = session.run(None, {input_name: feed})
        except Exception as exc:  # noqa: BLE001
            _log(f"Frame {i} inference failed: {exc}")
            continue

        if model_type == "detector":
            conf, label = _interpret_detector(outs, labels, VISUAL_THRESHOLD)
        else:
            conf, label = _interpret_classifier(
                outs, labels, VISUAL_THRESHOLD, safe_idx)

        if conf > VISUAL_THRESHOLD:
            start = i / FRAME_FPS
            end = (i + 1) / FRAME_FPS
            hits.append((start, end, conf, label))

        if i % 20 == 0:
            report(progress_floor + (0.95 - progress_floor) * (i + 1) / total)

    _log(f"Visual: {len(hits)} flagged frames of {total}.")
    return hits


def _safe_indices(labels) -> set:
    """Indices whose labels are neutral/safe (e.g. NEUTRAL). Detector has none."""
    safe = set()
    for i, lbl in enumerate(labels):
        u = str(lbl).upper()
        if u in {"NEUTRAL", "SAFE", "SFW", "NONEXPLICIT"}:
            safe.add(i)
    if not safe and len(labels) == len(CLASSIFIER_DEFAULT_LABELS):
        try:
            safe.add(labels.index("NEUTRAL"))
        except ValueError:
            pass
    return safe
# ---------------------------------------------------------------------------
# Post-processing: merge + safety buffer + JSON output
# ---------------------------------------------------------------------------
def merge_segments(segments, gap_window=MERGE_WINDOW_S):
    """Merge overlapping or close (gap <= gap_window) intervals in-place."""
    segments = sorted(segments, key=lambda x: (x[0], x[1]))
    merged = []
    for seg in segments:
        if merged and seg[0] - merged[-1][1] <= gap_window:
            merged[-1] = (merged[-1][0], max(merged[-1][1], seg[1]))
        else:
            merged.append((seg[0], seg[1]))
    return merged


def apply_buffer(segments, pad=SAFETY_BUFFER_S, duration_s=0.0):
    """Expand each [start, end] by pad on both sides, clamped to [0, duration]."""
    out = []
    for s, e in segments:
        s = max(0.0, s - pad)
        e = min(duration_s, e + pad)
        if e > s:
            out.append((s, e))
    return out


def word_segments_to_intervals(hits):
    """[(start_s, end_s, word)] -> [(start_s, end_s)]."""
    return [(s, e) for (s, e, _w) in hits]


def visual_intervals_to_mergeable(hits):
    """[(start_s, end_s, conf, label)] -> list of (start_s, end_s, conf, label)."""
    return hits


def build_segments_json(merged_list, action, category, source, confidence_fn):
    """
    Convert merged interval lists into the schema used by FilterSegment.
    Returns a list of dicts.
    """
    out = []
    for idx, item in enumerate(merged_list):
        s, e = item[0], item[1]
        conf = confidence_fn(item)
        out.append({
            "id": f"seg_{idx + 1:03d}",
            "start_ms": int(round(s * 1000)),
            "end_ms": int(round(e * 1000)),
            "action": action,
            "category": category,
            "confidence": round(conf, 4),
            "source": source,
        })
    return out


def postprocess(mute_hits, skip_hits, duration_s):
    """Merge/buffer both kinds of hits and return ready-to-serialize segments."""
    mute_intervals = word_segments_to_intervals(mute_hits)
    skip_intervals = [(s, e) for (s, e, _c, _l) in skip_hits]

    mute_merged = apply_buffer(
        merge_segments(mute_intervals), duration_s=duration_s)
    skip_merged = apply_buffer(
        merge_segments(skip_intervals), duration_s=duration_s)

    mute_json = build_segments_json(
        mute_merged, "mute", "profanity", "ai_whisper",
        lambda item: 1.0)
    skip_json = build_segments_json(
        skip_merged, "skip", "explicit_nudity", "ai_nudenet",
        lambda item: max((c for s, e, c, l in skip_hits
                          if s >= item[0] - 1e-6 and e <= item[1] + 1e-6), default=1.0))

    all_segments = sorted(mute_json + skip_json, key=lambda x: x["start_ms"])
    # Renumber ids sequentially across the merged, sorted list.
    for i, seg in enumerate(all_segments):
        seg["id"] = f"seg_{i + 1:03d}"
    return all_segments


def media_title(path: str) -> str:
    return os.path.basename(os.path.abspath(path))


def default_output_path(input_path: str) -> str:
    root, _ext = os.path.splitext(os.path.abspath(input_path))
    return root + ".safe.json"


def write_result(path: str, result: dict) -> str:
    """Persist result, return the compact one-line JSON for the RESULT line."""
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2, ensure_ascii=False)
    return json.dumps(result, separators=(",", ":"), ensure_ascii=False)
# ---------------------------------------------------------------------------
# Orchestration / CLI
# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="scanner_engine",
        description="Safe Scene offline media scanner sidecar.",
    )
    p.add_argument("--input", metavar="VIDEO", required=True,
                   help="path to the media file to scan")
    p.add_argument("--output", metavar="JSON", default=None,
                   help="explicit output path (default: '<video_stem>.safe.json')")
    p.add_argument("--models-dir", metavar="DIR", default=None,
                   help="directory containing bundled AI assets")
    p.add_argument("--ffmpeg", default=None, help="override path to ffmpeg")
    p.add_argument("--ffprobe", default=None, help="override path to ffprobe")
    p.add_argument("--whisper-cli", default=None,
                   help="override path to whisper.cpp CLI")
    p.add_argument("--provider", default="cpu",
                   help="comma-separated ONNX Runtime providers in priority "
                        "order: cpu,dml,cuda,tensorrt (default: cpu)")
    p.add_argument("--threads", type=int, default=None,
                   help="worker thread count for ONNX inference and "
                        "whisper.cpp (default: auto)")
    p.add_argument("--temp-dir", default=None,
                   help="directory for intermediate files (default: system temp)")
    p.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    return p


def run_scan(args) -> int:
    input_path = os.path.abspath(args.input)
    if not os.path.isfile(input_path):
        _log(f"Input file not found: {input_path}")
        return 1

    _progress(0.01)

    ffmpeg = _which("ffmpeg", args.models_dir, args.ffmpeg)
    ffprobe = _which("ffprobe", args.models_dir, args.ffprobe)
    whisper_cpp = _which("whisper-cli", args.models_dir, args.whisper_cli)
    if not whisper_cpp:
        # whisper.cpp builds are often shipped as "main"/"main.exe". Only accept
        # real executables so PATH lookups cannot resolve to system control
        # panel applets (e.g. main.cpl) that are not runnable programs.
        for candidate in ("main.exe", "main"):
            found = _which(candidate, args.models_dir, None)
            if found is None:
                continue
            if os.name == "nt" and not found.lower().endswith(".exe"):
                continue
            whisper_cpp = found
            break
    if not ffmpeg:
        _log("WARNING: ffmpeg not found; audio and visual analysis are disabled.")

    out_path = os.path.abspath(args.output) if args.output \
        else default_output_path(input_path)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)

    _log(f"Input  : {input_path}")
    _log(f"Output : {out_path}")
    if args.provider and args.provider.lower().strip() not in ("", "cpu"):
        _log(f"ONNX provider request: {args.provider}")
    if args.threads and args.threads > 0:
        _log(f"Worker threads: {args.threads}")

    duration_s = media_duration(input_path, ffprobe) if ffmpeg else 0.0
    media_hash_hex = media_hash(input_path)
    _log(f"Duration: {duration_s:.2f}s  hash: {media_hash_hex[:16]}...")

    tmp = tempfile.mkdtemp(prefix="safescene_", dir=args.temp_dir)
    try:
        # ---- Audio analysis ----
        mute_hits = []
        if ffmpeg:
            _progress(0.05)
            mute_hits = run_audio_analysis(
                ffmpeg, input_path, tmp, args.models_dir, whisper_cpp,
                threads=args.threads, progress=_progress, duration_s=duration_s)
            _progress(0.40)
        else:
            _progress(0.40)

        # ---- Visual analysis ----
        skip_hits = []
        if ffmpeg:
            frames = extract_frames(ffmpeg, input_path, os.path.join(tmp, "frames"),
                                    duration_s=duration_s,
                                    on_progress=lambda f: _progress(0.42 + 0.05 * f))
            skip_hits = run_visual_analysis(
                ffmpeg, input_path, tmp, args.models_dir, frames,
                providers_req=args.provider, threads=args.threads,
                progress=_progress, progress_floor=0.52)
            _progress(0.95)
        else:
            _progress(0.95)

        # ---- Post-processing ----
        segments = postprocess(mute_hits, skip_hits, duration_s)
        _progress(0.98)

        result = {
            "version": "1.0",
            "media_title": media_title(input_path),
            "media_hash": media_hash_hex,
            "duration_ms": int(round(duration_s * 1000)),
            "settings": {
                "filter_nudity": True,
                "filter_profanity": True,
                "safety_buffer_ms": int(SAFETY_BUFFER_S * 1000),
            },
            "segments": segments,
        }

        compact = write_result(out_path, result)
        _progress(1.0)
        _log(f"Wrote {len(segments)} segments to {out_path}")
        sys.stdout.write(f"RESULT:{compact}\n")
        sys.stdout.flush()
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run_scan(args)
    except KeyboardInterrupt:
        _log("Interrupted.")
        return 130
    except Exception as exc:  # noqa: BLE001
        _log(f"Fatal error: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
