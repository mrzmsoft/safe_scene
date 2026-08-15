import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_scene/models/scan_progress.dart';
import 'package:safe_scene/services/scanner_service.dart';

void main() {
  test('ScannerService resolves the repository scanner script in dev mode', () {
    final service = ScannerService();
    final command = service.resolveCommand();

    expect(command, isNotNull);
    expect(command!.last.replaceAll('\\', '/'), endsWith('scanner_engine.py'));
  });

  test('ScannerService resolves the roadmap models directory when present', () {
    final service = ScannerService();
    final modelsDir = service.resolveModelsDir();

    expect(modelsDir, isNotNull);
    expect(modelsDir!.replaceAll('\\', '/'), endsWith('assets/models'));
  });

  test(
    'ScannerService parses a sidecar RESULT from the Python fallback',
    () async {
      final temp = await Directory.systemTemp.createTemp('safe_scene_scanner_');
      final input = File('${temp.path}${Platform.pathSeparator}sample.mp4');
      final output = File(
        '${temp.path}${Platform.pathSeparator}sample.safe.json',
      );
      await input.writeAsBytes(const []);

      final service = ScannerService(executablePath: 'scanner_engine.py');
      final events = <ScanProgress>[];
      final sub = service.progress.listen(events.add);

      try {
        final result = await service.scan(input.path, outputPath: output.path);

        expect(result.mediaTitle, 'sample.mp4');
        expect(result.segments, isEmpty);
        expect(await output.exists(), isTrue);
        expect(events, isNotEmpty);
        expect(events.last.phase, ScanPhase.done);
      } finally {
        await sub.cancel();
        await service.dispose();
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
