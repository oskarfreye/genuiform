// Subscribes to the A2UI processor's action events and translates the
// Restart action carried by an in-Surface Button into a Dart callback.
//
// ─── Subscription target ─────────────────────────────────────────────────────
//
// `MessageProcessor.model` (a `SurfaceGroupModel`) exposes:
//
//   EventSource<A2uiRendererAction> get onAction
//
// When the user taps a Button whose `action` is `{"event":{"name":"..."}}`,
// the basic catalog's Button resolves the action and dispatches it on its
// surface, and the processor forwards it to `onAction` as an
// `A2uiRendererAction` carrying the event `name`.

import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:flutter/foundation.dart';

import 'a2ui_outcome_prompt.dart';

/// Subscribes to the `onAction` events of [controller] and fires [onRestart]
/// when an action with name [actionName] arrives. All other action names
/// are ignored (logged in debug mode).
///
/// Lifecycle:
/// 1. Call [start] after constructing the [controller].
/// 2. Call [dispose] in the owning widget's `dispose()`.
class A2uiActionHandler {
  A2uiActionHandler({
    required this.controller,
    required this.onRestart,
    this.actionName = kA2uiRestartAction,
  });

  final MessageProcessor<ComponentImplementation> controller;
  final VoidCallback onRestart;

  /// The A2UI action name routed to [onRestart].  Defaults to
  /// [kA2uiRestartAction].
  final String actionName;

  Subscription? _sub;

  /// Idempotent — calling [start] twice is a no-op.
  void start() {
    if (_sub != null) return;
    _sub = controller.model.onAction.subscribe(_handleAction);
  }

  void dispose() {
    _sub?.unsubscribe();
    _sub = null;
  }

  void _handleAction(A2uiRendererAction action) {
    if (action.name == actionName) {
      onRestart();
    } else {
      debugPrint('A2uiActionHandler: ignoring unknown action "${action.name}"');
    }
  }
}
