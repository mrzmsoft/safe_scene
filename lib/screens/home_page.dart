import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controllers/safe_player_controller.dart';
import '../models/filter_segment.dart';
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

      final segments = await _loadRulesFor(path);
      if (!mounted) return;

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
    } catch (e) {
      if (mounted) setState(() => _lastError = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Attempts to read `<videoName>.safe.json` sitting next to [videoPath] and
  /// deserialize its `segments`. Returns an empty list when absent/invalid.
  Future<List<FilterSegment>> _loadRulesFor(String videoPath) async {
    try {
      final dir = File(videoPath).parent.path;
      final base = videoPath.split(Platform.pathSeparator).last;
      final noExt = base.contains('.')
          ? base.substring(0, base.lastIndexOf('.'))
          : base;
      final rulePath = '$dir${Platform.pathSeparator}$noExt.safe.json';

      final file = File(rulePath);
      if (!await file.exists()) return const [];

      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final rawSegments = decoded['segments'] as List<dynamic>? ?? const [];
      final segments = rawSegments
          .map((e) => FilterSegment.fromJson(e as Map<String, dynamic>))
          .toList();

      if (kDebugMode) {
        debugPrint('SafeScene: loaded ${segments.length} rules from $rulePath');
      }
      return segments;
    } catch (e) {
      debugPrint('SafeScene: could not load rules: $e');
      return const [];
    }
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
