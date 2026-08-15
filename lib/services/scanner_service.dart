import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/scan_progress.dart';
import '../utils/file_hash.dart';

/// Thrown when the bundled scanner binary cannot be found or the scan fails.
class ScannerException implements Exception {
  const ScannerException(this.message);

  final String message;

  @override
  String toString() => 'ScannerException: $message';
}

/// Thrown when the user requests [ScannerService.cancel].
class ScannerCancelledException extends ScannerException {
  const ScannerCancelledException() : super('Scan cancelled by user.');
}

/// Runs the bundled `scanner_engine.exe` as a child process and streams its
/// machine-readable `PROGRESS:` / `RESULT:` lines back to callers.
///
/// # Protocol (produced by the offline worker)
/// * `PROGRESS:<0.0..1.0>` on stdout — real-time completion fraction.
/// * `RESULT:<json>` on stdout — the final `movie.safe.json` payload.
/// * `[scanner] ...` diagnostic lines on stderr — used to derive the live
///   "Visual scenes flagged" / "Profanities flagged" counters.
///
/// Only one scan runs at a time per service instance; concurrent calls throw.
class ScannerService {
  ScannerService({String? executablePath, String? modelsDir})
    : _executablePath = executablePath,
      _modelsDir = modelsDir;

  final String? _executablePath;
  final String? _modelsDir;
  String? _runtimeAssetRootPath;

  final StreamController<ScanProgress> _progress =
      StreamController<ScanProgress>.broadcast();

  String get runtimeAssetRootPath =>
      _runtimeAssetRootPath ?? _defaultRuntimeAssetRootPath;

  Process? _process;
  bool _cancelRequested = false;

  /// Live progress events for the currently running (or last completed) scan.
  Stream<ScanProgress> get progress => _progress.stream;

  /// Whether a scan is currently in flight.
  bool get isRunning => _process != null;

  /// Requests a graceful kill of the running child process.
  ///
  /// Is a no-op when nothing is running. The in-flight [scan] future completes
  /// with a [ScannerCancelledException].
  Future<void> cancel() async {
    _cancelRequested = true;
    final process = _process;
    if (process == null) return;
    try {
      process.kill();
    } catch (_) {
      // The process may have already exited; nothing else to do.
    }
  }

  // --------------------------------------------------------------------
  // Executable resolution (bundled + dev-mode fallbacks)
  // --------------------------------------------------------------------
  static const String name = 'scanner_engine.exe';
  static const String scriptName = 'scanner_engine.py';

  /// Resolves the argv of the scanner command. Prefers a bundled .exe, then a
  /// dev-mode `python scanner_engine.py` fallback so the engine can run before
  /// it is compiled. Returns null when neither is available.
  List<String>? resolveCommand() {
    final override = _executablePath;
    if (override != null && File(override).existsSync()) {
      return _commandForPath(override);
    }
    final env = Platform.environment['SAFE_SCENE_SCANNER'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) {
      return _commandForPath(env);
    }

    final runtimeBinDir = _runtimeAssetRootPath == null
        ? null
        : Directory('$_runtimeAssetRootPath${Platform.pathSeparator}bin');
    final runtimeExe = runtimeBinDir != null
        ? File('${runtimeBinDir.path}${Platform.pathSeparator}$name')
        : null;
    if (runtimeExe != null && runtimeExe.existsSync()) {
      return [runtimeExe.path];
    }

    final exe = _findCandidate(name);
    if (exe != null) return [exe];

    final runtimeScript = runtimeBinDir != null
        ? File('${runtimeBinDir.path}${Platform.pathSeparator}$scriptName')
        : null;
    if (runtimeScript != null && runtimeScript.existsSync()) {
      return _commandForPath(runtimeScript.path);
    }

    final script = _findCandidate(scriptName);
    if (script != null) return _commandForPath(script);

    return null;
  }

  /// Resolves the models directory passed to the scanner. This mirrors the
  /// roadmap packaging layout (`assets/models`) while keeping dev-mode runs
  /// working from the repository root.
  String? resolveModelsDir() {
    final override = _modelsDir;
    if (override != null && Directory(override).existsSync()) return override;

    final env = Platform.environment['SAFE_SCENE_MODELS'];
    if (env != null && env.isNotEmpty && Directory(env).existsSync()) {
      return env;
    }

    if (_runtimeAssetRootPath != null) {
      final runtimeModels = Directory(
        '$_runtimeAssetRootPath${Platform.pathSeparator}models',
      );
      if (runtimeModels.existsSync()) return runtimeModels.path;
    }

    return _findDirectory('assets${Platform.pathSeparator}models');
  }

  Future<void> prepareBundledRuntimeAssets() async {
    final root = await _defaultRuntimeAssetRootDirectory();
    _runtimeAssetRootPath = root.path;

    final folders = <String, List<String>>{
      'bin': [name, 'ffmpeg.exe', 'ffprobe.exe', 'ffplay.exe'],
      'models': ['nudenet.onnx', 'ggml-base.bin'],
    };

    for (final entry in folders.entries) {
      final folder = Directory(
        '${root.path}${Platform.pathSeparator}${entry.key}',
      );
      await folder.create(recursive: true);

      for (final fileName in entry.value) {
        final assetPath = 'assets/${entry.key}/$fileName';
        try {
          final bytes = await rootBundle.load(assetPath);
          final outFile = File(
            '${folder.path}${Platform.pathSeparator}$fileName',
          );
          await outFile.writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
            flush: true,
          );
        } catch (_) {
          // The runtime bundle may not include every optional file. Ignore
          // missing assets and continue; the scanner will fall back gracefully.
        }
      }
    }
  }

  static List<String> _commandForPath(String path) {
    if (path.toLowerCase().endsWith('.py')) {
      return [Platform.isWindows ? 'python' : 'python3', path];
    }
    return [path];
  }

  static String? _findCandidate(String fileName) {
    final candidates = <String>[];
    final roots = _candidateRoots();

    for (final root in roots) {
      candidates.addAll([
        '$root${Platform.pathSeparator}$fileName',
        '$root${Platform.pathSeparator}bin${Platform.pathSeparator}$fileName',
        '$root${Platform.pathSeparator}assets${Platform.pathSeparator}bin${Platform.pathSeparator}$fileName',
      ]);
    }

    candidates.add(fileName);
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static String? _findDirectory(String relativePath) {
    for (final root in _candidateRoots()) {
      final candidate = '$root${Platform.pathSeparator}$relativePath';
      if (Directory(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static List<String> _candidateRoots() {
    final roots = <String>[];

    void add(String? path) {
      if (path == null || path.isEmpty) return;
      final normalized = Directory(path).absolute.path;
      if (!roots.contains(normalized)) roots.add(normalized);
    }

    add(Directory.current.path);
    final projectRoot = _findProjectRoot(Directory.current);
    add(projectRoot?.path);

    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      add(exeDir);
      add(
        '$exeDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets',
      );
    } catch (_) {
      // resolvedExecutable is unavailable in some contexts (e.g. tests).
    }

    return roots;
  }

  Future<Directory> _defaultRuntimeAssetRootDirectory() async {
    if (_runtimeAssetRootPath != null) {
      return Directory(_runtimeAssetRootPath!);
    }

    try {
      final supportDir = await getApplicationSupportDirectory();
      final root = Directory(
        '${supportDir.path}${Platform.pathSeparator}safe_scene_runtime',
      );
      await root.create(recursive: true);
      _runtimeAssetRootPath = root.path;
      return root;
    } catch (_) {
      final root = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}safe_scene_runtime',
      );
      await root.create(recursive: true);
      _runtimeAssetRootPath = root.path;
      return root;
    }
  }

  static String get _defaultRuntimeAssetRootPath =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}safe_scene_runtime';

  static Directory? _findProjectRoot(Directory start) {
    var dir = start.absolute;
    while (true) {
      if (File(
        '${dir.path}${Platform.pathSeparator}pubspec.yaml',
      ).existsSync()) {
        return dir;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  // --------------------------------------------------------------------
  // Live scan
  // --------------------------------------------------------------------

  /// Diagnostic-line matchers emitted by the worker on stderr. They let the UI
  /// show running "visual / profanity" counters before the final RESULT arrives.
  static final RegExp _visualRe = RegExp(r'Visual:\s+(\d+)\s+flagged frames');
  static final RegExp _profanityRe = RegExp(r'(\d+)\s+profanity hits');
  static final RegExp _segmentsRe = RegExp(r'Wrote\s+(\d+)\s+segments');

  /// Maps a completion fraction onto a meaningful [ScanPhase] so the dialog can
  /// show "Audio"/"Video" instead of a bare percentage. The thresholds mirror
  /// the `PROGRESS:` fractions the Python engine actually emits.
  static ScanPhase _phaseFor(double fraction) {
    if (fraction >= 1.0) return ScanPhase.done;
    if (fraction >= 0.95) return ScanPhase.finalizing;
    if (fraction >= 0.42) return ScanPhase.video;
    if (fraction >= 0.05) return ScanPhase.audio;
    return ScanPhase.preparing;
  }

  /// Launches the scanner against [inputPath] and resolves with a parsed
  /// [ScanResult] when the engine prints its `RESULT:<json>` line.
  ///
  /// Progress (and the live counters) are surfaced through [progress] as they
  /// arrive, so the caller can drive a UI while this future is pending.
  ///
  /// Throws [ScannerException] if the binary is missing or the process exits
  /// without a result, and [ScannerCancelledException] if [cancel] was invoked.
  ///
  /// Only one scan may run at a time; a second concurrent call throws.
  Future<ScanResult> scan(
    String inputPath, {
    String? outputPath,
    String? modelsDir,
  }) async {
    await prepareBundledRuntimeAssets();
    modelsDir ??= resolveModelsDir();

    if (_process != null) {
      throw const ScannerException('A scan is already running.');
    }

    final command = resolveCommand();
    if (command == null) {
      throw const ScannerException(
        'Could not locate the scanner engine. Set SAFE_SCENE_SCANNER or '
        'bundle scanner_engine.exe next to the app.',
      );
    }

    final arguments = <String>[
      '--input',
      inputPath,
      if (outputPath != null) ...['--output', outputPath],
      if (modelsDir != null) ...['--models-dir', modelsDir],
    ];

    Process process;
    try {
      process = await Process.start(command.first, [
        ...command.skip(1),
        ...arguments,
      ]);
    } catch (e) {
      _process = null;
      throw ScannerException('Failed to launch scanner: $e');
    }

    _process = process;
    _cancelRequested = false;

    final completer = Completer<ScanResult>();
    var latest = const ScanProgress.initial();
    String? resultJson;
    final stderrTail = <String>[];

    void emit(ScanProgress next) {
      latest = next;
      if (!_progress.isClosed) _progress.add(next);
    }

    emit(
      latest.copyWith(
        phase: ScanPhase.preparing,
        message: 'Launching scanner…',
      ),
    );

    void complete(ScanResult result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    void fail(Object error) {
      if (!completer.isCompleted) completer.completeError(error);
    }

    final outSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith('PROGRESS:')) {
            final value = double.tryParse(
              line.substring('PROGRESS:'.length).trim(),
            );
            if (value != null) {
              final fraction = value.clamp(0.0, 1.0);
              emit(
                latest.copyWith(
                  percentage: fraction,
                  phase: _phaseFor(fraction),
                ),
              );
            }
          } else if (line.startsWith('RESULT:')) {
            resultJson = line.substring('RESULT:'.length).trim();
          }
        }, onError: (Object e) => fail(ScannerException('stdout error: $e')));

    final errSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            stderrTail.add(line);
            if (stderrTail.length > 8) stderrTail.removeAt(0);
            final parsed = _parseCounterLine(line, latest);
            if (parsed != null) emit(parsed);
          },
          onError: (_) {
            /* stderr is diagnostic only; ignore */
          },
        );

    process.exitCode.then((code) async {
      await outSub.cancel();
      await errSub.cancel();
      _process = null;

      if (_cancelRequested) {
        fail(const ScannerCancelledException());
        return;
      }

      if (resultJson != null) {
        try {
          final json = jsonDecode(resultJson!) as Map<String, dynamic>;
          final result = ScanResult.fromJson(json);
          emit(
            latest.copyWith(
              percentage: 1.0,
              phase: ScanPhase.done,
              segmentsFound: result.segments.length,
              message: 'Scan complete',
            ),
          );
          complete(result);
        } catch (e) {
          fail(ScannerException('Failed to parse RESULT payload: $e'));
        }
        return;
      }

      final details = stderrTail.isEmpty ? '' : '\n${stderrTail.join('\n')}';
      fail(
        ScannerException(
          'Scanner exited (code $code) without producing a RESULT.$details',
        ),
      );
    });

    return completer.future;
  }

  /// Updates the running visual/profanity/segment counters from a `[scanner]`
  /// diagnostic line, or returns null when the line carries no counter.
  static ScanProgress? _parseCounterLine(String line, ScanProgress current) {
    final visual = _visualRe.firstMatch(line);
    if (visual != null) {
      return current.copyWith(visualFlagged: int.parse(visual.group(1)!));
    }
    final profanity = _profanityRe.firstMatch(line);
    if (profanity != null) {
      return current.copyWith(profanityFlagged: int.parse(profanity.group(1)!));
    }
    final segments = _segmentsRe.firstMatch(line);
    if (segments != null) {
      return current.copyWith(segmentsFound: int.parse(segments.group(1)!));
    }
    return null;
  }

  // --------------------------------------------------------------------
  // Auto-loader
  // --------------------------------------------------------------------

  /// Looks for a pre-computed rule file for [videoPath] and returns it parsed,
  /// or null when none is available.
  ///
  /// Two strategies are tried:
  ///   1. **Name match** — `<name>.safe.json` / `<name>.safe` next to the video.
  ///   2. **Hash match** — any `.safe.json` / `.safe` in the same directory whose
  ///      recorded `media_hash` equals the SHA-256 of [videoPath]'s contents.
  Future<ScanResult?> findExistingRule(String videoPath) async {
    final file = File(videoPath);
    if (!await file.exists()) return null;

    final dir = file.parent.path;
    final base = file.uri.pathSegments.last;
    final noExt = base.contains('.')
        ? base.substring(0, base.lastIndexOf('.'))
        : base;

    final nameCandidates = [
      '$dir${Platform.pathSeparator}$noExt.safe.json',
      '$dir${Platform.pathSeparator}$noExt.safe',
    ];
    for (final candidate in nameCandidates) {
      final parsed = await _tryParseRule(File(candidate));
      if (parsed != null) return parsed;
    }

    final videoHash = await _hashOrNull(videoPath);
    if (videoHash == null) return null;

    await for (final entity in file.parent.list()) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      if (!lower.endsWith('.safe.json') && !lower.endsWith('.safe')) continue;
      final parsed = await _tryParseRule(entity);
      if (parsed != null && parsed.mediaHash == videoHash) return parsed;
    }

    return null;
  }

  static Future<String?> _hashOrNull(String path) async {
    try {
      return await sha256FileHex(path);
    } catch (_) {
      return null;
    }
  }

  static Future<ScanResult?> _tryParseRule(File file) async {
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ScanResult.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Releases the child process (if any) and closes the progress stream.
  ///
  /// Call once when the owning widget/provider is torn down.
  Future<void> dispose() async {
    _process?.kill();
    _process = null;
    if (!_progress.isClosed) await _progress.close();
  }
}
