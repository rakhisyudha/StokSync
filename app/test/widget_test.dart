import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stoksync/main.dart';

void main() {
  testWidgets('boots within a Riverpod provider scope', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: StokSyncApp()));

    expect(find.text('StokSync'), findsOneWidget);
  });
}
