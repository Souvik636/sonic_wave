import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/widgets/shimmer_loading.dart';

void main() {
  testWidgets(
      'ShimmerLoadingList never overflows a short viewport (regression: '
      'search skeleton bottom-overflow)', (tester) async {
    // A height far smaller than 10 rows × ~72px — the old Column-based
    // skeleton overflowed here; the ListView version must clip instead.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: ShimmerLoadingList(itemCount: 10),
          ),
        ),
      ),
    );
    // Let the entrance animations run; overflow would throw during layout.
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);
    expect(find.byType(ShimmerLoadingList), findsOneWidget);
  });

  testWidgets('ShimmerLoadingList renders the requested row count in a tall '
      'viewport', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 1200,
            child: ShimmerLoadingList(itemCount: 6),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);
    expect(find.byType(ShimmerSongTile), findsNWidgets(6));
  });
}
