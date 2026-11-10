import 'package:flutter/material.dart';
import 'package:genuiform/genuiform.dart';
import 'package:genuiform_a2ui/genuiform_a2ui.dart';

import '../llm/workbench_mock_llm_client.dart';
import 'debug_strip.dart';
import 'icon_names.dart';

/// PoC flag — when true, the form's `onComplete` callback hands over to the
/// A2UI-driven outcome renderer instead of showing a `SnackBar`. Tracked in
/// `A2UI_AGENDA.md` as option C.
const bool _kUseA2uiHandoff =
    bool.fromEnvironment('USE_A2UI_HANDOFF', defaultValue: false);

/// Right-pane preview widget.
///
/// Renders a [GenuiForm] built from the four parsed primitives ([contract],
/// [constraints], [posture], [outcomes]) plus [client] and [model].
///
/// The form's internal [FormController] is hoisted out via
/// [GenuiForm.onControllerCreated] so the [DebugStrip] below can subscribe to
/// live session updates.
///
/// Re-keying this widget (via [ValueKey(_formKey)] in the shell) resets the
/// [FormController] cleanly and triggers the fade-in animation.
class FormPreview extends StatefulWidget {
  const FormPreview({
    required this.contract,
    required this.constraints,
    required this.posture,
    required this.outcomes,
    required this.client,
    required this.model,
    this.temperature = 0.7,
    this.handoffMap = const {},
    this.onRestartRequested,
    this.emitter,
    this.onControllerCreated,
    super.key,
  });

  /// Parsed contract — what fields the LLM may collect.
  final Contract contract;

  /// Parsed constraints — rules the LLM must obey.
  final List<Constraint> constraints;

  /// Parsed posture — tone and pacing settings.
  final Posture posture;

  /// Parsed outcome tree root.
  final OutcomeNode outcomes;

  /// The LLM transport forwarded to the inner form.
  final LlmClient client;

  /// The Vertex AI model string.
  final String model;

  /// Sampling temperature forwarded to [GenuiForm]. Defaults to `0.7`.
  final double temperature;

  /// Side-table mapping each Outcome.id to its [SimulatedHandoff].
  /// Used to show a handoff toast when [GenuiForm.onComplete] fires.
  final Map<String, SimulatedHandoff> handoffMap;

  /// Called when the user taps "Restart" in the escalation card.
  /// The shell bumps the form key, which re-keys this widget cleanly.
  final VoidCallback? onRestartRequested;

  /// The A2UI outcome emitter constructed once per session by [AppShell].
  ///
  /// When [_kUseA2uiHandoff] is true AND this is non-null AND [client] is NOT
  /// a [WorkbenchMockLlmClient], [_showHandoffToast] will call the emitter to
  /// stream a live A2UI tree into [A2uiOutcomeRenderer].
  ///
  /// Gating decision ownership: [FormPreview] decides whether to use the emitter
  /// (not [AppShell]) because only [FormPreview] has access to both [client]
  /// (for mock detection) and the build-time [_kUseA2uiHandoff] flag.
  final A2uiOutcomeEmitter? emitter;

  /// Forwarded from [GenuiForm.onControllerCreated]. Lets the workbench shell
  /// hold a reference to the active [FormController] for the progress drawer
  /// without duplicating the inner [GenuiForm] state.
  final void Function(FormController)? onControllerCreated;

  @override
  State<FormPreview> createState() => _FormPreviewState();
}

class _FormPreviewState extends State<FormPreview>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<FormController?> _controller =
      ValueNotifier<FormController?>(null);

  /// When set, the escalation card replaces the form pane.
  EscalateIf? _activeEscalation;

  /// When set (only with [_kUseA2uiHandoff] true), the A2UI outcome renderer
  /// replaces the form pane after `onComplete` fires.
  ///
  /// [a2uiStream] is non-null when the live emit path is active (real client +
  /// emitter present). It is null when the v1 fallback is used (mock client or
  /// no emitter) — [A2uiOutcomeRenderer] handles the null case automatically.
  ({
    String outcomeId,
    SimulatedHandoff? handoff,
    Stream<String>? a2uiStream,
  })? _activeA2uiHandoff;

  /// Drives the fade-in when the form first appears (triggered by re-keying).
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnim = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    );
    // Fade in when this widget first appears (after a form rebuild / re-key).
    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _showHandoffToast(FormResult result) {
    if (!mounted) return;
    final outcomeId = result.reachedOutcome?.id;
    if (outcomeId == null) return;
    final handoff = widget.handoffMap[outcomeId];

    // PoC option C — replace the form pane with the A2UI-rendered outcome.
    if (_kUseA2uiHandoff) {
      // Determine whether to use the live emit path or the v1 fallback.
      //
      // Gating rules (all must be true for the live path):
      //   1. _kUseA2uiHandoff is true (compile-time flag, already true here).
      //   2. widget.emitter is non-null (AppShell constructed one).
      //   3. The client is NOT a WorkbenchMockLlmClient — the mock speaks
      //      scripted form JSON, not A2UI v0.9.
      //
      // The gating decision lives here rather than in AppShell because FormPreview
      // is the site that has both client type visibility and the flag check.
      final bool isMock = widget.client is WorkbenchMockLlmClient;
      Stream<String>? a2uiStream;

      if (widget.emitter != null && !isMock) {
        // Live path: build the loader and request a stream.
        final loader = A2uiOutcomeLoader(emitter: widget.emitter!);
        a2uiStream = loader.load(
          outcomeId: outcomeId,
          handoff: handoff,
          result: result,
        );
      }
      // If isMock or emitter is null, a2uiStream stays null → renderer uses v1
      // fallback path automatically (spec §4.5 "v1 hand-crafted fallback").

      setState(() {
        _activeA2uiHandoff = (
          outcomeId: outcomeId,
          handoff: handoff,
          a2uiStream: a2uiStream,
        );
      });
      return;
    }

    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    if (handoff == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Form completed — outcome: $outcomeId'),
        ),
      );
      return;
    }

    final icon = _iconForHandoff(handoff);
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 10),
            Text('Handoff fired: ${handoff.label}'),
          ],
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // When an A2UI handoff is active, show the A2UI-rendered outcome screen.
    if (_activeA2uiHandoff != null) {
      return A2uiOutcomeRenderer(
        outcomeId: _activeA2uiHandoff!.outcomeId,
        handoff: _activeA2uiHandoff!.handoff,
        onRestart: () {
          setState(() => _activeA2uiHandoff = null);
          widget.onRestartRequested?.call();
        },
        a2uiMessageStream: _activeA2uiHandoff!.a2uiStream,
      );
    }

    // When an escalation is active, show the escalation card instead of form.
    if (_activeEscalation != null) {
      return _EscalationCard(
        trigger: _activeEscalation!.trigger,
        onRestart: () {
          setState(() => _activeEscalation = null);
          widget.onRestartRequested?.call();
        },
      );
    }

    return FadeTransition(
      opacity: _fadeAnim,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: GenuiForm(
              contract: widget.contract,
              constraints: widget.constraints,
              posture: widget.posture,
              outcomes: widget.outcomes,
              client: widget.client,
              model: widget.model,
              temperature: widget.temperature,
              onControllerCreated: (c) {
                _controller.value = c;
                widget.onControllerCreated?.call(c);
              },
              onComplete: _showHandoffToast,
              onEscalation: (rule) {
                if (!mounted) return;
                setState(() => _activeEscalation = rule);
              },
              onError: (err) {
                if (!mounted) return;
                // Don't surface raw transport errors on screen — Vertex's
                // 4xx/5xx error envelopes can echo project IDs, region info,
                // or correlation hints that would be visible on a projector.
                debugPrint('GenuiForm error: $err');
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text(
                          'Form error — see browser console for details.'),
                    ),
                  );
              },
            ),
          ),
          ValueListenableBuilder<FormController?>(
            valueListenable: _controller,
            builder: (context, controller, _) {
              if (controller == null) {
                return const _DebugStripPlaceholder();
              }
              return DebugStrip(controller: controller);
            },
          ),
        ],
      ),
    );
  }
}

// ── Escalation card ────────────────────────────────────────────────────────────

class _EscalationCard extends StatelessWidget {
  const _EscalationCard({
    required this.trigger,
    required this.onRestart,
  });

  final String trigger;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.support_agent,
                  size: 48,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Form ended due to escalation:',
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  trigger,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: onRestart,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Restart'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Icon mapping ───────────────────────────────────────────────────────────────

/// Maps a [SimulatedHandoff.icon] string to a Flutter [IconData].
/// See [iconForName] for the supported set; unknown names render as a flag.
IconData _iconForHandoff(SimulatedHandoff handoff) => iconForName(handoff.icon);

// ── Debug strip placeholder ────────────────────────────────────────────────────

class _DebugStripPlaceholder extends StatelessWidget {
  const _DebugStripPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Text(
        'Debug strip — waiting for form to start…',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
      ),
    );
  }
}
