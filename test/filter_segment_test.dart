import 'package:flutter_test/flutter_test.dart';

import 'package:safe_scene/models/filter_segment.dart';

void main() {
  group('FilterAction', () {
    test('exposes the canonical labels used in .safe.json', () {
      expect(FilterAction.skip.label, 'skip');
      expect(FilterAction.mute.label, 'mute');
      expect(FilterAction.blackout.label, 'blackout');
    });

    test('parses known labels', () {
      expect(FilterAction.fromLabel('skip'), FilterAction.skip);
      expect(FilterAction.fromLabel('mute'), FilterAction.mute);
      expect(FilterAction.fromLabel('blackout'), FilterAction.blackout);
    });

    test('throws on unknown labels', () {
      expect(
        () => FilterAction.fromLabel('explode'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('FilterSegment', () {
    const segment = FilterSegment(
      id: 'seg_001',
      start: Duration(seconds: 10),
      end: Duration(seconds: 20),
      action: FilterAction.mute,
      category: 'profanity',
      source: 'ai_whisper',
      confidence: 0.97,
    );

    test('contains uses half-open [start, end) bounds', () {
      expect(segment.contains(Duration(seconds: 9)), isFalse);
      expect(segment.contains(Duration(seconds: 10)), isTrue);
      expect(segment.contains(Duration(seconds: 15)), isTrue);
      expect(segment.contains(Duration(seconds: 20)), isFalse);
      expect(segment.contains(Duration.zero), isFalse);
    });

    test('computes length', () {
      expect(segment.length, const Duration(seconds: 10));
    });

    test('round-trips through toJson/fromJson', () {
      final json = segment.toJson();
      expect(json['start_ms'], 10000);
      expect(json['end_ms'], 20000);
      expect(json['action'], 'mute');

      final restored = FilterSegment.fromJson(json);
      expect(restored.id, segment.id);
      expect(restored.start, segment.start);
      expect(restored.end, segment.end);
      expect(restored.action, segment.action);
      expect(restored.category, segment.category);
      expect(restored.source, segment.source);
      expect(restored.confidence, segment.confidence);
    });

    test('equality is based on start/end/action', () {
      const same = FilterSegment(
        start: Duration(seconds: 10),
        end: Duration(seconds: 20),
        action: FilterAction.mute,
        category: 'profanity',
        source: 'ai_whisper',
      );
      const different = FilterSegment(
        start: Duration(seconds: 11),
        end: Duration(seconds: 20),
        action: FilterAction.mute,
        category: 'profanity',
        source: 'ai_whisper',
      );
      expect(same, segment);
      expect(different, isNot(segment));
    });
  });
}
