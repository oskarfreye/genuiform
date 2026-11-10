# genuiform_workbench

Live code editor + form preview for the [genuiform](../) library. Built as the
demo surface for the Generative UI Hackathon — judges sit at the laptop, edit
the form definition on the left, and watch the form rebuild on the right.

```
┌──────────────────────────┬───────────────────────────┐
│  // edit the DSL         │  What's your company?     │
│  final form = GenuiForm( │  [ Acme Industries     ]  │
│    contract: ...         │              [ Continue ] │
│    constraints: [...],   │                           │
│    posture: ...,         │  ─────────────────────    │
│    outcomes: ...,        │  step 3 · strong · path   │
│  );                      │                           │
│  ✓ parsed cleanly        │                           │
└──────────────────────────┴───────────────────────────┘
```

The editor accepts a constrained Dart-shaped **DSL** (not real Dart — Flutter
Web cannot compile Dart at runtime). The DSL parses into the four genuiform
primitives (`Contract`, `List<Constraint>`, `Posture`, `OutcomeNode`) which the
right pane wraps into a live `GenuiForm`. See `WORKBENCH_SPEC.md` §1 for why.

## Run it

The workbench uses Google AI Studio (Gemini API key) plus a stage-safe mock.
Vertex AI from a Flutter client must go through Firebase
(`FirebaseVertexAI.instance`), not via a baked-in bearer token, so the
workbench deliberately does not expose a Vertex transport — for a Vertex demo
use the example app with a Firebase-configured project.

**Live transport — Google AI Studio.** Grab a free key from
[aistudio.google.com/apikey](https://aistudio.google.com/apikey) — no GCP
project, no OAuth dance:

```bash
flutter run -d chrome --dart-define=GEMINI_API_KEY=AIza...
```

If the key is not set at compile time, the workbench shows a paste panel.

To enable the full A2UI round-trip (Gemini emits A2UI v0.9 JSON per outcome,
rendered live via `a2ui_flutter`, with an in-Surface Restart action), add:

```
  --dart-define=USE_A2UI_HANDOFF=true
```

The default (unflagged) path is unchanged: form completion shows a handoff toast.

For a stage-safe demo path that never calls the LLM:

```bash
flutter run -d chrome --dart-define=USE_MOCK=true
```

This swaps in a scripted mock LLM client that completes the
`lead_qualification` scenario in four steps and routes to `book_call`. An
amber `MOCK` chip stays pinned in the top bar so you always know which mode
you're in.

## What's in scope

- **Live parse-and-rebuild** — 250 ms debounce, inline error indicators,
  `parsed cleanly / N warnings / N errors` footer.
- **Four bundled scenarios** picked from a top-bar dropdown, all four parse
  via the same DSL grammar (`lead_qualification`, `gymgeist_onboarding`,
  `newsletter_signup`, `medical_intake`).
- **URL hash state** — `gzip + base64url` of the editor content, capped to
  defend against gzip-bomb URLs. Paste a workbench URL into a fresh tab and
  the editor restores. URL is only updated on clean parses, so bad code
  never lands in the link.
- **Handoff toasts + escalation card** — when the form completes the toast
  shows the named handoff (`Book a call`, `Send proposal`, …) with a Material
  icon. When `EscalateIf` fires the form pane swaps for an escalation card
  with a Restart button.
- **Mobile fallback** — under 900 px, the layout stacks editor-above-form
  and shows a "best viewed on desktop" banner.

## Build for production

```bash
flutter build web --release --dart-define=GEMINI_API_KEY=AIza...
```

The output lands in `build/web/`. The hosting target should serve over HTTPS
and set `X-Frame-Options: DENY` (or rely on the `frame-ancestors 'none'` CSP
we ship in `web/index.html`).

## Tests

```bash
flutter test
```

144 tests across the lexer, parser, builder, four scenario round-trips, URL
hash round-trip, and a top-level widget smoke. The genuiform library has its
own 528-test suite — run from the repo root with `flutter test`.

## Phases

The build was structured in seven phases (see `WORKBENCH_SPEC.md` §5):

| Phase | What landed |
|---|---|
| 0 | scaffold (`flutter create --platforms=web`) |
| 1 | static split layout + hardcoded form |
| 2 | read-only Dart code editor (`re_editor` + Atom One Dark) |
| 3 | DSL parser, AST, builder, handoff registry |
| 4 | live parse-and-rebuild with error indicators |
| 5 | scenario presets + URL hash state |
| 6 | demo polish (animations, toasts, escalation card, mock client, About modal) |

A small additive change to the genuiform library — the `onControllerCreated`
callback on `GenuiForm` — was needed so the workbench's debug strip can
subscribe to live session updates without re-implementing the form internals.
