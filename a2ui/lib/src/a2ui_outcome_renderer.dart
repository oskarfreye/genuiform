// Renders a per-outcome handoff screen with the A2UI Dart SDKs
// (`a2ui_core` and `a2ui_flutter`).
//
// ─── Stream path (a2uiMessageStream != null) ────────────────────────────────
//
// Each text chunk from the stream is one A2UI wire envelope. It is decoded,
// parsed with [AgentToRendererMessage.fromJson] and passed to
// [MessageProcessor.processMessages]. A chunk that is not a valid envelope
// is logged and skipped.
//
// ─── Fallback path ──────────────────────────────────────────────────────────
//
// If [a2uiMessageStream] is null, errors, or completes without dispatching
// any messages, a hand-crafted v1 `createSurface` + `updateComponents` pair
// is processed directly. The fallback tree includes a Button with the
// configured restart action so the in-Surface Restart still works
// regardless of which path rendered.
//
// ─── Action handler ─────────────────────────────────────────────────────────
//
// [A2uiActionHandler] is created in [initState] and wired before any
// messages are dispatched. It subscribes to the processor's `onAction`
// events and calls [onRestart] when the configured action arrives.

import 'dart:async';
import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/v0_9/basic_catalog.dart' as v0_9;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'a2ui_action_handler.dart';
import 'a2ui_outcome_prompt.dart';
import 'simulated_handoff.dart';

/// Renders a per-outcome handoff screen with the A2UI Dart SDKs.
class A2uiOutcomeRenderer extends StatefulWidget {
  const A2uiOutcomeRenderer({
    required this.outcomeId,
    required this.handoff,
    required this.onRestart,
    this.a2uiMessageStream,
    this.restartActionName = kA2uiRestartAction,
    this.showDebugRestartButton = true,
    super.key,
  });

  final String outcomeId;

  /// May be `null` if no handoff was registered for this outcome — the
  /// renderer's fallback tree still produces a generic "Form completed"
  /// screen in that case.
  final SimulatedHandoff? handoff;

  final VoidCallback onRestart;

  /// When non-null, each chunk from this stream is processed as one A2UI
  /// wire envelope. When null (or when the stream errors / completes empty),
  /// the v1 hand-crafted tree is dispatched.
  final Stream<String>? a2uiMessageStream;

  /// Action name routed to [onRestart] both inside the LLM-emitted tree
  /// and inside the fallback tree. Defaults to [kA2uiRestartAction].
  final String restartActionName;

  /// When true and [kDebugMode] is on, shows a secondary "Restart (debug)"
  /// button below the Surface as a safety net. Workbench enables this;
  /// release-style deployments may want it off.
  final bool showDebugRestartButton;

  @override
  State<A2uiOutcomeRenderer> createState() => _A2uiOutcomeRendererState();
}

class _A2uiOutcomeRendererState extends State<A2uiOutcomeRenderer> {
  late final MessageProcessor<ComponentImplementation> _processor;
  late final String _surfaceId;
  late final A2uiActionHandler _actionHandler;

  StreamSubscription<String>? _streamSub;

  bool _receivedAnyMessage = false;
  bool _usedFallback = false;

  @override
  void initState() {
    super.initState();
    _surfaceId = 'outcome_${widget.outcomeId}';
    _processor = MessageProcessor<ComponentImplementation>(
      // The prompt asks for genui's old basic catalog id, which the SDK's
      // v0.9 basic catalog does not register; serve the basic catalog under
      // that id.
      catalogs: [v0_9.basicCatalog().derive(catalogId: kA2uiBasicCatalogId)],
      validationConfig: ValidationConfig.relaxed,
      reportErrorsOnly: true,
      // A rejected message leaves the surface unchanged; log why.
      onError: (error) =>
          debugPrint('A2uiOutcomeRenderer: ${error.code}: ${error.message}'),
    );

    _actionHandler = A2uiActionHandler(
      controller: _processor,
      onRestart: widget.onRestart,
      actionName: widget.restartActionName,
    );
    _actionHandler.start();

    if (widget.a2uiMessageStream != null) {
      _startStreamPath(widget.a2uiMessageStream!);
    } else {
      _seedFallbackSurface();
    }
  }

  @override
  void dispose() {
    _actionHandler.dispose();
    _streamSub?.cancel();
    _processor.dispose();
    super.dispose();
  }

  void _startStreamPath(Stream<String> stream) {
    _streamSub = stream.listen(
      _handleChunk,
      onError: (Object error, StackTrace stack) {
        debugPrint(
          'A2uiOutcomeRenderer: stream error — falling back to v1 tree. '
          'Error: $error',
        );
        _applyFallback();
      },
      onDone: () {
        if (!mounted) return;
        if (!_receivedAnyMessage) {
          debugPrint(
            'A2uiOutcomeRenderer: stream completed with no messages — '
            'falling back to v1 tree.',
          );
          _applyFallback();
        }
      },
      cancelOnError: true,
    );
  }

  void _handleChunk(String chunk) {
    final AgentToRendererMessage message;
    try {
      message = switch (jsonDecode(chunk)) {
        final Map<String, dynamic> json => AgentToRendererMessage.fromJson(
          json,
        ),
        _ => throw const FormatException('Expected a JSON object.'),
      };
    } on Exception catch (error) {
      debugPrint(
        'A2uiOutcomeRenderer: skipping a chunk that is not an A2UI message. '
        'Error: $error',
      );
      return;
    }
    _processor.processMessages(message);
    if (!_receivedAnyMessage) {
      setState(() => _receivedAnyMessage = true);
    }
  }

  void _applyFallback() {
    setState(() => _usedFallback = true);
    _seedFallbackSurface();
  }

  void _seedFallbackSurface() {
    final version = A2uiProtocolVersion.v0_9.jsonValue;
    final headline = widget.handoff?.label ?? 'Form completed';
    final subtext = widget.handoff != null
        ? 'Outcome reached: ${widget.outcomeId}.'
        : 'Outcome reached: ${widget.outcomeId} (no handoff registered).';

    _processor.processMessages([
      {
        'version': version,
        'createSurface': {
          'surfaceId': _surfaceId,
          'catalogId': kA2uiBasicCatalogId,
        },
      },
      {
        'version': version,
        'updateComponents': {
          'surfaceId': _surfaceId,
          'components': [
            {
              'id': 'root',
              'component': 'Column',
              'children': ['headline', 'subtext', 'restart_btn'],
            },
            {
              'id': 'headline',
              'component': 'Text',
              'text': headline,
              'variant': 'h2',
            },
            {
              'id': 'subtext',
              'component': 'Text',
              'text': subtext,
              'variant': 'body',
            },
            {
              'id': 'restart_label',
              'component': 'Text',
              'text': 'Restart form',
            },
            {
              'id': 'restart_btn',
              'component': 'Button',
              'child': 'restart_label',
              'variant': 'primary',
              'action': {
                'event': {'name': widget.restartActionName},
              },
            },
          ],
        },
      },
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showFallbackBadge = kDebugMode && _usedFallback;
    final footerText = _usedFallback
        ? 'fallback A2UI tree (LLM emit unavailable)'
        : 'rendered live by Vertex via a2ui_flutter (A2UI v0.9)';
    final surface = _processor.model.getSurface(_surfaceId);
    final footerIcon =
        _usedFallback ? Icons.warning_amber_rounded : Icons.electric_bolt;

    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showFallbackBadge)
            Container(
              color: theme.colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'fallback (LLM emit failed)',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: surface == null
                  ? const SizedBox.shrink()
                  : A2uiSurface(key: ObjectKey(surface), surface: surface),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  footerIcon,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  footerText,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          if (kDebugMode && widget.showDebugRestartButton)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: OutlinedButton.icon(
                onPressed: widget.onRestart,
                icon: const Icon(Icons.refresh),
                label: const Text('Restart (debug)'),
              ),
            ),
        ],
      ),
    );
  }
}
