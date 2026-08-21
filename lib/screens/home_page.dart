import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../controllers/safe_player_controller.dart';
import '../models/filter_segment.dart';
import '../services/scanner_service.dart';
import '../theme/app_theme.dart';
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
          debugPrint(
            'SafeScene: auto-loaded ${existing.segments.length} '
            'rules for ${path.split(Platform.pathSeparator).last}',
          );
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

      // 3. Run the scan and play once a result is available.
      await _runScanAndPlay(path);
    } on ScannerCancelledException {
      // Silently ignore an explicit cancel; nothing else to do.
    } catch (e) {
      if (mounted) setState(() => _lastError = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks the user whether to auto-scan the selected movie for Family Mode.
  ///
  /// Deliberately not dismissible by tapping outside: dismissing it silently
  /// falls through to an unfiltered playback, which defeats the purpose.
  Future<bool?> _askAutoScan() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Auto-scan for Family Mode?'),
        content: const Text(
          'No filter rules were found for this movie. Would you like to '
          'auto-scan this movie for Family Mode?',
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

  /// Opens a file picker and immediately scans the selected movie, then plays
  /// it with the resulting rules. Provides an always-visible, explicit entry
  /// point for Family Mode scanning.
  Future<void> _scanMovie() async {
    setState(() {
      _busy = true;
      _lastError = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _videoExtensions,
        dialogTitle: 'Select a movie to scan for Family Mode',
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) throw const FormatException('No file path returned.');
      await _runScanAndPlay(path);
    } catch (e) {
      if (mounted) setState(() => _lastError = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Runs the scanner for [path], shows the progress dialog and plays the
  /// movie with the resulting segments once the scan completes.
  Future<void> _runScanAndPlay(String path) async {
    // The future is owned here so "Run in Background" can dismiss the dialog
    // yet still resolve to a result later.
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
        if (reason == ScanDialogCloseReason.background && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Scanning in the background — opening the '
                'movie will resume once it finishes.',
              ),
            ),
          );
        }
        final scanResult = await scanFuture;
        if (!mounted) return;
        await _startPlayback(path, scanResult.segments);
    }
  }

  /// Builds a [SafePlayerController] from [segments], navigates to the player
  /// and lets the player screen open the media after its video surface exists.
  Future<void> _startPlayback(String path, List<FilterSegment> segments) async {
    final controller = SafePlayerController(
      segments: segments,
      onSkip: (s) => debugPrint('SafeScene: skipped ${s.category}'),
    );

    if (!mounted) {
      await controller.dispose();
      return;
    }

    final title = path.split(Platform.pathSeparator).last;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          controller: controller,
          media: Media(path),
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
      body: Stack(
        children: [
          const _AmbientBackdrop(),
          LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 40,
                    vertical: 28,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1020),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _BrandBar(),
                          const SizedBox(height: 64),
                          const _HeroCopy(),
                          const SizedBox(height: 30),
                          Center(
                            child: _CtaRow(
                              busy: _busy,
                              onOpen: _openFile,
                              onScan: _scanMovie,
                            ),
                          ),
                          const SizedBox(height: 48),
                          const _FeatureGrid(),
                          const SizedBox(height: 36),
                          const _FooterTip(),
                          if (_lastError != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.errorContainer
                                    .withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: theme.colorScheme.error.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                              ),
                              child: Text(
                                _lastError!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
/// Layered ambient backdrop: a deep base, two soft brand glows and a fine grid
/// that gives the landing page its "instrument panel" texture.
class _AmbientBackdrop extends StatelessWidget {
  const _AmbientBackdrop();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: AppColors.background),
          Align(
            alignment: Alignment.topRight,
            child: Container(
              width: 640,
              height: 480,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Color(0x3D3FC6F2),
                    Color(0x123FC6F2),
                    Colors.transparent,
                  ],
                  stops: [0.0, 0.55, 1.0],
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomLeft,
            child: Container(
              width: 620,
              height: 460,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Color(0x2E43E5C8),
                    Color(0x0F43E5C8),
                    Colors.transparent,
                  ],
                  stops: [0.0, 0.55, 1.0],
                ),
              ),
            ),
          ),
          const CustomPaint(painter: _GridPainter()),
        ],
      ),
    );
  }
}

/// A fine, faint blueprint grid drawn across the backdrop.
class _GridPainter extends CustomPainter {
  const _GridPainter();

  static const double _spacing = 72;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.028)
      ..strokeWidth = 1;
    final path = Path();
    for (double x = 0; x <= size.width; x += _spacing) {
      path.moveTo(x, 0);
      path.lineTo(x, size.height);
    }
    for (double y = 0; y <= size.height; y += _spacing) {
      path.moveTo(0, y);
      path.lineTo(size.width, y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => false;
}
/// Top strip: brand mark + wordmark on the left, privacy guarantee on the right.
class _BrandBar extends StatelessWidget {
  const _BrandBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            gradient: AppGradients.brand,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: AppColors.brand.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(
            Icons.shield,
            size: 22,
            color: AppColors.onBrand,
          ),
        ),
        const SizedBox(width: 12),
        const Text(
          'Safe Scene',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(AppRadii.pill),
            border: Border.all(color: AppColors.border),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 14, color: AppColors.accent),
              SizedBox(width: 6),
              Text(
                'PRIVACY FIRST · 100% LOCAL',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
/// Centered hero headline + supporting copy.
class _HeroCopy extends StatelessWidget {
  const _HeroCopy();

  @override
  Widget build(BuildContext context) {
    final display = Theme.of(context).textTheme.displaySmall;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.brand.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(AppRadii.pill),
            border: Border.all(color: AppColors.brand.withValues(alpha: 0.4)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome, size: 13, color: AppColors.brandSoft),
              SizedBox(width: 6),
              Text(
                'FAMILY-SAFE MOVIE PLAYER',
                style: TextStyle(
                  color: AppColors.brandSoft,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Text.rich(
          TextSpan(
            style: display,
            children: [
              const TextSpan(
                text: 'Watch freely.\n',
                style: TextStyle(color: AppColors.textPrimary),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: ShaderMask(
                  shaderCallback: (bounds) =>
                      AppGradients.brandText.createShader(bounds),
                  blendMode: BlendMode.srcATop,
                  child: Text(
                    'Content gets protected.',
                    style: display,
                  ),
                ),
              ),
            ],
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 640),
          child: Text(
            'Open any local movie. Safe Scene automatically skips explicit '
            'scenes, mutes profanity, and blackouts the rest — all with '
            'on-device AI. Nothing ever leaves your machine.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 15.5,
              height: 1.6,
            ),
          ),
        ),
      ],
    );
  }
}
/// Primary + secondary call-to-action row.
class _CtaRow extends StatelessWidget {
  const _CtaRow({
    required this.busy,
    required this.onOpen,
    required this.onScan,
  });

  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: busy ? null : onOpen,
          style: FilledButton.styleFrom(
            minimumSize: const Size(224, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.video_library, size: 20),
          label: const Text('Open Video File'),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : onScan,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(224, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: const Text('Scan & Protect a Movie'),
        ),
      ],
    );
  }
}
/// The four product pillars presented as glass feature cards.
class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid();

  static const List<_FeatureData> _features = [
    _FeatureData(
      icon: Icons.auto_awesome,
      color: AppColors.brand,
      title: 'Smart Scene Detection',
      body: 'Dual-model AI flags explicit frames in real time and skips them '
          'with a graceful fade.',
    ),
    _FeatureData(
      icon: Icons.volume_off,
      color: AppColors.mute,
      title: 'Word-level Muting',
      body: 'Whisper transcription silences coarse language — the picture '
          'keeps playing.',
    ),
    _FeatureData(
      icon: Icons.tune,
      color: AppColors.blackout,
      title: 'Scene Editor',
      body: 'Review every flag and fine-tune start, end, and action down to '
          'the millisecond.',
    ),
    _FeatureData(
      icon: Icons.lock_outline,
      color: AppColors.accent,
      title: '100% Private',
      body: 'Every scan runs on your machine. No cloud, no account, no '
          'upload — ever.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      alignment: WrapAlignment.center,
      children: [for (final f in _features) _FeatureCard(data: f)],
    );
  }
}

class _FeatureData {
  const _FeatureData({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;
}

/// A single glass card in the feature grid.
class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.data});

  final _FeatureData data;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 232,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.7)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  data.color.withValues(alpha: 0.30),
                  data.color.withValues(alpha: 0.08),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: data.color.withValues(alpha: 0.45)),
            ),
            child: Icon(data.icon, size: 20, color: data.color),
          ),
          const SizedBox(height: 14),
          Text(
            data.title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            data.body,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
/// The small context line under the feature grid.
class _FooterTip extends StatelessWidget {
  const _FooterTip();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.lightbulb_outline,
          size: 14,
          color: AppColors.textFaint,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            'Tip: place a <name>.safe.json next to your video to load '
            'existing filter rules instantly.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textFaint,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
