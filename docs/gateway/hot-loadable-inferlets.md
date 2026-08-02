# Tree-of-Thought + Best-of-N as hot-loadable inferlets

**Status:** plan, rev 2 (post-review) · decisions taken

Rev 2 corrects four blocking holes and six design errors found in review. The
mode-neutral canonical boundary survives unchanged; the request contract, the
gateway protocol, the Best-of-N commit path, the snapshot-enforcement claim, and
the entire eviction section did not.

## 1. Context

The gateway migration shipped chat only; `/v1/inferlet` and dispatch-shaped
ToT/Best-of-N requests return **501**, which gates the production flip. The goal
is the mode switch: run ToT **once** mid-conversation and continue with ordinary
chat without discarding the conversation KV.

**Legacy does not do this at all.** `Inferlets/chat-apc/src/tot/` contains no
`Context::save|open|delete` and no `prefix_cache` reference; every ToT request is
`Context::new` → `fill_context(full history)` → `flush()`
(`tot/mod.rs:294,309,326`). Best-of-N's `bon/` snapshots are only the resume
handle for the pick, released by the app at commit
(`ChatScaffoldView.swift:1049-1053`). So this adds cross-turn reuse for the first
time.

**What legacy gets right and must be ported unchanged:** the root is flushed
before forking, so committed pages are shared by refcount and only the tail page
is copied (`runtime/context/snapshot.rs:134-145`). The SDK `fork()` clones an
unflushed buffer (`sdk/.../context.rs:181`), so an unflushed root makes every
child re-prefill.

## 2. Decisions

| | decision |
|---|---|
| Eviction policy fix | **Ship without it** — but add the observability API (§5) |
| `conv/` writer | **Shared `gen_core::save_boundary`** |
| Scope | **ToT first, Best-of-N after** |
| Caching granularity | **Final answer only** |
| `bon-0` collision | Document; superseded by §6 digest naming |
| Reuse direction | **Both** entry and exit |
| Inferlet trust | **Trusted directory** for now; true drop-in needs pie ACLs (§4.3) |

## 3. The canonical boundary

```
conv/{h(chat_key)}/{h(compat)}/{digest}
digest = BLAKE3(len-delimited: model_id ‖ PROMPT_MARKER ‖ prefix_tokens)
```

**Digest, not FNV.** The reference implementation's paired FNV construction is
inappropriate for a cache whose collision result is *wrong KV*. Fields are
length-delimited to prevent boundary ambiguity. `chat_key` and `compat` are
hashed (or strictly encoded) rather than interpolated raw — client strings in a
slash-delimited name permit namespace ambiguity and unbounded length.

Two prerequisites:

**(a) `PROMPT_MARKER` must be shared.** Today it is
`concat!("chat-apc-", CARGO_PKG_VERSION)` (`prefix_cache.rs:628`) — per-crate and
hashed into the name, so cross-inferlet hit rate is structurally 0%. Becomes a
`prompt-v{N}` constant in `gen-core`.

**(b) The shared prefix is mode-agnostic.** No cue (`CueMode::None`) **and no
`/no_think`**. `/no_think` is a Qwen3 inline directive suppressing thinking mode;
ToT (`tot/mod.rs:248`) and Best-of-N (`bestofn/mod.rs:240`) append it to the last
user message when `thinking:false`, chat does not. Mutating the base diverges
their tokens from chat's for the same conversation. Move it **after the fork**,
per branch — legacy notes the per-branch prefill already carries it
(`bestofn/mod.rs:235`).

### 3.1 What "same boundary" means

Identical token ids imply identical KV **only** on the canonical `gen-core` path
with the same model incarnation, positions, masks and adapters. Therefore:

- Only that path may write `conv/`. Any inferlet using a private prompt builder,
  a different adapter, or custom masks must not.
- `open_boundary` must verify `full_tokens.starts_with(prefix_tokens)`. The
  reference helper compares lengths only, which admits a same-length different
  prefix.

## 4. Request and protocol contract

### 4.1 `BoundaryDirective` is a top-level field — BLOCKING

The namespace needs `chat_key`/`compat`, but only ordinary chat sends
`ChatCacheDirective` (`ChatSendController.swift:673`). `ToTRequestInput` (:1182)
carries **only `model`**; `BestOfNRequestInput` (:1203) carries model + messages.
The gateway cannot derive conversation identity from messages. As things stand
`chat→ToT→chat` cannot share the namespace.

Add a typed directive as a **top-level field of every generative request**, not
buried per-inferlet:

```
BoundaryDirective { key, compat, turn, policy, retention }
```

Swift request construction is therefore **in scope**:
`Shared/Persistence/ChatSendController.swift`, `Shared/Engine/EngineClient.swift`.

### 4.2 Registry entries declare a protocol class — BLOCKING

"No gateway code" is false without this. The chat driver commits HTTP on
`Event::Ready` (`chat.rs:145`). The captured ToT and Best-of-N streams begin with
`tree_start`, contain **no `Ready`**, and end with `tree_complete` /
`awaiting_selection`, not a chat `Finish`
(`ratio-wire/tests/fixtures/{tot,bestofn}_stream.sse`). Unchanged, ToT hangs to
`first_event_timeout`; adding `Ready` breaks the golden stream.

```
protocol = "chat-v1" | "tree-v1" | "json-unary-v1"
```

A protocol class defines: the commit event, the terminal event(s), the renderer,
cancellation behaviour, and how the process return value is interpreted.

Honest claim: **no gateway code for a new inferlet implementing an
already-supported protocol class.** A genuinely new interaction shape is a new
protocol class, and that is gateway work.

### 4.3 Manifest prefixes are convention, not enforcement — BLOCKING

The earlier claim that the gateway can enforce prefixes is wrong. The gateway
cannot restrict a guest's `Context::open/save/delete`: pie authorizes by
`(username, name)` with no launching program in the key
(`runtime/src/api/context.rs:56`). A buggy or third-party inferlet can open or
delete `conv/` or another round's `bon/`. Requiring a nonempty prefix is also
wrong for `echo`, which needs no persistence.

**Decision: declare the inferlet directory trusted.** `ratio-names` + workspace
lints are correctness conventions, explicitly *not* a security boundary. Manifest
prefixes are declarations used for GC scoping and duplicate detection, and may be
empty.

**Genuine drop-in third-party inferlets require pie-side per-program prefix ACLs
(empty list = deny-all).** That is a pie feature request, recorded here, not
something this plan can fake.

## 5. Eviction: suspension, not deletion — corrected

The previous section was wrong about the failure mode. Eviction calls
`self.suspend(victim_ctx_id)` and counts `eviction_suspends`
(`sched.rs:790-815`); the `snapshots` name map is untouched.

Consequences:

- An evicted snapshot is **logically present**. `open()` **succeeds** and replays
  the entire prefix.
- **The ladder never fires.** It helps when a snapshot is absent or deleted, not
  when it is off-GPU. "Keep the ladder as the fallback" was wrong.
- The cost of eviction is therefore silent full-prefill replay behind a
  successful open — invisible with today's API.

Victim selection is still degenerate (snapshot `spawn_time` falls back to
`Instant::now()`, `sched.rs:917-921`; tiebreaker prefers later spawn, `:930`;
every bid hardcoded `0.0`, `snapshot.rs:189,343,778`; `active_snapshots` read only
by `enforce_snapshot_retention`, `:424-428` — so `retain_snapshot` is decorative).

**Observability is required, not optional.** "Count a replay-open as a miss" is
unimplementable: the WIT returns `result<context, error>` with no residency or
replay report. Add a small API surfacing `snapshot_found` plus
`resident_prefix_tokens` / `replayed_tokens`. Without it the verification in §8
cannot be written and the cache looks healthy while re-prefilling.

Recorded upstream fix: `find_eviction_victim` skips names in `active_snapshots`;
`save`/`fork`/`take_inner` inherit the source bid.

## 6. Per-mode specifics

### 6.1 ToT — preserve the root, save before the terminal event

Do **not** reconstruct the boundary after search. Instead:

1. Build the canonical root once (cue-free, `/no_think`-free) and **keep it**.
2. Run the search from a `fork` of it.
3. After branch contexts drop, save the untouched root (client boundary), then
   append `assistant(final_answer)`, `flush()`, save (generated boundary).
4. **Complete both saves before emitting `tree_complete`** — otherwise the next
   chat request can race the save and miss.

This also keeps the peak-fork window off the save.

### 6.2 Best-of-N needs an explicit commit — BLOCKING

A generation process cannot know which candidate becomes the answer, and the
terminal release request carries only `model` + snapshot names
(`ChatSendController.swift:1011`). So Best-of-N→chat would still fall back to a
shorter ladder boundary, contradicting both "entry and exit" and "final answer
only".

Add a **commit operation** carrying the boundary directive, canonical history,
the selected candidate, and the round identity. It saves the selected `conv/`
boundary **and then** releases the round's snapshots before acknowledging.

**Candidate naming and resume validation.** A gateway-minted UUID removes
`bon-0` but does not bind `resume_from` to `picked_text` — a stale or mismatched
pair silently opens one candidate while the UI believes it selected another.
Therefore:

- Candidate names embed a digest of `canonical_base ‖ candidate_answer`.
- Resume **recomputes and validates** that digest before using the snapshot.
- Every `unpicked` name must parse under the same round prefix. **Never delete an
  arbitrary client-supplied snapshot name.**

## 7. Milestones

**A — shared naming + boundary I/O.** `PROMPT_MARKER`, digest naming, `conv/`,
`save_boundary` / `open_boundary` (with the `starts_with` check) in `gen-core`;
`ratio-names` gains `conv/`; `BoundaryDirective` added to the wire and to the
Swift request builders; chat wired through it.
*Exit: chat→chat exact hit; chat A/B stays byte-identical.*

**B1 — transactional registry, proven with `echo`.** Directory scan, artifact
hashing, duplicate route/program-id rejection, immutable versions, atomic swap,
protected `/v1/admin/reload`, protocol class plumbed (`chat-v1` only so far).
A `OnceCell` is insufficient once an existing route's files change.
*Exit: reload `echo` with changed bytes, no restart, no gateway rebuild.*

**B2 — ToT.** `tot-core` + `tot.wasm`; `BranchSink` → `&dyn EventSink`; the 15
`sse::json_error` sites → `GenError`; `/no_think` after the fork; `tree-v1`
protocol class; entry via `open_boundary`, exit per §6.1.
*Exit: **chat→ToT→chat exact hit**; ToT frames match the golden fixtures.*

**C — Best-of-N.** `bestofn.wasm` over `tot-core`; digest-named candidates;
validated resume; the §6.2 commit operation.
*Exit: **chat→Best-of-N→select/commit→chat exact hit**; round → pick →
think-more works; A/B vs chat-apc.*

Splitting B is deliberate: it previously combined hot loading, a new process
protocol, ToT extraction and cross-mode caching in one step, which makes failures
hard to localize.

## 8. Files

- `Inferlets/gen-core/src/{prompt.rs,lib.rs}` + new `boundary.rs` — marker,
  digest naming, save/open. Reference pattern: `chat-apc/src/chat/prefix_cache.rs`
  `plan` (:714-765) and `finalize` (:903-950).
- `Inferlets/ratio-names/` (new) — namespace registry.
- `Inferlets/{tot-core,tot}/`, later `bestofn/` — ported from `chat-apc/src/tot/`
  and `src/bestofn/`.
- `Gateway/ratio-gateway/src/{routes.rs,chat.rs}` + new `registry.rs` and
  protocol-class dispatch; the 501 arms come out.
- `Shared/Persistence/ChatSendController.swift`, `Shared/Engine/EngineClient.swift`
  — `BoundaryDirective` on every generative request; Best-of-N commit request.
- `Inferlets/ratio-wire/` — the tree/interactive `Event` variants and fixtures
  already exist; expect additions only for the commit operation.

## 9. Verification

- **chat→ToT→chat exact hit** and **chat→BoN→commit→chat exact hit**. A forked
  namespace yields a slow turn, not an error, so nothing else detects it.
- Assert on `resident_prefix_tokens` / `replayed_tokens` (§5), not on
  `open()` success — an evicted snapshot opens fine and replays everything.
- `full_tokens.starts_with(prefix_tokens)` negative test.
- Resume-digest mismatch is rejected, and an unpicked name outside the round
  prefix is refused rather than deleted.
- Golden frames vs `ratio-wire/tests/fixtures/{tot,bestofn}_stream.sse`.
- A/B vs the chat-apc oracle at `temperature=0`, via `Gateway/dev/run.sh ab`.
- Reload: change an inferlet's bytes, reload, confirm the new version serves and
  a duplicate route is rejected.
- Chat A/B byte-identical after A — the regression guard on the naming change.

## 10. Known gaps, recorded deliberately

- **Eviction policy.** Until the upstream fix lands, a suspended boundary opens
  successfully and replays. Detectable only via the §5 observability addition.
- **No snapshot isolation between inferlets.** Trusted-directory assumption;
  drop-in third-party inferlets need pie-side per-program prefix ACLs.
- **ToT intermediate nodes are never cached**, by decision.
- **Best-of-N's N sequential post-generation saves** (`mod.rs:444-449`) carry over
  as-is; each costs an extra prefill while the generation contexts holding that
  KV are dropped at `:444`.
