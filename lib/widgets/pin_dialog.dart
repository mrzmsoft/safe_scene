import 'package:flutter/material.dart';

/// Validates a 4-digit Master PIN entered in a [PinDialog].
///
/// Returns `null` when the PIN is accepted, or a non-null human-readable error
/// message (surfaced inline in the dialog) when it is rejected.
typedef PinValidator = Future<String?> Function(String pin);

/// A dark, keyboard-friendly numeric keypad dialog for entering / creating a
/// 4-digit Master PIN.
///
/// Two flavours are provided:
/// * [PinDialog.verify] – a single entry that is checked by [validator].
/// * [PinDialog.create] – a two-step (enter + confirm) flow returning the new
///   PIN without any external validation.
///
/// Both resolve with the accepted PIN string, or `null` when the user cancels.
class PinDialog {
  /// Prompts for a PIN and validates it with [validator].
  ///
  /// Resolves with the validated PIN (as a 4-digit string), or `null` when the
  /// dialog is cancelled.
  static Future<String?> verify(
    BuildContext context, {
    required PinValidator validator,
    String title = 'Enter Master PIN',
    String? message,
    String errorText = 'Incorrect PIN. Please try again.',
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PinDialog(
        title: title,
        message: message,
        confirm: false,
        errorText: errorText,
        validator: validator,
      ),
    );
  }

  /// Prompts for a brand new 4-digit PIN (entered twice to confirm).
  ///
  /// Resolves with the new PIN, or `null` when cancelled.
  static Future<String?> create(
    BuildContext context, {
    String title = 'Create Master PIN',
    String? message = 'Choose a 4-digit Master PIN. It will be required to '
        'open the Scene Editor and change safety settings.',
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PinDialog(
        title: title,
        message: message,
        confirm: true,
      ),
    );
  }
}

/// The keypad dialog implementation shared by [PinDialog.verify]/[create].
class _PinDialog extends StatefulWidget {
  const _PinDialog({
    required this.title,
    required this.message,
    required this.confirm,
    this.errorText = '',
    this.validator,
  });

  final String title;
  final String? message;
  final bool confirm;
  final String errorText;
  final PinValidator? validator;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final List<int> _digits = [];
  final List<int> _confirm = [];
  bool _confirming = false;
  bool _checking = false;
  bool _error = false;

  bool get _complete => _digits.length == 4;
  List<int> get _active => _confirming ? _confirm : _digits;

  void _addDigit(int digit) {
    if (_checking || _active.length >= 4) return;
    setState(() { _error = false; _active.add(digit); if (!_confirming && _complete) _submit(); });
  }

  void _backspace() {
    if (_checking) return;
    setState(() { _error = false; if (_active.isNotEmpty) _active.removeLast(); });
  }

  String _pinString(List<int> digits) => digits.join();

  Future<void> _submit() async {
    if (_checking) return;
    if (!_complete) return;
    if (widget.confirm) {
      if (!_confirming) { setState(() { _confirming = true; _error = false; }); return; }
      if (_pinString(_digits) != _pinString(_confirm)) { setState(() { _error = true; _confirm.clear(); }); return; }
      Navigator.of(context).pop(_pinString(_digits));
      return;
    }
    setState(() => _checking = true);
    final pin = _pinString(_digits);
    final error = await widget.validator?.call(pin);
    if (!mounted) return;
    if (error != null) { setState(() { _checking = false; _error = true; _digits.clear(); }); return; }
    Navigator.of(context).pop(pin);
  }

  void _backToEnter() { setState(() { _confirming = false; _confirm.clear(); _error = false; }); }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: const Color(0xFF0F172A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.lock_outline, size: 36, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                _confirming ? 'Confirm your PIN' : widget.title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              if (widget.message != null && !_confirming) ...[
                const SizedBox(height: 8),
                Text(widget.message!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
              const SizedBox(height: 20),
              _PinDots(count: 4, filled: _active.length, error: _error),
              const SizedBox(height: 6),
              if (_error)
                Text(
                  _confirming ? 'PINs do not match. Try again.' : (widget.errorText.isNotEmpty ? widget.errorText : 'Invalid PIN.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                ),
              const SizedBox(height: 20),
              _Keypad(enabled: !_checking, onDigit: _addDigit, onBackspace: _backspace),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(onPressed: _checking ? null : () => Navigator.of(context).pop(null), child: const Text('Cancel')),
                  if (widget.confirm && _confirming)
                    TextButton(onPressed: _checking ? null : _backToEnter, child: const Text('Back')),
                  FilledButton(
                    onPressed: _checking ? null : (_confirming && _active.length < 4) ? null : _submit,
                    child: _checking
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_confirming ? 'Confirm' : 'Submit'),
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

/// Renders `count` circles that fill up as the user enters digits.
class _PinDots extends StatelessWidget {
  const _PinDots({required this.count, required this.filled, required this.error});
  final int count;
  final int filled;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i < filled;
        return Container(
          width: 16, height: 16,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: error
                ? Theme.of(context).colorScheme.error
                : (active ? Theme.of(context).colorScheme.primary : Colors.white24),
          ),
        );
      }),
    );
  }
}

/// A 3x4 digit keypad with a backspace key.
class _Keypad extends StatelessWidget {
  const _Keypad({required this.enabled, required this.onDigit, required this.onBackspace});
  final bool enabled;
  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;

  static const List<int?> _keys = [1, 2, 3, 4, 5, 6, 7, 8, 9, null, 0, null];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var r = 0; r < 4; r++) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var c = 0; c < 3; c++) ...[
                if (c > 0) const SizedBox(width: 12),
                _buildKey(_keys[r * 3 + c], r == 3 && c == 0, r == 3 && c == 2),
              ],
            ],
          ),
          if (r < 3) const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildKey(int? digit, bool isBlank, bool isBackspace) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: enabled && !isBlank ? (isBackspace ? onBackspace : () => onDigit(digit!)) : null,
      child: SizedBox(
        width: 56, height: 48,
        child: Center(
          child: isBackspace
              ? const Icon(Icons.backspace_outlined, size: 22, color: Colors.white)
              : Text('$digit', style: const TextStyle(color: Colors.white, fontSize: 20)),
        ),
      ),
    );
  }
}