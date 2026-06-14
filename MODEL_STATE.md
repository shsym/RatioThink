# Model & Recovery State — Source-of-Truth Map (#497)

Who owns which piece of "which model / what should the UI do about it",
what transitions are allowed, and which derivations are THE one. Any new
surface must consume these — never re-derive its own.

## Authorities

| Domain | Owner | Persistence | Written by | Cleared / invalidated |
|---|---|---|---|---|
| Per-chat model selection (the pin) | `Chat.modelID` (SwiftData, #460 single authority) | disk | toolbar model menu commits (`persistChatModel`), swap confirm pin, residency seed (`shouldSeedResidentModel`) | "Use profile default" (clears pin) |
| Profile default model | `Profile.model` (TOML, `ProfileStore`) | disk | Settings → Models / "Set as default" on confirm | profile edit/delete |
| Active profile (global start target) | `active-profile` marker (`ProfileStore.activeProfileID`) | disk | profile swap, seed | `clearActiveProfileID` |
| Active model (helper boot memory) | `active-model` marker (`ProfileStore.activeModelID`, #469) | disk | helper records the resolved boot model | cleared on model delete |
| Engine residency | `ModelLoadCenter.residentModelID` (residency-only since #469) | transient | `/v1/models` reconcile, serve executor | leave-`.running` edge, Unload |
| Engine lifecycle status | `EngineStatusStore.status` (helper poll, `EngineSessionSnapshot`) | transient | helper XPC poll | each poll |
| Launch/load target | **derived** — `ModelTarget.resolve(selectedModelID:profileDefault:)` (#497) | n/a (pure) | n/a | n/a |
| Engine boot spec | Helper `LaunchSpecResolver` via `startEngine`/`restartEngine` `(profileID:modelOverride:)`, marker fallback | computed per start | App XPC call / `HelperResumeAction` | n/a |

## The single derivations (per domain, pure + unit-tested)

- **Launch/load target**: `ModelTarget.resolve` = chat pin, else profile
  default, with `source` provenance (`ChatScaffoldView.gateTarget`).
  Consumed by: `ChatStartGate.evaluate(target:)`, `NoModelLoadedPrompt`
  (copy + chip + Load), `availabilityAction`/`MissingModelRecovery`
  (Load-vs-Download axis + missing-model banner keying),
  `LaunchEngineStartPrompt.shouldAsk` (launch ask). Mirrors the boot
  path's precedence (`startEngineForSelectedProfile` boots
  `chat.modelID ?? profile default`), so what the prompt names IS what
  the tap boots.
- **Servable send model**: `ChatScaffoldView.requestModelID` =
  `PIE_TEST_CHAT_MODEL`, else (engine `.running` only) `ModelTarget.resolve`
  (pin, else profile default; #460). Selection intent is not servability:
  with the engine stopped/failed the gate raises instead of letting a send
  die at HTTP.
- **Blocked-send prompt state**: `ChatStartGate.evaluate` (pure reducer)
  → ready / busy / needsLoad(target) / noDefault / engineFailed /
  helperUnreachable / configBroken.
- **Engine-fault copy + recovery affordance**: `EngineProblem
  (statusCode:rawMessage:)` (#477) — one taxonomy for title, message,
  and the recovery action; raw diagnostics stay in logs.
- **Prompt render plan**: `NoModelLoadedPrompt.plan(state:action:)`
  (pure; #497: download headline is source-honest).
- **Swap/pick confirm policy**: `ProfileSwapCoordinator` keyed on the
  passed selection (`fromModel`), never residency — silent when the new
  profile has no default (pins the current model, #460-AC1), when
  nothing is current (policy 1.5), or when target == current; confirm
  popover otherwise (+ Keep Current Model on the swap path). A confirmed
  pick routes through the engine (re)launch executor (#469).

## Allowed transitions (engine boot target)

- Gate Load / post-download auto-start / toolbar start: profileID +
  `modelOverride = chat.modelID` (nil/blank → profile default).
- Confirmed pick on a running engine: `restartEngine(profileID:modelOverride:)`.
- Menu-bar Resume: profileID + the durable `active-model` marker
  (explicit XPC override > marker > profile default; marker-driven
  resolve retries bounded, #469-F1).
- Helper resolves an override through the SAME safety ladder as a
  default: split-shard refusal, on-disk/HF-cache resolution, memory
  guardrail.

## Invariants

1. No blocked-send prompt surface (gate state, prompt copy/chip,
   availability action, missing-model banner keying, launch ask) reads
   `Profile.model` directly — only through `ModelTarget`
   (`ChatScaffoldView.gateTarget`). Outside the prompt domain, every
   pin-over-default derivation likewise routes through
   `ModelTarget.resolve`: the servable-send model (`requestModelID`), the
   swap policy's current model (`ContentToolbar.effectiveModelID`), and the
   collapsed model label (`ContentToolbar.modelLabel`). Two consumers of
   `selectedProfileDefault` stay deliberately NOT `ModelTarget` because the
   rule differs and folding them would change behavior: the toolbar current
   summary + option list (`toolbarCurrentModelSummary` /
   `toolbarModelOptions`) is `override -> resident -> default` (the live
   resident tier has no `ModelTarget` analogue), and the residency seed
   (`seededModelID`) is a seed-guard (unpinned AND served == default), not a
   pin-over-default pick — what is banned is a prompt surface
   re-deriving pin-vs-default on its own.
2. A pinned selection is never described or actioned as the profile
   default: the gate carries `needsLoad(target)` with
   `source == .selected`, and the boot path receives the pin as
   `modelOverride`.
3. Sends pass the gate only with a running engine (or the test seam) —
   selection intent alone never unlocks a send.
4. No eager loads: every model load/boot is a direct consequence of a
   user action (Load, Retry, confirm, download-complete auto-start).

## Known gaps (follow-up tickets)

- #499 scope shipped via #460 (`Chat.modelID` persists); #498's
  running-engine switch shipped via #469 (`restartEngine`). Remaining:
  the `engineFailed(.modelMissing)` and `.busy` states carry no target
  axis, so their download copy is deliberately target-NEUTRAL ("Model
  isn't downloaded" / "The model isn't downloaded yet…") — honest but
  unable to say "selected". Threading a target through those states
  would close the remaining sliver.
