/// Shared A2UI v0.9 outcome-screen plumbing for genuiform.
///
/// Both `genuiform_workbench` and the example app depend on this package to
/// avoid duplicating the four moving parts of the A2UI integration:
///
/// - [SimulatedHandoff] — value type carrying a label/icon per outcome.
/// - [buildA2uiOutcomePrompt] / [a2uiOutcomeResponseJsonSchema] — Vertex prompt +
///   structured-output JSON Schema for emitting a v0.9 message pair.
/// - [A2uiOutcomeEmitter] — wraps [LlmClient.generate] to yield the two
///   `createSurface` + `updateComponents` envelopes.
/// - [A2uiOutcomeLoader] — first-chunk timeout + summary builder around the
///   emitter; suitable for piping into [A2uiOutcomeRenderer].
/// - [A2uiOutcomeRenderer] — Flutter widget that renders the live A2UI tree
///   via `A2uiSurface`, with an automatic hand-crafted v1 fallback.
/// - [A2uiActionHandler] — translates the in-Surface Restart action back
///   into a Dart callback.
library;

export 'src/a2ui_action_handler.dart';
export 'src/a2ui_outcome_emitter.dart';
export 'src/a2ui_outcome_loader.dart';
export 'src/a2ui_outcome_prompt.dart';
export 'src/a2ui_outcome_renderer.dart';
export 'src/simulated_handoff.dart';
export 'src/a2ui_outcome_source.dart';
export 'src/sources/gemini_a2ui_outcome_source.dart';
