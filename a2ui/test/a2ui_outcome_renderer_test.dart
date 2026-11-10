// Tests for workbench/lib/src/preview/a2ui_outcome_renderer.dart
//
// Covers Phase 4 of the A2UI v2 spec (§4.4):
//
//   1. v1 fallback path (a2uiMessageStream == null)
//      — widget renders; Surface is present; fallback badge is NOT shown.
//
//   2. Live-stream path (valid wire envelopes)
//      — widget renders; Surface is present; stream chunks are consumed.
//
//   3. Fallback-on-error path
//      — stream emits an error → v1 tree rendered; debug fallback badge shown
//        (kDebugMode is always true in flutter_test).
//
//   4. Fallback-on-empty path
//      — stream completes immediately with no chunks → v1 tree rendered.
//
//   5. In-Surface Restart smoke test
//      — In the v1 fallback tree, the in-Surface Button with
//        `genuiform/restart` action fires onRestart.
//
// NOTE: kDebugMode is true in flutter_test environments, so assertions about
// the "fallback (LLM emit failed)" badge will be visible in tests.

// ignore_for_file: lines_longer_than_80_chars

import 'dart:async';

import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:genuiform_a2ui/genuiform_a2ui.dart';

// ─── Test constants ───────────────────────────────────────────────────────────

const _kOutcomeId = 'book_call';
const _kHandoff = SimulatedHandoff(
  label: 'Book a call',
  icon: 'phone',
);

// Wire-format JSON strings as produced by A2uiOutcomeEmitter:
// {"version":"v0.9","createSurface":{...}}
// {"version":"v0.9","updateComponents":{...}}
//
// The surfaceId in these envelopes must match what the renderer uses:
// 'outcome_${outcomeId}' → 'outcome_book_call'.

const String _kCreateSurfaceChunk =
    '{"version":"v0.9","createSurface":{"surfaceId":"outcome_book_call","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json","sendDataModel":false}}';

const String _kUpdateComponentsChunk =
    '{"version":"v0.9","updateComponents":{"surfaceId":"outcome_book_call","components":[{"id":"root","component":"Column","children":["headline","restart_btn"]},'
    '{"id":"headline","component":"Text","text":"Book a call","variant":"h2"},'
    '{"id":"restart_label","component":"Text","text":"Restart"},'
    '{"id":"restart_btn","component":"Button","child":"restart_label","variant":"primary","action":{"event":{"name":"genuiform/restart"}}}]}}';

// ─── Helper ───────────────────────────────────────────────────────────────────

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  group('A2uiOutcomeRenderer', () {
    // ── 1. v1 fallback path (null stream) ────────────────────────────────────
    testWidgets(
      'null a2uiMessageStream renders the v1 fallback tree without a fallback badge',
      (WidgetTester tester) async {
        int restartCount = 0;

        await tester.pumpWidget(
          _wrap(
            A2uiOutcomeRenderer(
              outcomeId: _kOutcomeId,
              handoff: _kHandoff,
              onRestart: () => restartCount++,
              // a2uiMessageStream intentionally omitted (null).
            ),
          ),
        );

        // Let the surface build.
        await tester.pumpAndSettle();

        // The A2uiSurface widget should be present.
        expect(find.byType(A2uiSurface), findsOneWidget);

        // The footer with the live-path text should be visible.
        expect(
          find.textContaining('rendered live by Vertex'),
          findsOneWidget,
        );

        // No fallback badge (because we didn't trigger a stream error).
        expect(find.textContaining('fallback (LLM emit failed)'), findsNothing);
      },
    );

    // ── 2. Live-stream path (valid wire envelopes) ────────────────────────────
    testWidgets(
      'valid a2uiMessageStream: Surface renders streamed tree',
      (WidgetTester tester) async {
        // Emit both wire envelopes with a small gap.
        final controller = StreamController<String>();

        await tester.pumpWidget(
          _wrap(
            A2uiOutcomeRenderer(
              outcomeId: _kOutcomeId,
              handoff: _kHandoff,
              onRestart: () {},
              a2uiMessageStream: controller.stream,
            ),
          ),
        );

        // Feed the chunks (mirrors what A2uiOutcomeEmitter yields).
        controller.add(_kCreateSurfaceChunk);
        controller.add(_kUpdateComponentsChunk);
        await controller.close();

        // Allow microtasks + frame rebuilds to settle.
        await tester.pumpAndSettle();

        // The A2uiSurface widget should be present and show the streamed tree.
        expect(find.byType(A2uiSurface), findsOneWidget);
        expect(find.text('Book a call'), findsOneWidget);

        // No fallback badge — we received messages successfully.
        expect(find.textContaining('fallback (LLM emit failed)'), findsNothing);
      },
    );

    // ── 3. Fallback-on-error path ─────────────────────────────────────────────
    testWidgets(
      'stream error triggers v1 fallback and shows debug badge',
      (WidgetTester tester) async {
        final controller = StreamController<String>();

        await tester.pumpWidget(
          _wrap(
            A2uiOutcomeRenderer(
              outcomeId: _kOutcomeId,
              handoff: _kHandoff,
              onRestart: () {},
              a2uiMessageStream: controller.stream,
            ),
          ),
        );

        // Emit an error before any messages.
        controller.addError(Exception('LLM emit failed'));
        // Allow the error to propagate.
        await tester.pump();
        await tester.pumpAndSettle();

        // The Surface still renders (v1 fallback was seeded).
        expect(find.byType(A2uiSurface), findsOneWidget);

        // In kDebugMode (always true in tests), the fallback badge appears.
        expect(
          find.textContaining('fallback (LLM emit failed)'),
          findsOneWidget,
        );
      },
    );

    // ── 4. Fallback-on-empty path ─────────────────────────────────────────────
    testWidgets(
      'stream that completes with no chunks triggers v1 fallback',
      (WidgetTester tester) async {
        // An immediately-closed stream (no items, no error).
        final stream = Stream<String>.empty();

        await tester.pumpWidget(
          _wrap(
            A2uiOutcomeRenderer(
              outcomeId: _kOutcomeId,
              handoff: _kHandoff,
              onRestart: () {},
              a2uiMessageStream: stream,
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Surface present (v1 fallback rendered).
        expect(find.byType(A2uiSurface), findsOneWidget);

        // Fallback badge shown in debug mode.
        expect(
          find.textContaining('fallback (LLM emit failed)'),
          findsOneWidget,
        );
      },
    );

    // ── 5. In-Surface Restart smoke test (fallback tree) ─────────────────────
    //
    // Verifies that the fallback v1 tree includes the Button with
    // genuiform/restart action and that tapping it fires onRestart via
    // A2uiActionHandler.
    testWidgets(
      'tapping the in-surface Restart button in the fallback tree fires onRestart',
      (WidgetTester tester) async {
        int restartCount = 0;

        await tester.pumpWidget(
          _wrap(
            A2uiOutcomeRenderer(
              outcomeId: _kOutcomeId,
              handoff: _kHandoff,
              onRestart: () => restartCount++,
              // null stream → v1 fallback tree with restart_btn.
            ),
          ),
        );

        await tester.pumpAndSettle();

        // The fallback tree includes a Text node "Restart form" as the
        // button label (matching the prompt's recommended copy).
        expect(find.text('Restart form'), findsAtLeastNWidgets(1));

        // Tap the Restart text (which is the child of the restart_btn Button).
        await tester.tap(find.text('Restart form').first);
        await tester.pump();

        // Allow the A2uiActionHandler's stream listener to fire.
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          restartCount,
          1,
          reason: 'onRestart should fire exactly once when tapping the in-surface Restart button',
        );
      },
    );

    // ── 6. Debug-mode secondary Restart button present ───────────────────────
    //
    // kDebugMode is always true in flutter_test, so the outside-the-Surface
    // safety Restart button (§5.3) should always appear in test runs.
    testWidgets(
      'kDebugMode shows secondary outside-the-Surface Restart button',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          _wrap(
            A2uiOutcomeRenderer(
              outcomeId: _kOutcomeId,
              handoff: _kHandoff,
              onRestart: () {},
            ),
          ),
        );

        await tester.pumpAndSettle();

        // The OutlinedButton.icon with label 'Restart (debug)' should be present.
        expect(find.text('Restart (debug)'), findsOneWidget);
      },
    );
  });
}
