import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tampal/core/models/clipboard_entry.dart';
import 'package:tampal/core/network/sync_service.dart';
import 'package:tampal/ui/widgets/clipboard_card.dart';
import 'package:tampal/ui/widgets/connection_badge.dart';
import 'package:tampal/ui/widgets/empty_state.dart';

void main() {
  group('Widget Tests', () {
    testWidgets('ConnectionBadge displays status accurately', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ConnectionBadge(
              status: SyncStatus.connected,
              peerName: 'MacBook Pro',
            ),
          ),
        ),
      );

      expect(find.text('Synced with MacBook Pro'), findsOneWidget);
      expect(find.byIcon(Icons.link_rounded), findsOneWidget);
    });

    testWidgets('ClipboardCard displays content and triggers copy', (WidgetTester tester) async {
      bool copied = false;
      bool deleted = false;

      final entry = ClipboardEntry(
        id: 'test-id-1',
        deviceId: 'device-local',
        contentType: 'text',
        content: 'Antigravity Tampal Text',
        createdAt: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClipboardCard(
              entry: entry,
              isLocal: true,
              onCopy: () => copied = true,
              onDelete: () => deleted = true,
            ),
          ),
        ),
      );

      expect(find.text('Antigravity Tampal Text'), findsOneWidget);
      expect(find.text('This Device'), findsOneWidget);

      // Tap card to copy
      await tester.tap(find.byType(ClipboardCard));
      await tester.pump();

      expect(copied, isTrue);

      // Tap delete icon
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pump(const Duration(seconds: 2));

      expect(deleted, isTrue);
    });

    testWidgets('EmptyStateView renders title, message, and action button', (WidgetTester tester) async {
      bool actionTriggered = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmptyStateView(
              title: 'No Items',
              message: 'Your clipboard history is clear.',
              actionLabel: 'Sync Now',
              onAction: () => actionTriggered = true,
            ),
          ),
        ),
      );

      expect(find.text('No Items'), findsOneWidget);
      expect(find.text('Your clipboard history is clear.'), findsOneWidget);
      expect(find.text('Sync Now'), findsOneWidget);

      await tester.tap(find.text('Sync Now'));
      await tester.pump();

      expect(actionTriggered, isTrue);
    });
  });
}
