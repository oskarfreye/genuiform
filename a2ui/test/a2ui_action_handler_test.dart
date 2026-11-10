// Tests for workbench/lib/src/preview/a2ui_action_handler.dart
//
// Covers Phase 3 of the A2UI v2 spec (§4.3):
//   1. Positive: tapping a Button with action `genuiform/restart` fires onRestart.
//   2. Negative: tapping a Button with action `workbench/other` does NOT fire onRestart.
//
// The test drives a real `MessageProcessor` + `A2uiSurface` widget so that
// the full button→dispatchAction→onAction chain is exercised — not mocked.

// ignore_for_file: lines_longer_than_80_chars

import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/v0_9/basic_catalog.dart' as v0_9;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:genuiform_a2ui/genuiform_a2ui.dart';

// ─── Helpers ─────────────────────────────────────────────────────────────────

const _kSurfaceId = 'test_surface';
const _kCatalogId = 'https://a2ui.org/specification/v0_9/basic_catalog.json';

// IDs used in both tests via the shared surface.
const _kButtonId = 'restart_btn';
const _kLabelId = 'restart_label';
const _kOtherButtonId = 'other_btn';
const _kOtherLabelId = 'other_label';

/// Builds the complete surface with two buttons: one `genuiform/restart` and
/// one `workbench/other`.
void _seedTwoButtonSurface(
  MessageProcessor<ComponentImplementation> controller,
) {
  controller.processMessages([
    {
      'version': 'v0.9',
      'createSurface': {'surfaceId': _kSurfaceId, 'catalogId': _kCatalogId},
    },
    {
      'version': 'v0.9',
      'updateComponents': {
        'surfaceId': _kSurfaceId,
        'components': [
          {
            'id': 'root',
            'component': 'Column',
            'children': [_kButtonId, _kOtherButtonId],
          },
          {'id': _kLabelId, 'component': 'Text', 'text': 'Restart form'},
          {
            'id': _kButtonId,
            'component': 'Button',
            'child': _kLabelId,
            'variant': 'primary',
            'action': {
              'event': {'name': 'genuiform/restart'},
            },
          },
          {'id': _kOtherLabelId, 'component': 'Text', 'text': 'Other action'},
          {
            'id': _kOtherButtonId,
            'component': 'Button',
            'child': _kOtherLabelId,
            'action': {
              'event': {'name': 'workbench/other'},
            },
          },
        ],
      },
    },
  ]);
}

/// Dispatches [name] on the seeded surface as if a Button had been tapped.
void _dispatchAction(
  MessageProcessor<ComponentImplementation> controller,
  String name,
) {
  controller.model.getSurface(_kSurfaceId)!.dispatchAction({
    'event': {'name': name},
  }, 'fake_btn');
}

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  group('A2uiActionHandler', () {
    late MessageProcessor<ComponentImplementation> controller;
    late A2uiActionHandler handler;
    late int restartCallCount;

    setUp(() {
      restartCallCount = 0;
      controller = MessageProcessor<ComponentImplementation>(
        catalogs: [v0_9.basicCatalog().derive(catalogId: _kCatalogId)],
        validationConfig: ValidationConfig.strict,
      );
      handler = A2uiActionHandler(
        controller: controller,
        onRestart: () => restartCallCount++,
      );
      handler.start();
    });

    tearDown(() {
      handler.dispose();
      controller.dispose();
    });

    // ── Positive case ─────────────────────────────────────────────────────────
    testWidgets(
      'fires onRestart exactly once when the genuiform/restart button is tapped',
      (WidgetTester tester) async {
        _seedTwoButtonSurface(controller);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: A2uiSurface(
                surface: controller.model.getSurface(_kSurfaceId)!,
              ),
            ),
          ),
        );

        // Let async rendering settle (surface builds component widgets).
        await tester.pumpAndSettle();

        // Tap the restart button (identified by its label text).
        expect(find.text('Restart form'), findsOneWidget);
        await tester.tap(find.text('Restart form'));
        await tester.pump();

        expect(restartCallCount, 1, reason: 'onRestart should fire exactly once');
      },
    );

    // ── Negative case ─────────────────────────────────────────────────────────
    testWidgets(
      'does NOT fire onRestart when a button with action workbench/other is tapped',
      (WidgetTester tester) async {
        _seedTwoButtonSurface(controller);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: A2uiSurface(
                surface: controller.model.getSurface(_kSurfaceId)!,
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Tap the "other" button.
        expect(find.text('Other action'), findsOneWidget);
        await tester.tap(find.text('Other action'));
        await tester.pump();

        expect(restartCallCount, 0, reason: 'onRestart should NOT fire for workbench/other');
      },
    );

    // ── Idempotency of start() ────────────────────────────────────────────────
    test('start() is idempotent — calling it twice does not double-subscribe', () async {
      _seedTwoButtonSurface(controller);

      // Call start() a second time.
      handler.start();

      // Dispatch an action on the surface to simulate a button tap without
      // needing a widget tree.
      // We verify by counting: if start() were NOT idempotent, two subscriptions
      // would both call onRestart → restartCallCount == 2.
      _dispatchAction(controller, 'genuiform/restart');

      // Give the stream a microtask to deliver the event.
      await Future<void>.delayed(Duration.zero);

      expect(
        restartCallCount,
        1,
        reason: 'double start() should not cause double callback invocation',
      );
    });

    // ── dispose() cancels subscription ────────────────────────────────────────
    test('dispose() cancels subscription so no further callbacks fire', () async {
      _seedTwoButtonSurface(controller);
      handler.dispose();

      _dispatchAction(controller, 'genuiform/restart');

      await Future<void>.delayed(Duration.zero);

      expect(restartCallCount, 0, reason: 'onRestart must not fire after dispose()');
    });
  });
}
