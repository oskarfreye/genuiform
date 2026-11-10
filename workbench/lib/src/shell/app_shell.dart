import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:genuiform/genuiform.dart';

import 'package:genuiform_a2ui/genuiform_a2ui.dart';

import '../editor/code_editor.dart';
import '../editor/legend_drawer.dart';
import '../editor/progress_drawer.dart';
import '../parser/parse_dsl.dart';
import '../persistence/url_state.dart';
import '../preview/form_preview.dart';
import '../scenarios/scenarios.dart';
import 'split_view.dart';

/// The top-level scaffold of the workbench.
///
/// Renders a top app bar with:
/// - The app title ("genuiform workbench")
/// - A scenario [DropdownButton] populated from [kScenarios]
/// - A "Run" [FilledButton] that re-parses synchronously and resets the form
/// - A Reset [IconButton] (same behaviour as Run)
/// - An "About" icon that opens a modal explaining the DSL constraint
///
/// The body is a [SplitView]: left shows the editable DSL in [_LeftPane];
/// right shows the live [FormPreview].
class AppShell extends StatefulWidget {
  const AppShell({
    required this.client,
    required this.model,
    required this.temperature,
    this.showMockBadge = false,
    super.key,
  });

  /// The LLM client wired up from the entry point.
  final LlmClient client;

  /// The currently-selected Gemini model. A [ValueNotifier] (not a plain
  /// String) so the toolbar dropdown can swap models at runtime: when the
  /// value changes, [_AppShellState] bumps the form key so the form-
  /// generation path picks up the new model on the next step. (The A2UI
  /// emitter is pinned to a `responseJsonSchema`-capable default.)
  final ValueNotifier<String> model;

  /// Sampling temperature shared between both code paths. A [ValueNotifier]
  /// so the toolbar slider can change it at runtime: when the value changes,
  /// [_AppShellState] rebuilds the A2UI emitter (it captures temperature at
  /// construction) and triggers a [setState] so [FormPreview] re-passes the
  /// new value down to [GenuiForm], which forwards it to [FormConfig] via
  /// `rebuildConfig`.
  final ValueNotifier<double> temperature;

  /// Models offered by the toolbar dropdown.
  ///
  /// `*-latest` aliases follow whatever Gemini currently routes to (today
  /// that includes the gemini-3 preview line) — keep them so the "what does
  /// latest behave like right now?" path is one click away. The pinned 2.5
  /// entries give a stable baseline for bisection. We deliberately do NOT
  /// list explicit gemini-3 IDs here because the `-latest` aliases already
  /// cover that family.
  static const candidateModels = <String>[
    'gemini-flash-latest',
    'gemini-flash-lite-latest',
    'gemini-pro-latest',
    'gemini-2.5-flash',
    'gemini-2.5-pro',
  ];

  /// When true, a persistent MOCK badge is shown in the top bar.
  /// Set when `--dart-define=USE_MOCK=true`.
  final bool showMockBadge;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// The id of the currently selected scenario, or `'lead_qualification'`
  /// when no URL hash is present or the hash doesn't match any scenario.
  String _currentScenarioId = 'lead_qualification';

  /// The current DSL source being displayed and edited in the left pane.
  late String _dsl;

  /// Latest parse result. Guaranteed non-null after initState. Drives the
  /// editor's error marks and parse-status footer so feedback stays snappy.
  late ParseResult _parseResult;

  /// The most recent **clean** parse result that has been "committed" — i.e.
  /// forwarded down to [FormPreview]. The form preview reads from this rather
  /// than [_parseResult] so a longer debounce can throttle how often the LLM
  /// is asked to regenerate the current step. Falls back to the last known-
  /// good config while the user is mid-edit (transient parse errors don't
  /// blank out the form).
  late ParseResult _committedParseResult;

  /// Bumping this key forces [FormPreview] to rebuild and restart the form.
  int _formKey = 0;

  /// Debounce timer for re-parsing after keystrokes — short, drives the
  /// editor's inline error feedback.
  Timer? _debounce;

  /// Debounce timer for **committing** a clean parse to [_committedParseResult],
  /// which is what actually triggers [FormController.rebuildConfig] (and thus
  /// an LLM call) downstream. Kept significantly longer than [_debounce] so
  /// active typing doesn't hammer the model.
  Timer? _commitDebounce;

  /// How long to wait after the last keystroke before forwarding new parsed
  /// primitives down to the running form. Empirically: shorter than this and
  /// every typing pause re-fires generation; longer and the live-edit feel
  /// disappears.
  static const Duration _kCommitDebounce = Duration(milliseconds: 2000);

  /// Last DSL value that was synced to the URL hash (avoids redundant writes).
  String _lastSyncedDsl = '';

  /// Used to open the progress end-drawer from the AppBar — the AppBar's
  /// BuildContext doesn't see the [Scaffold] above it, so we route through a
  /// key instead of [Scaffold.of].
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Whether the DSL reference sidebar is currently visible inside the editor
  /// pane. Lives here (not in [_LeftPane]) so the toggle button in the editor
  /// header can open and close the same panel.
  bool _legendOpen = false;

  /// Live reference to the inner [FormController] hoisted out of [GenuiForm]
  /// via [GenuiForm.onControllerCreated]. Driven by [FormPreview], read by
  /// [ProgressDrawer]. A [ValueNotifier] (instead of plain state) means the
  /// drawer rebuilds when the controller is recreated on a Run/Reset.
  final ValueNotifier<FormController?> _controllerRef =
      ValueNotifier<FormController?>(null);

  /// Emitter for the A2UI outcome path.
  ///
  /// Deliberately built without forwarding [widget.model.value]: the toolbar
  /// dropdown is for the form-generation path (which uses Gemini's legacy
  /// `responseSchema` and accepts every listed model). The A2UI outcome path
  /// uses the newer `responseJsonSchema`, which the `-latest` aliases reject
  /// with HTTP 400. Letting [A2uiOutcomeEmitter] use its `gemini-2.5-flash`
  /// default keeps that path stable regardless of the picker.
  ///
  /// Rebuilt when the toolbar temperature slider moves, since the emitter
  /// captures temperature at construction and forwards it to every
  /// `client.generate(...)` call.
  ///
  /// Always constructed (even when the client is a mock), because the gating
  /// decision — whether to actually call through to the emitter — lives in
  /// [FormPreview], which has visibility into both the client type and the
  /// compile-time [_kUseA2uiHandoff] flag.
  late A2uiOutcomeEmitter _a2uiEmitter;

  @override
  void initState() {
    super.initState();

    // Attempt to restore state from the URL hash first.
    final hashDsl = readDslFromUrlHash();
    if (hashDsl != null) {
      _dsl = hashDsl;
      // Find matching scenario by exact DSL equality; fall back to default.
      final match = kScenarios.where((s) => s.dsl == hashDsl).firstOrNull;
      _currentScenarioId = match?.id ?? 'lead_qualification';
    } else {
      _dsl = kScenarios.first.dsl;
      _currentScenarioId = kScenarios.first.id;
    }

    // Parse eagerly so _parseResult is always non-null before the first build.
    _parseResult = parseDsl(_dsl);
    // Initial paint forwards the same result downstream — no debounce on first
    // mount.
    _committedParseResult = _parseResult;

    // Sync the clean initial state to the URL.
    if (_parseResult.isClean) {
      _syncUrl();
    }

    // Construct the A2UI emitter once, pinned to its default model and the
    // initial temperature. AppShell constructs always; FormPreview gates on
    // client type + flag.
    _a2uiEmitter = A2uiOutcomeEmitter(
      source: GeminiA2uiOutcomeSource(
        client: widget.client,
        temperature: widget.temperature.value,
      ),
    );

    // Restart the form whenever the user picks a new model from the toolbar
    // dropdown so the next form-generation step picks it up. The A2UI
    // emitter is unaffected by the picker (see _a2uiEmitter docstring).
    widget.model.addListener(_onModelChanged);

    // Rebuild the A2UI emitter (and re-pass the new value to FormPreview via
    // setState) whenever the toolbar slider moves. Deliberately does NOT
    // bump the form key — temperature changes only affect future LLM calls,
    // and tossing the running session for that is too aggressive.
    widget.temperature.addListener(_onTemperatureChanged);
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    widget.temperature.removeListener(_onTemperatureChanged);
    _debounce?.cancel();
    _commitDebounce?.cancel();
    _controllerRef.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    setState(() {
      // Bump the form key so any in-flight LLM call dies and the next step
      // is regenerated with the new model. Switching models mid-form is a
      // debug action; losing partial answers is acceptable.
      _formKey++;
    });
  }

  void _onTemperatureChanged() {
    setState(() {
      _a2uiEmitter = A2uiOutcomeEmitter(
        source: GeminiA2uiOutcomeSource(
          client: widget.client,
          temperature: widget.temperature.value,
        ),
      );
    });
  }

  /// Writes the current DSL to the URL hash when it is clean and has changed.
  void _syncUrl() {
    if (_parseResult.isClean && _dsl != _lastSyncedDsl) {
      syncHashToUrl(_dsl);
      _lastSyncedDsl = _dsl;
    }
  }

  void _onDslChanged(String newDsl) {
    _dsl = newDsl;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      final result = parseDsl(_dsl);
      setState(() {
        _parseResult = result;
        // Deliberately do NOT bump _formKey on a clean parse: that used to
        // tear down the form and discard every answer the user had filled in.
        // We now flow the new primitives down to FormPreview/GenuiForm which
        // calls FormController.rebuildConfig, preserving session history and
        // re-asking the LLM for the current step against the new DSL. The
        // form key still bumps on explicit Run / Reset / scenario picks.
      });
      _syncUrl();

      // Schedule a separate, longer debounce before forwarding the parsed
      // primitives to the running form. This prevents every typing pause
      // from firing an LLM regeneration. Reset on every keystroke so the
      // commit only happens once typing has actually stopped.
      _commitDebounce?.cancel();
      if (result.isClean) {
        _commitDebounce = Timer(_kCommitDebounce, () {
          if (!mounted) return;
          // Re-check: if the user has continued editing into an error state
          // since the timer was scheduled, leave the previous good config
          // mounted instead of committing nothing.
          if (!_parseResult.isClean) return;
          if (identical(_parseResult, _committedParseResult)) return;
          setState(() {
            _committedParseResult = _parseResult;
          });
        });
      }
    });
  }

  /// Called when the user picks a new scenario from the dropdown.
  void _onScenarioPicked(Scenario scenario) {
    _debounce?.cancel();
    _commitDebounce?.cancel();
    setState(() {
      _currentScenarioId = scenario.id;
      _dsl = scenario.dsl;
      _parseResult = parseDsl(_dsl);
      // Scenario switches are deliberate — commit immediately, no debounce.
      _committedParseResult = _parseResult;
      // Always bump the form key on a deliberate scenario switch — cursor
      // reset and form restart are desired behaviour here.
      _formKey++;
    });
    _syncUrl();
  }

  void _openProgressDrawer() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  void _toggleLegend() {
    setState(() => _legendOpen = !_legendOpen);
  }

  /// Re-parses the current DSL synchronously and bumps the form key
  /// unconditionally, aborting any in-flight stream.
  void _runOrReset() {
    _debounce?.cancel();
    _commitDebounce?.cancel();
    setState(() {
      _parseResult = parseDsl(_dsl);
      // Run/Reset is an explicit "go now" — bypass the commit debounce.
      _committedParseResult = _parseResult;
      _formKey++;
    });
    _syncUrl();
  }

  @override
  Widget build(BuildContext context) {
    // The form pane reads the *committed* parse result so transient errors
    // and rapid keystrokes don't tear down the form / refire the LLM. The
    // editor itself still reflects [_parseResult] for fast error feedback.
    final hasForm = _committedParseResult.hasForm;

    final currentScenario =
        kScenarios.firstWhere((s) => s.id == _currentScenarioId);

    // The dropdown is anchored to the last-picked scenario, but the editor
    // content may have drifted. Render a "(modified)" suffix on the closed
    // dropdown when the DSL no longer matches any preset exactly.
    final isModified = !kScenarios.any((s) => s.dsl == _dsl);

    // Build a side-table of outcomeId → SimulatedHandoff from the *committed*
    // DSL so the handoff map matches the contract currently mounted on the
    // running form.
    final handoffMap = _committedParseResult.handoffMap ?? const {};

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 900;

        // Build the two panes once, then hand them to either layout.
        final leftPane = _LeftPane(
          dsl: _dsl,
          parseResult: _parseResult,
          onChanged: _onDslChanged,
          legendOpen: _legendOpen,
          onToggleLegend: _toggleLegend,
        );

        final Widget rightPane = hasForm
            ? FormPreview(
                key: ValueKey(_formKey),
                contract: _committedParseResult.contract!,
                constraints: _committedParseResult.constraints!,
                posture: _committedParseResult.posture!,
                outcomes: _committedParseResult.outcomes!,
                client: widget.client,
                model: widget.model.value,
                temperature: widget.temperature.value,
                handoffMap: handoffMap,
                onRestartRequested: _runOrReset,
                emitter: _a2uiEmitter,
                onControllerCreated: (c) => _controllerRef.value = c,
              )
            : const _NoParsedFormPlaceholder();

        final Widget shellBody = isMobile
            ? _MobileLayout(left: leftPane, right: rightPane)
            : SplitView(left: leftPane, right: rightPane);

        return Scaffold(
          key: _scaffoldKey,
          endDrawer: ProgressDrawer(controllerRef: _controllerRef),
          appBar: AppBar(
            title: const Text('genuiform workbench'),
            actions: [
              // ── Mock badge ────────────────────────────────────────────────
              if (widget.showMockBadge) ...[
                Chip(
                  label: const Text('MOCK'),
                  backgroundColor: Colors.amber.shade700,
                  labelStyle: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
              ],

              // ── Scenario picker ───────────────────────────────────────────
              DropdownButton<Scenario>(
                value: currentScenario,
                underline: const SizedBox.shrink(),
                selectedItemBuilder: (context) => kScenarios
                    .map(
                      (s) => Center(
                        child: Text(
                          isModified && s.id == currentScenario.id
                              ? '${s.name} (modified)'
                              : s.name,
                        ),
                      ),
                    )
                    .toList(),
                items: kScenarios
                    .map(
                      (s) => DropdownMenuItem<Scenario>(
                        value: s,
                        child: Text(s.name),
                      ),
                    )
                    .toList(),
                onChanged: (scenario) {
                  if (scenario == null) return;
                  _onScenarioPicked(scenario);
                },
              ),
              const SizedBox(width: 12),

              // ── Model picker ──────────────────────────────────────────────
              ValueListenableBuilder<String>(
                valueListenable: widget.model,
                builder: (context, current, _) {
                  return DropdownButton<String>(
                    value: current,
                    underline: const SizedBox.shrink(),
                    items: AppShell.candidateModels
                        .map(
                          (m) => DropdownMenuItem<String>(
                            value: m,
                            child: Text(m),
                          ),
                        )
                        .toList(),
                    onChanged: (next) {
                      if (next == null || next == current) return;
                      widget.model.value = next;
                    },
                  );
                },
              ),
              const SizedBox(width: 12),

              // ── Temperature slider ────────────────────────────────────────
              _TemperatureSlider(notifier: widget.temperature),
              const SizedBox(width: 12),

              // ── Run button ────────────────────────────────────────────────
              Tooltip(
                message: '⌘ Enter / Ctrl Enter',
                child: FilledButton(
                  onPressed: _runOrReset,
                  child: const Text('Run'),
                ),
              ),
              const SizedBox(width: 8),

              // ── Reset button ──────────────────────────────────────────────
              IconButton(
                tooltip: 'Reset',
                onPressed: _runOrReset,
                icon: const Icon(Icons.refresh),
              ),

              // ── Progress drawer ───────────────────────────────────────────
              IconButton(
                tooltip: 'Contract progress',
                onPressed: _openProgressDrawer,
                icon: const Icon(Icons.timeline_outlined),
              ),

              // ── About button ──────────────────────────────────────────────
              IconButton(
                tooltip: 'About this workbench',
                onPressed: () => _showAboutDialog(context),
                icon: const Icon(Icons.info_outline),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              // Cmd+Enter on macOS, Ctrl+Enter elsewhere.
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  _runOrReset,
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _runOrReset,
            },
            child: Focus(
              autofocus: true,
              child: isMobile
                  ? Column(
                      children: [
                        _MobileBanner(onDismiss: () => setState(() {})),
                        Expanded(child: shellBody),
                      ],
                    )
                  : shellBody,
            ),
          ),
        );
      },
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => const _AboutDialog(),
    );
  }
}

// ── Left pane ──────────────────────────────────────────────────────────────────

class _LeftPane extends StatelessWidget {
  const _LeftPane({
    required this.dsl,
    required this.parseResult,
    required this.onChanged,
    required this.legendOpen,
    required this.onToggleLegend,
  });

  final String dsl;
  final ParseResult parseResult;
  final ValueChanged<String> onChanged;
  final bool legendOpen;
  final VoidCallback onToggleLegend;

  /// Build the list of [EditorErrorMark]s from [parseResult.errors].
  List<EditorErrorMark> get _errorMarks => parseResult.errors
      .map(
        (e) => EditorErrorMark(
          line: e.line,
          column: e.column,
          message: e.message,
          hint: e.hint,
        ),
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    final editorColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // DSL editor badge
        Container(
          padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'DSL editor',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              IconButton(
                tooltip: legendOpen ? 'Hide DSL reference' : 'DSL reference',
                onPressed: onToggleLegend,
                isSelected: legendOpen,
                icon: const Icon(Icons.menu_book_outlined, size: 18),
                selectedIcon:
                    const Icon(Icons.menu_book, size: 18),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
        Expanded(
          child: CodeEditor(
            code: dsl,
            readOnly: false,
            onChanged: onChanged,
            errors: _errorMarks,
          ),
        ),
        // Parse status footer (§4.3)
        _ParseStatusFooter(parseResult: parseResult),
      ],
    );

    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: editorColumn),
          if (legendOpen) LegendDrawer(onClose: onToggleLegend),
        ],
      ),
    );
  }
}

// ── Parse status footer ────────────────────────────────────────────────────────

/// A compact footer below the editor showing parse status.
///
/// - green ✓ "parsed cleanly" when [parseResult.isClean]
/// - amber ⚠ "warnings: N" when errors present but form still renders
/// - red ✕ "N error(s)" when fatal — form not rebuilt
///
/// The first error's line/col is appended in muted small text.
class _ParseStatusFooter extends StatelessWidget {
  const _ParseStatusFooter({required this.parseResult});

  final ParseResult parseResult;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    late final Color iconColor;
    late final IconData icon;
    late final String label;

    if (parseResult.isClean) {
      iconColor = Colors.green;
      icon = Icons.check_circle_outline;
      label = 'parsed cleanly';
    } else if (parseResult.hasErrors && parseResult.hasForm) {
      // Soft errors — form still renders with warnings.
      iconColor = Colors.amber;
      icon = Icons.warning_amber_outlined;
      final n = parseResult.errors.length;
      label = 'warnings: $n';
    } else {
      // Fatal — form not rebuilt.
      iconColor = Colors.red;
      icon = Icons.cancel_outlined;
      final n = parseResult.errors.length;
      label = '$n error${n == 1 ? '' : 's'}';
    }

    final firstError =
        parseResult.hasErrors ? parseResult.errors.first : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: iconColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(color: iconColor),
          ),
          if (firstError != null) ...[
            const SizedBox(width: 8),
            Text(
              'Line ${firstError.line}, col ${firstError.column}',
              style: textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Temperature slider ────────────────────────────────────────────────────────

/// Compact toolbar slider tuning the sampling temperature shared by the form-
/// generation path and the A2UI outcome emitter.
///
/// Range mirrors Gemini's accepted band (0.0–2.0). 0.7 is the system-wide
/// default; the slider snaps to 0.1 increments so the value is easy to read
/// at a glance. The current value is rendered to the left of the track so
/// the user can read it without dragging.
class _TemperatureSlider extends StatelessWidget {
  const _TemperatureSlider({required this.notifier});

  final ValueNotifier<double> notifier;

  static const double _min = 0.0;
  static const double _max = 2.0;
  static const int _divisions = 20;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<double>(
      valueListenable: notifier,
      builder: (context, current, _) {
        return Tooltip(
          message: 'Sampling temperature (${current.toStringAsFixed(1)}). '
              'Applies to both form generation and A2UI outcome streams.',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'T ${current.toStringAsFixed(1)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              SizedBox(
                width: 140,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                  ),
                  child: Slider(
                    value: current.clamp(_min, _max),
                    min: _min,
                    max: _max,
                    divisions: _divisions,
                    onChanged: (next) => notifier.value = next,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Right pane placeholder ─────────────────────────────────────────────────────

class _NoParsedFormPlaceholder extends StatelessWidget {
  const _NoParsedFormPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Fix parse errors to preview the form.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

// ── About dialog ───────────────────────────────────────────────────────────────

class _AboutDialog extends StatelessWidget {
  const _AboutDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('About the workbench'),
      content: const SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'DSL editor, not a Dart compiler',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                'This editor is a DSL parser, not a Dart compiler. Flutter Web '
                'cannot compile Dart at runtime, so we accept a constrained '
                'Dart-shaped DSL and parse it into real genuiform types. '
                'Anything outside the grammar is a parse error displayed inline.',
              ),
              SizedBox(height: 16),
              Text(
                'What this means for you',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                'The DSL is a strict subset of Dart. No conditionals, no helpers, '
                'no imports — just literal config trees. Posture presets '
                '(salesDiscovery, supportiveOnboarding, clinicalIntake), '
                'constraints, and outcome trees are all supported. Real '
                'Dart callbacks are replaced by inline simulated handoffs '
                "(e.g. Handoff(label: 'Book a call', icon: 'calendar_today')).",
              ),
              SizedBox(height: 16),
              Text(
                'What this gets you',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                'Pure Flutter Web — no backend, no compilation pipeline, zero '
                'stage risk. Edits re-parse within 250ms and rebuild the live '
                'form on the right. Looks identical to real Dart to a judge '
                'watching over your shoulder.',
              ),
              SizedBox(height: 16),
              Text(
                'Where this sits next to A2UI',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                "Google's A2UI protocol (a2ui.org) and the a2ui_flutter SDK "
                'let an agent draw a UI per turn. genuiform is a layer above '
                "that: where A2UI asks \"what should the UI look like this "
                'turn?", genuiform asks "what should we ask next, given hard '
                'invariants on what may ever be collected and where the form '
                'may land?". The workbench closes the live round-trip: Vertex '
                'emits A2UI v0.9 JSON per outcome, a2ui_flutter renders the '
                'Surface, and the in-Surface Restart button fires back through '
                'an A2UI action — all while the form-collection loop stays '
                "inside genuiform's typed primitives.",
              ),
              SizedBox(height: 16),
              Divider(),
              SizedBox(height: 8),
              Text(
                'genuiform workbench — Spec v0.1, May 2026\n'
                'See README.md for the full library documentation.',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

// ── Mobile layout (stacked, 6.6) ──────────────────────────────────────────────

class _MobileLayout extends StatefulWidget {
  const _MobileLayout({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  State<_MobileLayout> createState() => _MobileLayoutState();
}

class _MobileLayoutState extends State<_MobileLayout> {
  bool _editorCollapsed = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Editor pane (collapsible)
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          child: SizedBox(
            height: _editorCollapsed ? 0 : 300,
            child: widget.left,
          ),
        ),
        // Collapse/expand tab
        GestureDetector(
          onTap: () => setState(() => _editorCollapsed = !_editorCollapsed),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _editorCollapsed
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up,
                  size: 16,
                ),
                const SizedBox(width: 4),
                Text(
                  _editorCollapsed ? 'Show editor' : 'Hide editor',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ),
        // Form pane
        Expanded(child: widget.right),
      ],
    );
  }
}

// ── Mobile banner (6.6) ───────────────────────────────────────────────────────

class _MobileBanner extends StatefulWidget {
  const _MobileBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  State<_MobileBanner> createState() => _MobileBannerState();
}

class _MobileBannerState extends State<_MobileBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    return MaterialBanner(
      content: const Text('Best viewed on desktop'),
      actions: [
        TextButton(
          onPressed: () {
            setState(() => _dismissed = true);
            widget.onDismiss();
          },
          child: const Text('Got it'),
        ),
      ],
    );
  }
}
