import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:safe_scene/models/filter_segment.dart';
import 'package:safe_scene/widgets/safe_seek_bar.dart';

void main() {
  const skipSegment = FilterSegment(
    id: 'seg_skip',
    start: Duration(seconds: 30),
    end: Duration(seconds: 40),
    action: FilterAction.skip,
    category: 'explicit_nudity',
    source: 'manual',
  );
  const muteSegment = FilterSegment(
    id: 'seg_mute',
    start: Duration(seconds: 50),
    end: Duration(seconds: 60),
    action: FilterAction.mute,
    category: 'profanity',
    source: 'manual',
  );

  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 60,
            child: child,
          ),
        ),
      ),
    );
  }

  testWidgets('renders without a tooltip until a band is hovered',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(SafeSeekBarWidget(
        position: const Duration(seconds: 20),
        duration: const Duration(seconds: 100),
        segments: const [skipSegment, muteSegment],
        onSeek: (_) {},
      )),
    );

    expect(find.byType(SafeSeekBarWidget), findsOneWidget);
    expect(find.text('explicit_nudity'), findsNothing);
    expect(find.text('profanity'), findsNothing);
  });

  testWidgets('shows a tooltip with category + timestamp when hovering a band',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(SafeSeekBarWidget(
        position: const Duration(seconds: 20),
        duration: const Duration(seconds: 100),
        segments: const [skipSegment, muteSegment],
        onSeek: (_) {},
      )),
    );

    final rect = tester.getRect(find.byType(SafeSeekBarWidget));

    // Hover over the skip band (~30-40% across) -> 'explicit_nudity'.
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(location: Offset.zero);
    await hover.moveTo(
      Offset(rect.left + rect.width * 0.35, rect.bottom - 8),
    );
    await tester.pump();

    expect(find.text('explicit_nudity'), findsOneWidget);
    expect(find.text('00:30 – 00:40'), findsOneWidget);

    // Hover over the mute band (~50-60%) -> 'profanity'.
    await hover.moveTo(
      Offset(rect.left + rect.width * 0.55, rect.bottom - 8),
    );
    await tester.pump();
    expect(find.text('profanity'), findsOneWidget);
    expect(find.text('00:50 – 01:00'), findsOneWidget);

    // Move off the bar -> tooltip disappears.
    await hover.moveTo(Offset(rect.left + rect.width * 0.05, rect.bottom - 8));
    await tester.pump();
    expect(find.text('profanity'), findsNothing);
  });

  testWidgets('tap calls onSeek with the duration at that fraction',
      (WidgetTester tester) async {
    Duration? sought;
    await tester.pumpWidget(
      wrap(SafeSeekBarWidget(
        position: const Duration(seconds: 20),
        duration: const Duration(seconds: 100),
        segments: const [],
        onSeek: (d) => sought = d,
      )),
    );

    final rect = tester.getRect(find.byType(SafeSeekBarWidget));
    await tester.tapAt(
      Offset(rect.left + rect.width * 0.5, rect.bottom - 8),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(sought, isNotNull);
    // 50% of 100s.
    expect(sought, const Duration(seconds: 50));
  });
}