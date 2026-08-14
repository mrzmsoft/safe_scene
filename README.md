+-------------------------------------------------------------------------+
|                      FLUTTER WINDOWS FRONTEND                           |
|  - UI State & File Pickers (file_picker)                                |
|  - Video Rendering Engine (media_kit + libmpv)                          |
|  - Filter Engine (JSON loader, real-time timestamp listener)            |
|  - Manual Scene Editor (Hotkeys + Seekbar Markers)                      |
|  - Master PIN & Family Safety Controls                                  |
+------------------------------------+------------------------------------+
| Standard I/O (JSON Streams)
v
+-------------------------------------------------------------------------+
|                LOCAL SCANNER SIDECAR (C++ / Python CLI)                 |
|                                                                         |
|  [ Input Video (.mp4/.mkv) ]                                            |
|        |                                                                |
|        +---> Audio Extraction (FFmpeg CLI)                              |
|        |           |                                                    |
|        |           v                                                    |
|        |     Whisper.cpp (ggml-base.bin) ---> Word Timestamps           |
|        |           |                                                    |
|        |           v                                                    |
|        |     Profanity Regex / Dictionary -> [ MUTE Segments ]          |
|        |                                                                |
|        +---> Keyframe Sampling (1.5 FPS via FFmpeg)                     |
|                    |                                                    |
|                    v                                                    |
|              NudeNet / YOLO-NSFW (ONNX) ---> [ SKIP Segments ]          |
|                                                                         |
|  [ Output: movie_name.safe.json ]                                       |
+-------------------------------------------------------------------------+


### Core Technologies
* **Frontend Framework:** Flutter Desktop (Windows target, Release mode).
* **Video Playback Engine:** `media_kit`, `media_kit_video`, `media_kit_libs_windows_video` (native `libmpv` binding for zero-latency frame-accurate seeking).
* **Audio AI Engine:** `whisper.cpp` (C++ static binary with AVX2/DirectML) running `ggml-base.bin` (~140MB).
* **Visual AI Engine:** ONNX Runtime (`onnxruntime.dll` / C++ or standalone Python sidecar) running quantized `nudenet_320n.onnx` (~40MB).
* **Media Processor:** Bundled static `ffmpeg.exe` for high-speed keyframe and audio extraction.
* **Storage Format:** Local human-readable JSON schema (`*.safe` / `*.safe.json`).

---

## 2. Master Implementation Roadmap (Phases 1 - 5)

### Phase 1: Foundation & Video Playback Engine (Days 1–4)
- [x] Configure Flutter Windows desktop environment and verify C++ build tools.
- [ ] Install and configure `media_kit` for Windows.
- [ ] Build baseline player UI with native keyboard hotkeys (Space for Play/Pause, Left/Right for Seek, Esc for Fullscreen).
- [ ] Implement data models (`FilterSegment`, `SafeMetadata`, `FilterAction`).
- [ ] Build real-time playback position listener stream to trigger instant skip and volume mute.

### Phase 2: Offline AI Scanner Engine (Sidecar) (Days 5–10)
- [ ] Build standalone `scanner_engine.exe` (or C++/Python worker script).
- [ ] Integrate FFmpeg audio extraction: 16kHz mono `.wav`.
- [ ] Integrate `whisper.cpp` to produce word-level timestamps.
- [ ] Implement profanity regex and swearword dictionary filter mapping.
- [ ] Integrate FFmpeg keyframe/scene extraction sampled at 1.5 FPS.
- [ ] Run batch inference through `nudenet.onnx` and merge contiguous detections into safe skip intervals ($[t_{start} - 0.75s, t_{end} + 0.75s]$).
- [ ] Pipe structured stdout stream (`PROGRESS:<0.0-1.0>`, `RESULT:<json>`) back to Flutter.

### Phase 3: Flutter Scanner Integration & Progress UI (Days 11–14)
- [ ] Implement `ScannerService` in Flutter using `dart:io Process.start`.
- [ ] Design sleek Scan Dialog with progress bar, estimated time remaining, and real-time category detection counters.
- [ ] Auto-save and auto-load `.safe` files alongside media files with matching hashes.

### Phase 4: Interactive Scene Editor & Parent Controls (Days 15–18)
- [ ] Build Parent PIN authentication (encrypted local storage via `flutter_secure_storage`).
- [ ] Develop Scene Inspector Timeline: visually display Red (Skip) and Yellow (Mute) markers over `media_kit` timeline.
- [ ] Build In-Player Marker Hotkeys (`[` for segment start, `]` for segment end, `S` for Skip, `M` for Mute).
- [ ] Implement segment fine-tuning dialog (adjust start/end by $\pm 100\text{ms}$).

### Phase 5: Production Packaging & Performance Tuning (Days 19–22)
- [ ] Multi-thread CPU & DirectML GPU acceleration configuration.
- [ ] Bundle static binaries (`ffmpeg.exe`, `scanner_engine.exe`, AI models) in `assets/bin/` and `assets/models/`.
- [ ] Build standalone Windows installer using **Inno Setup**.

---

## 3. Data Specification (`movie.safe.json`)

```json
{
  "version": "1.0",
  "media_title": "Action_Movie_2026.mp4",
  "media_hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "duration_ms": 7200000,
  "settings": {
    "filter_nudity": true,
    "filter_profanity": true,
    "safety_buffer_ms": 750
  },
  "segments": [
    {
      "id": "seg_001",
      "start_ms": 142000,
      "end_ms": 147500,
      "action": "skip",
      "category": "explicit_nudity",
      "confidence": 0.96,
      "source": "ai_nudenet"
    },
    {
      "id": "seg_002",
      "start_ms": 210200,
      "end_ms": 211100,
      "action": "mute",
      "category": "profanity",
      "confidence": 1.0,
      "source": "ai_whisper"
    }
  ]
}