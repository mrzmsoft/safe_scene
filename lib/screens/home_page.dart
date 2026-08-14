import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controllers/safe_player_controller.dart';
import '../models/filter_segment.dart';
import '../services/scanner_service.dart';
import '../widgets/scan_dialog.dart';
import 'video_player_page.dart';

/// The landing screen for Safe Scene.
///
/// Lets the user pick a local video file, optionally auto-loads the matching
/// `<name>.safe.json` rule set when one sits next to the media, and opens the
/// player.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Drives the offline scanner engine and keeps a single long-lived instance
  /// so the in-flight [ScannerService.progress] stream survives dialog rebuilds.
  final ScannerService _scanner = ScannerService();

  static const List<String> _videoExtensions = [
    'mp4',
    'mkv',
    'avi',
    'mov',
    'webm',
    'flv',
    'wmv',
    'm4v',
    'ts',
    'mpg',
    'mpeg',
    'ogv',
  ];

  bool _busy = false;
  String? _lastError;

  Future<void> _openFile() async {
    setState(() {
      _busy = true;
      _lastError = null;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _videoExtensions,
        dialogTitle: 'Open a video file',
      );

      if (result == null || result.files.isEmpty) {
        return; // User cancelled.
      }

      final path = result.files.single.path;
      if (path == null) throw const FormatException('No file path returned.');

      // 1. Auto-load an existing rule set (by name or content hash).
      final existing = await _scanner.findExistingRule(path);
      if (!mounted) return;
      if (existing != null) {
        if (kDebugMode) {
          debugPrint('SafeScene: auto-loaded ${existing.segments.length} '
              'rules for ${path.split(Platform.pathSeparator).last}');
        }
        await _startPlayback(path, existing.segments);
        return;
      }

      // 2. No rules found — offer to auto-scan for Family Mode.
      final wantsScan = await _askAutoScan();
      if (!mounted) return;
      if (wantsScan != true) {
        await _startPlayback(path, const []);
        return;
      }

      // 3. Run the scan. The future is owned here so "Run in Background" can
      //    dismiss the dialog yet still resolve to a result later.
      final scanFuture = _scanner.scan(path);
      final reason = await ScanDialogWidget.show(
        context,
        scanner: _scanner,
        inputPath: path,
        scanFuture: scanFuture,
      );
      if (!mounted) return;

      switch (reason) {
        case ScanDialogCloseReason.cancelled:
          return; // User bailed; keep the video unplayed.
        case ScanDialogCloseReason.completed:
        case ScanDialogCloseReason.background:
          if (reason == ScanDialogCloseReason.background) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Scanning in the background — opening the '
                      'movie will resume once it finishes.'),
                ),
              );
            }
          }
          final scanResult = await scanFuture;
          if (!mounted) return;
          await _startPlayback(path, scanResult.segments);
      }
    } on ScannerCancelledException {
      // Silently ignore an explicit cancel; nothing else to do.
    } catch (e) {
      if (mounted) setState(() => _lastError = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks the user whether to auto-scan the selected movie for Family Mode.
  Future<bool?> _askAutoScan() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text(
          'Auto-scan for Family Mode?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'No filter rules were found for this movie. Would you like to '
          'auto-scan this movie for Family Mode?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not Now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Scan'),
          ),
        ],
      ),
    );
  }

  /// Builds a [SafePlayerController] from [segments], opens the media and
  /// navigates to the player. Disposes the controller when popped.
  Future<void> _startPlayback(
    String path,
    List<FilterSegment> segments,
  ) async {
    final controller = SafePlayerController(
      segments: segments,
      onSkip: (s) => debugPrint('SafeScene: skipped ${s.category}'),
    );

    // Open the media before navigating so the first frame is ready sooner.
    await controller.openPath(path);

    if (!mounted) {
      await controller.dispose();
      return;
    }

    final title = path.split(Platform.pathSeparator).last;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          controller: controller,
          title: title,
          autoplay: true,
        ),
      ),
    );

    // Disposal happens once the player screen is popped.
    await controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.shield,
                    size: 80,
                    color: Colors.lightBlueAccent,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Safe Scene',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'A local video player that automatically skips\n'
                    'and mutes explicit scenes from timestamp rules.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, height: 1.5),
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: _busy ? null : _openFile,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.video_library),
                    label: const Text('Open Video File'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 16,
                      ),
                      textStyle: const TextStyle(fontSize: 16),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Tip: place a <name>.safe.json next to your video\n'
                    'to auto-apply filter rules.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  if (_lastError != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _lastError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
