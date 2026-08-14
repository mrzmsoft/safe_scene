import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/scan_progress.dart';
import '../services/scanner_service.dart';

/// How the scan dialog was dismissed.
enum ScanDialogCloseReason {
  /// The scan finished and produced a [ScanResult].
  completed,

  /// The user pressed Cancel; the scan was killed.
  cancelled,

  /// The user pressed "Run in Background"; the scan keeps running and the
  /// caller is responsible for awaiting [ScannerService.scan] to completion.
  background,
}

/// A modern, dark-themed dialog that streams [ScannerService] progress while a
/// movie is being scanned for Family Mode.
///
/// The owner is expected to start the scan (via [ScannerService.scan]) *before*
/// showing the dialog and pass the resulting future in via [scanFuture]; this
/// lets "Run in Background" dismiss the UI without abandoning the running scan.
class ScanDialogWidget extends StatefulWidget {
  const ScanDialogWidget({
    super.key,
    required this.scanner,
    required this.inputPath,
    required this.scanFuture,
  });

  /// The service driving the scan (used to listen for progress + cancel).
  final ScannerService scanner;

  /// The media being scanned (used for the subtitle).
  final String inputPath;

  /// The in-flight scan. The dialog listens for completion/errors and pops with
  /// [ScanDialogCloseReason.completed] or [ScanDialogCloseReason.cancelled].
  final Future<ScanResult> scanFuture;

  /// Shows the dialog as a modal route and resolves with how it was closed.
  static Future<ScanDialogCloseReason> show(
    BuildContext context, {
    required ScannerService scanner,
    required String inputPath,
    required Future<ScanResult> scanFuture,
  }) {
    return showDialog<ScanDialogCloseReason>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ScanDialogWidget(
        scanner: scanner,
        inputPath: inputPath,
        scanFuture: scanFuture,
      ),
    ).then((r) => r ?? ScanDialogCloseReason.cancelled);
  }

  @override
  State<ScanDialogWidget> createState() => _ScanDialogWidgetState();
}

class _ScanDialogWidgetState extends State<ScanDialogWidget> {
  ScanProgress _progress = const ScanProgress.initial();
  String? _error;
  StreamSubscription<ScanProgress>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.scanner.progress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });

    widget.scanFuture.then((_) {
      if (mounted) Navigator.of(context).pop(ScanDialogCloseReason.completed);
    }).catchError((Object e) {
      if (!mounted) return;
      if (e is! ScannerCancelledException) {
        setState(() => _error = e.toString());
      }
      Navigator.of(context).pop(ScanDialogCloseReason.cancelled);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onCancel() => widget.scanner.cancel();

  void _onBackground() =>
      Navigator.of(context).pop(ScanDialogCloseReason.background);

  @override
  Widget build(BuildContext context) {
    final percent = (_progress.percentage * 100).clamp(0, 100).round();
    final fileName = widget.inputPath.split(Platform.pathSeparator).last;

    return Dialog(
      backgroundColor: const Color(0xFF0F172A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.shield, color: Colors.lightBlueAccent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Scanning for Family Mode',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.lightBlueAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _progress.phase.label,
                      style: const TextStyle(
                        color: Colors.lightBlueAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: 132,
                height: 132,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: _progress.percentage,
                      strokeWidth: 10,
                      backgroundColor: Colors.white12,
                      color: Colors.lightBlueAccent,
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$percent%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Icon(
                          Icons.auto_awesome,
                          color: Colors.white38,
                          size: 18,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: _CounterCard(
                      label: 'Visual Scenes Flagged',
                      value: _progress.visualFlagged,
                      color: Colors.redAccent,
                      icon: Icons.visibility_off,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _CounterCard(
                      label: 'Profanities Flagged',
                      value: _progress.profanityFlagged,
                      color: Colors.amber,
                      icon: Icons.volume_off,
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _onCancel,
                      icon: const Icon(Icons.cancel),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _onBackground,
                      icon: const Icon(Icons.history_toggle_off),
                      label: const Text('Run in Background'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact stat card used by the scan dialog (e.g. "Visual Scenes Flagged").
class _CounterCard extends StatelessWidget {
  const _CounterCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  final String label;
  final int value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text(
            '$value',
            style: TextStyle(
              color: color,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
