import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:genuiform/genuiform.dart';
import 'package:genuiform_a2ui/genuiform_a2ui.dart';

import 'api_key_panel.dart';
import 'scenario_page.dart';
import 'scenarios/freelance_qualification.dart';
import 'scenarios/gymgeist_onboarding.dart';

void main() {
  runApp(const GenuiformExampleApp());
}

class GenuiformExampleApp extends StatelessWidget {
  const GenuiformExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'genuiform examples',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Compile-time --dart-define=GEMINI_API_KEY=xxx (free tier from
  // aistudio.google.com/apikey). Vertex AI from a Flutter client must go
  // through Firebase, not via a baked-in API key.
  static const _envApiKey = String.fromEnvironment('GEMINI_API_KEY');

  late final ValueNotifier<String> _apiKey;

  /// Runtime toggle controlling whether terminal outcomes render via the
  /// A2UI machinery (`A2uiOutcomeRenderer` streaming a Gemini-emitted A2UI
  /// tree, with hand-crafted fallback) or via a SnackBar.
  late final ValueNotifier<bool> _useA2ui;

  static const _model = 'gemini-flash-latest';

  @override
  void initState() {
    super.initState();
    _apiKey = ValueNotifier(_envApiKey);
    _useA2ui = ValueNotifier(false);
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _useA2ui.dispose();
    super.dispose();
  }

  LlmClient _buildClient() => GeminiApiClient(apiKey: _apiKey.value);

  /// Builds a fresh emitter scoped to one scenario run. The page disposes
  /// the loader's stream when it tears down; the emitter itself is
  /// stateless beyond the bound [LlmClient], so re-creation is cheap.
  A2uiOutcomeEmitter _buildEmitter(LlmClient client) =>
      A2uiOutcomeEmitter(
        source: GeminiA2uiOutcomeSource(client: client),
      );

  void _openScenario({
    required String title,
    required ScenarioSpec Function({required void Function(String) showFeedback})
        specBuilder,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) {
          final client = _buildClient();
          // showFeedback for EscalateIf handlers — uses the page's scaffold,
          // not this home screen's, so we need the route's context.
          void showFeedback(String msg) {
            if (!routeContext.mounted) return;
            ScaffoldMessenger.of(routeContext)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(msg)));
          }

          final spec = specBuilder(showFeedback: showFeedback);
          return ScenarioPage(
            title: title,
            spec: spec,
            client: client,
            model: _model,
            useA2ui: _useA2ui.value,
            emitter: _useA2ui.value ? _buildEmitter(client) : null,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('genuiform examples')),
      body: ListenableBuilder(
        listenable: Listenable.merge([_apiKey, _useA2ui]),
        builder: (context, _) {
          final hasKey = _apiKey.value.isNotEmpty;

          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── API key input ───────────────────────────────────────────
                ApiKeyPanel(
                  notifier: _apiKey,
                  label: 'Gemini API key (AIza…)',
                ),
                const SizedBox(height: 16),

                // ── A2UI mode toggle ────────────────────────────────────────
                Card(
                  child: SwitchListTile(
                    value: _useA2ui.value,
                    onChanged: (v) => _useA2ui.value = v,
                    title: const Text('A2UI outcome screens'),
                    subtitle: Text(
                      _useA2ui.value
                          ? 'Terminal outcomes render via a2ui_flutter '
                              '(A2UI v0.9). Gemini emits the tree; falls '
                              'back to a hand-crafted tree on timeout/error.'
                          : 'Terminal outcomes show a SnackBar with the '
                              'handoff label (deterministic).',
                    ),
                    secondary: Icon(
                      _useA2ui.value
                          ? Icons.electric_bolt
                          : Icons.notifications_outlined,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Demo 1 ──────────────────────────────────────────────────
                FilledButton.icon(
                  onPressed: hasKey
                      ? () => _openScenario(
                            title: 'Freelance qualification',
                            specBuilder: freelanceQualificationSpec,
                          )
                      : null,
                  icon: const Icon(Icons.support_agent),
                  label: const Text(
                    'Demo 1 — Freelance qualification (branching)',
                  ),
                ),
                const SizedBox(height: 12),

                // ── Demo 2 ──────────────────────────────────────────────────
                FilledButton.icon(
                  onPressed: hasKey
                      ? () => _openScenario(
                            title: 'GymGeist onboarding',
                            specBuilder: gymgeistOnboardingSpec,
                          )
                      : null,
                  icon: const Icon(Icons.fitness_center),
                  label: const Text(
                    'Demo 2 — GymGeist onboarding (ladder + branch)',
                  ),
                ),
                const SizedBox(height: 12),

                // ── Demo 3 — Dev tools (works without a real key) ───────────
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const _DevToolsDemoScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.developer_mode),
                  label: const Text(
                    'Demo 3 — Dev tools (no API key needed)',
                  ),
                ),

                // ── No-key hint ─────────────────────────────────────────────
                if (!hasKey) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Paste your Gemini API key (free tier from '
                    'aistudio.google.com/apikey) above to enable demos 1 and 2.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── Dev tools demo screen ─────────────────────────────────────────────────────

/// Demonstrates [OutcomeTreeView], [AnswerHistorySidebar], and [SplitUserDemo]
/// using [FakeLlmClient] scripts — no real Gemini API key required.
class _DevToolsDemoScreen extends StatefulWidget {
  const _DevToolsDemoScreen();

  @override
  State<_DevToolsDemoScreen> createState() => _DevToolsDemoScreenState();
}

class _DevToolsDemoScreenState extends State<_DevToolsDemoScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dev tools demo'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Tree view'),
            Tab(text: 'Answer history'),
            Tab(text: 'Split demo'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _OutcomeTreeTab(),
          _AnswerHistoryTab(),
          _SplitDemoTab(),
        ],
      ),
    );
  }
}

// ── Tab 1: OutcomeTreeView ─────────────────────────────────────────────────────

class _OutcomeTreeTab extends StatelessWidget {
  const _OutcomeTreeTab();

  @override
  Widget build(BuildContext context) {
    // GymGeist outcome tree from spec §11.2
    final tree = Layer(
      id: 'account_only',
      contractDelta: Contract(fields: {
        'email': const FieldSpec(type: 'String', required: true),
        'name': const FieldSpec(type: 'String', required: true),
      }),
      handoff: null,
      next: Layer(
        id: 'with_workout_plan',
        contractDelta: Contract(fields: {}),
        handoff: null,
        next: Branch(
          id: 'nutrition_path',
          options: [
            BranchOption(
              id: 'with_meal_plan',
              criterion: 'user wants concrete meals planned',
              contractDelta: null,
              child: Outcome(
                id: 'full_meal_plan',
                contractDelta: Contract(fields: {}),
                handoff: null,
              ),
            ),
            BranchOption(
              id: 'skip_nutrition',
              criterion: 'user opts out of nutrition',
              contractDelta: null,
              child: Outcome(
                id: 'workout_only',
                contractDelta: Contract(fields: {}),
                handoff: null,
              ),
            ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'GymGeist outcome tree — active path: account_only → with_workout_plan',
            style: TextStyle(fontStyle: FontStyle.italic),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: OutcomeTreeView(
              root: tree,
              activePath: const ['account_only', 'with_workout_plan'],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Tab 2: AnswerHistorySidebar ────────────────────────────────────────────────

class _AnswerHistoryTab extends StatelessWidget {
  const _AnswerHistoryTab();

  @override
  Widget build(BuildContext context) {
    final step1 = const QuizStepSpec(
      id: 'email',
      title: 'What is your email?',
      inputType: QuizInputType.text,
    );
    final step2 = const QuizStepSpec(
      id: 'goals',
      title: 'What are your fitness goals?',
      inputType: QuizInputType.multiChoice,
    );
    final step3 = const QuizStepSpec(
      id: 'intensity',
      title: 'How intense do you want your workouts?',
      inputType: QuizInputType.slider,
    );

    final now = DateTime(2026, 5, 9, 12);
    final history = [
      Answer(
        stepId: 'email',
        stepSpec: step1,
        answer: 'oskar@fr3n.tech',
        timestamp: now,
        engagement: EngagementSignal.strong,
      ),
      Answer(
        stepId: 'goals',
        stepSpec: step2,
        answer: ['lose_weight', 'build_muscle'],
        timestamp: now.add(const Duration(minutes: 1)),
        engagement: EngagementSignal.strong,
      ),
      Answer(
        stepId: 'intensity',
        stepSpec: step3,
        answer: 'idk',
        timestamp: now.add(const Duration(minutes: 2)),
        engagement: EngagementSignal.weak,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Sample session history — 3 answers with mixed engagement',
            style: TextStyle(fontStyle: FontStyle.italic),
          ),
        ),
        Expanded(child: AnswerHistorySidebar(history: history)),
      ],
    );
  }
}

// ── Tab 3: SplitUserDemo ──────────────────────────────────────────────────────

class _SplitDemoTab extends StatelessWidget {
  const _SplitDemoTab();

  // JSON helpers
  static String _askStepJson({
    required String id,
    required String title,
    String inputType = 'text',
    String engagement = 'strong',
  }) =>
      jsonEncode({
        'decision': 'ask_step',
        'step': {'id': id, 'title': title, 'inputType': inputType},
        'engagement': engagement,
      });

  static String _completeJson(String outcomeId) => jsonEncode({
        'decision': 'complete',
        'outcome': {'outcome_id': outcomeId, 'summary': 'Done.'},
        'engagement': 'strong',
      });

  @override
  Widget build(BuildContext context) {
    // Engaged user: asks many questions, reaches deeper outcome
    final engagedScript = FakeLlmClient(
      scriptedResponses: [
        _askStepJson(id: 'q1', title: 'What is your primary goal?'),
        _askStepJson(id: 'q2', title: 'How many days per week?'),
        _askStepJson(id: 'q3', title: 'Do you have any equipment?'),
        _completeJson('book_call'),
      ],
    );

    // Tired user: gets fewer questions, exits at first opportunity
    final tiredScript = FakeLlmClient(
      scriptedResponses: [
        _askStepJson(
          id: 'q1',
          title: 'What is your name?',
          engagement: 'weak',
        ),
        _completeJson('send_proposal'),
      ],
    );

    final outcomes = Branch(
      id: 'lead_split',
      options: [
        BranchOption(
          id: 'book_call',
          criterion: 'engaged, ready to commit',
          contractDelta: null,
          child: Outcome(
            id: 'book_call',
            contractDelta: Contract(fields: {}),
            handoff: null,
          ),
        ),
        BranchOption(
          id: 'send_proposal',
          criterion: 'needs more info',
          contractDelta: null,
          child: Outcome(
            id: 'send_proposal',
            contractDelta: Contract(fields: {}),
            handoff: null,
          ),
        ),
      ],
    );

    return SplitUserDemo(
      contract: Contract(fields: {
        'name': const FieldSpec(type: 'String', required: true),
      }),
      constraints: const [MaxSteps(value: 8)],
      posture: Posture.salesDiscovery(),
      outcomes: outcomes,
      leftClient: engagedScript,
      rightClient: tiredScript,
      model: 'gemini-flash-latest',
      leftLabel: 'Engaged CTO (4 questions)',
      rightLabel: 'Tired founder (2 questions)',
    );
  }
}
