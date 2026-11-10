// Prompt template + `responseJsonSchema` for emitting an A2UI v0.9 outcome
// screen.
//
// ─── Schema approach ────────────────────────────────────────────────────────
//
// CHOSEN: a single JSON object with two required top-level keys —
//   { "createSurface": { ... }, "updateComponents": { ... } }
//
// The structured-output validator does not reliably honour `prefixItems`
// (the schema mechanism for an ordered tuple), so a two-element array with
// discriminated union shapes is not viable. `oneOf` over array items would
// also accept arrays in any order or with any mix of message kinds, which
// defeats the purpose. The flat two-property object is cleanly expressible
// and lets the model reason about both halves coherently in a single call.
// The caller ([A2uiOutcomeSource]) reconstructs the two A2UI wire envelopes
// by wrapping each payload with `{"version":"v0.9", ...}`.

import 'simulated_handoff.dart';

/// Catalog identifier for the A2UI v0.9 basic catalog, as genui named it.
///
/// `A2uiOutcomeRenderer` registers the basic catalog under this id.
const String kA2uiBasicCatalogId =
    'https://a2ui.org/specification/v0_9/basic_catalog.json';

/// Surface ID used for outcome screens.  Must be consistent across the
/// `createSurface` and `updateComponents` messages emitted by
/// [A2uiOutcomeSource].
const String kA2uiOutcomeSurfaceId = 'outcome_surface';

/// Default action name carried by the in-Surface Restart Button.
///
/// Both consumers (workbench, example) use this canonical name. Keeping it
/// shared lets the prompt, the renderer's fallback tree, and the action
/// handler stay in lockstep without per-consumer plumbing.
const String kA2uiRestartAction = 'genuiform/restart';

/// Builds the system prompt that instructs the model to emit A2UI v0.9 JSON
/// for the terminal outcome screen.
///
/// The returned string is passed verbatim as `systemInstruction` to
/// [LlmClient.generate]. It tells the model:
/// - What JSON shape to produce (matching [a2uiOutcomeJsonSchema]).
/// - Which catalog to use and what components are allowed.
/// - That the Button with id `restart_btn` must carry the
///   [kA2uiRestartAction] action so the handler can route it back.
/// - Hard prohibitions: no interpolation, no conditionals, no free-form
///   text outside the schema, no deviation from the v0.9 message shape.
String buildA2uiOutcomePrompt({
  required String outcomeId,
  required SimulatedHandoff? handoff,
  required String summary,
}) {
  final handoffContext = handoff != null
      ? 'The outcome reached is "${handoff.label}" (outcome id: "$outcomeId").'
      : 'A generic completion for outcome id: "$outcomeId".';

  return '''
You are an A2UI v0.9 component tree emitter.

Your job is to produce a JSON object describing the completion screen for a
conversational form that just reached a terminal outcome.

## Context

$handoffContext

Session summary from the form:
"$summary"

## Output format

Return EXACTLY one JSON object with two required top-level keys:
  "createSurface" and "updateComponents".

Do NOT add a "version" wrapper — that is added by the caller.
Do NOT add any extra keys beyond "createSurface" and "updateComponents".
Do NOT output markdown fences, prose, or any text outside the JSON object.

### createSurface shape

```
"createSurface": {
  "surfaceId": "$kA2uiOutcomeSurfaceId",
  "catalogId": "$kA2uiBasicCatalogId",
  "sendDataModel": false
}
```

### updateComponents shape

```
"updateComponents": {
  "surfaceId": "$kA2uiOutcomeSurfaceId",
  "components": [ ... array of component objects ... ]
}
```

## Component rules

- Catalog: $kA2uiBasicCatalogId
- Use ONLY these component types: Column, Text, Button, Icon, Card, Divider, Row.
- Every component object MUST have an "id" (unique string) and a "component" key
  naming the type exactly as listed above.
- The root component MUST have id "root" and MUST be a Column.
- The Column's "children" MUST be an array of string IDs referencing other
  components defined in the same "components" array.
- Do NOT nest component definitions inside each other — all components live in
  the flat "components" array, referenced by ID.

### Button requirements

Include a Button with id "restart_btn" whose action is:
```json
{ "event": { "name": "$kA2uiRestartAction" } }
```
The Button's "child" must be the id of a Text component (e.g. "restart_label").
The Text component's "text" should be "Restart form".
Set the Button's "variant" to "primary".

### Text requirements

Every Text component MUST include a "text" property (a plain string literal —
never a path object or interpolation expression).

### Recommended structure

A good outcome screen typically contains:
1. A headline Text (variant "h2") summarising the outcome label.
2. One or two body Text components with brief contextual copy drawn from the
   session summary above. Keep copy concise (≤ 30 words per paragraph).
3. The restart_btn Button described above.

Example minimum-viable component array:
```json
[
  { "id": "root", "component": "Column", "justify": "center", "align": "center",
    "children": ["headline", "body", "restart_btn"] },
  { "id": "headline", "component": "Text", "text": "Outcome headline here",
    "variant": "h2" },
  { "id": "body", "component": "Text", "text": "Brief summary sentence.",
    "variant": "body" },
  { "id": "restart_label", "component": "Text", "text": "Restart form" },
  { "id": "restart_btn", "component": "Button", "child": "restart_label",
    "variant": "primary",
    "action": { "event": { "name": "$kA2uiRestartAction" } } }
]
```

## Hard prohibitions

- NO string interpolation (no \${...} expressions inside text values).
- NO data model path bindings (no {"path": "..."} objects for text values).
- NO conditionals, loops, or any programmatic logic.
- NO components not listed in the "Component rules" section above.
- NO free-form text outside the JSON object.
- NO deviation from the A2UI v0.9 basic-catalog component property names.
- All text MUST be plain string literals — static, not bound to any data model.

Produce the JSON object now.
''';
}

/// Returns the JSON Schema that constrains the model response to the combined
/// `createSurface` + `updateComponents` object described in
/// [buildA2uiOutcomePrompt].
///
/// See [GeminiA2uiOutcomeSource] for the rationale behind the schema design
/// (discriminated-union branches, bounded properties, and the infinite-digit-
/// loop history that motivated this approach).
Map<String, dynamic> a2uiOutcomeJsonSchema() {
  const justifyEnum = ['start', 'center', 'end', 'spaceBetween', 'stretch'];
  const alignEnum = ['start', 'center', 'end', 'stretch'];
  const textVariants = ['display', 'h1', 'h2', 'h3', 'body', 'label'];
  const buttonVariants = ['primary', 'secondary', 'tertiary'];

  // Plain string refs. We deliberately do NOT use `maxLength` even though
  // it's tempting as a runaway-string guard: per the python-genai SDK
  // source (google/genai/types.py, GenerateContentConfig.response_json_schema
  // docstring), Gemini's `responseJsonSchema` does not honour `maxLength` —
  // including it triggers HTTP 400 INVALID_ARGUMENT with no field-level
  // detail. Bounded `maxItems` on parent arrays is our string-runaway guard.
  final stringIdRef = {'type': 'string'};

  Map<String, dynamic> branch({
    required String componentName,
    required Map<String, dynamic> properties,
    required List<String> required,
  }) =>
      {
        'type': 'object',
        'additionalProperties': false,
        'required': ['id', 'component', ...required],
        'properties': {
          'id': stringIdRef,
          'component': {
            'type': 'string',
            'enum': [componentName],
          },
          ...properties,
        },
      };

  return {
    'type': 'object',
    'additionalProperties': false,
    'required': ['createSurface', 'updateComponents'],
    'properties': {
      'createSurface': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['surfaceId', 'catalogId'],
        'properties': {
          'surfaceId': {
            'type': 'string',
            'enum': [kA2uiOutcomeSurfaceId],
          },
          'catalogId': {
            'type': 'string',
            'enum': [kA2uiBasicCatalogId],
          },
          'sendDataModel': {'type': 'boolean'},
        },
      },
      'updateComponents': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['surfaceId', 'components'],
        'properties': {
          'surfaceId': {
            'type': 'string',
            'enum': [kA2uiOutcomeSurfaceId],
          },
          'components': {
            'type': 'array',
            'minItems': 1,
            'maxItems': 16,
            'items': {
              'anyOf': [
                branch(
                  componentName: 'Column',
                  required: ['children'],
                  properties: {
                    'children': {
                      'type': 'array',
                      'minItems': 1,
                      'maxItems': 12,
                      'items': stringIdRef,
                    },
                    'justify': {'type': 'string', 'enum': justifyEnum},
                    'align': {'type': 'string', 'enum': alignEnum},
                  },
                ),
                branch(
                  componentName: 'Row',
                  required: ['children'],
                  properties: {
                    'children': {
                      'type': 'array',
                      'minItems': 1,
                      'maxItems': 8,
                      'items': stringIdRef,
                    },
                    'justify': {'type': 'string', 'enum': justifyEnum},
                    'align': {'type': 'string', 'enum': alignEnum},
                  },
                ),
                branch(
                  componentName: 'Text',
                  required: ['text'],
                  properties: {
                    'text': {'type': 'string'},
                    'variant': {'type': 'string', 'enum': textVariants},
                  },
                ),
                branch(
                  componentName: 'Button',
                  required: ['child', 'action'],
                  properties: {
                    'child': stringIdRef,
                    'variant': {'type': 'string', 'enum': buttonVariants},
                    'action': {
                      'type': 'object',
                      'additionalProperties': false,
                      'required': ['event'],
                      'properties': {
                        'event': {
                          'type': 'object',
                          'additionalProperties': false,
                          'required': ['name'],
                          'properties': {
                            'name': {
                              'type': 'string',
                              'enum': [kA2uiRestartAction],
                            },
                          },
                        },
                      },
                    },
                  },
                ),
                branch(
                  componentName: 'Icon',
                  required: ['name'],
                  properties: {
                    'name': {'type': 'string'},
                  },
                ),
                branch(
                  componentName: 'Card',
                  required: ['child'],
                  properties: {
                    'child': stringIdRef,
                  },
                ),
                branch(
                  componentName: 'Divider',
                  required: const [],
                  properties: const {},
                ),
              ],
            },
          },
        },
      },
    },
  };
}

/// Compatibility alias for [a2uiOutcomeJsonSchema].
@Deprecated('Use a2uiOutcomeJsonSchema() instead')
Map<String, dynamic> a2uiOutcomeResponseJsonSchema() => a2uiOutcomeJsonSchema();
