import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/scan_progress.dart';
import '../services/scanner_service.dart';
import '../theme/app_theme.dart';

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

    widget.scanFuture
        .then((_) {
          if (mounted) {
            Navigator.of(context).pop(ScanDialogCloseReason.completed);
          }
        })
        .catchError((Object e) {
          if (!mounted) {
            return;
          }
          if (e is ScannerCancelledException) {
            Navigator.of(context).pop(ScanDialogCloseReason.cancelled);
          } else {
            setState(() => _error = e.toString());
          }
        });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onCancel() {
    if (_error != null) {
      Navigator.of(context).pop(ScanDialogCloseReason.cancelled);
      return;
    }
    widget.scanner.cancel();
  }

  void _onBackground() {
    if (_error != null) return;
    Navigator.of(context).pop(ScanDialogCloseReason.background);
  }

  @override
  Widget build(BuildContext context) {
    final percent = (_progress.percentage * 100).clamp(0, 100).round();
    final fileName = widget.inputPath.split(Platform.pathSeparator).last;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      gradient: AppGradients.brand,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(
                      Icons.shield,
                      size: 20,
                      color: AppColors.onBrand,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Scanning for Family Mode',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.brand.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      border: Border.all(
                        color: AppColors.brand.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Text(
                      _progress.phase.label,
                      style: const TextStyle(
                        color: AppColors.brandSoft,
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
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
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
                      backgroundColor: AppColors.border,
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$percent%',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Icon(
                          Icons.auto_awesome,
                          color: AppColors.brand,
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
                      color: AppColors.skip,
                      icon: Icons.visibility_off,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _CounterCard(
                      label: 'Profanities Flagged',
                      value: _progress.profanityFlagged,
                      color: AppColors.mute,
                      icon: Icons.volume_off,
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.errorContainer.withValues(alpha: 0.24),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.error.withValues(alpha: 0.5),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _onCancel,
                      icon: Icon(_error == null ? Icons.cancel : Icons.close),
                      label: Text(_error == null ? 'Cancel' : 'Close'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _error == null ? _onBackground : null,
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
        borderRadius: BorderRadius.circular(AppRadii.md),
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
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
