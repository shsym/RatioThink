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

**A — shared naming + boundary I/O.** ✅ **Done** (`ecb19fe`, `29aa4ae`).
`PROMPT_MARKER`, digest naming, `conv/`, `save_boundary` / `open_boundary` (with
the `starts_with` check) in `gen-core`; `ratio-names` gains `conv/`;
`BoundaryDirective` added to the wire and to the Swift request builders; chat
wired through it.
*Exit met: turn 2 reports `boundary_found=true, reused_tokens=22,
prompt_tokens=34`; chat A/B 4/4 byte-identical.*

**B1 — transactional registry, proven with `echo`.** ✅ **Done.** Directory scan,
artifact hashing, duplicate route/program-id rejection, immutable versions,
atomic swap, protected `/v1/admin/reload`, protocol class plumbed (`chat-v1`
only so far). A `OnceCell` is insufficient once an existing route's files change.
*Exit met: `./Gateway/dev/run.sh reload-test` edits `echo`, rebuilds, reloads,
and asserts the new bytes are executing — no restart, no gateway rebuild.*

Two corrections the gate forced, both invisible to a digest-only check:

- **Install tracking is `program id → current digest`, not a set of every
  digest seen.** `program::add` overwrites, so pie holds exactly one artifact
  per program id. A history set makes a revert (A → B → A) skip the reinstall
  while the engine still holds B — the reload reports success and serves the
  wrong bytes. This is why the gate reverts as well as changes.
- **A rebuild is not a byte change.** The wasm build is deterministic, so
  `touch` + rebuild yields an identical digest. The gate edits real source and
  asserts on the emitted marker, not on the digest alone.

Route names come from the manifest's `[ratio]` table, including `aliases`, so
the shipped app's `inferlet: "chat-apc"` reaches `chat` with no per-inferlet
string in the gateway. `--inferlet-dir` replaces the four wasm/manifest flags;
`GatewaySupervisor` passes the bundle's staged directory and no admin token, so
reload is disabled in the shipped app.

**B2 — ToT.** ✅ **Done.** `tot-core` + `tot.wasm`; `BranchSink` → `&dyn
EventSink`; `sse::json_error` → `GenError` (which gained `param`, so ToT's
bounds rejections still name the offending field); `/no_think` after the fork;
`tree-v1` protocol class; entry via `open_canonical`, exit per §6.1.

*Exit met*, `./Gateway/dev/run.sh crossmode`:

| turn | mode | `boundary_found` | `reused_tokens` | prompt |
|------|------|------------------|-----------------|--------|
| 1 | chat (cold) | false | 0  | 13 |
| 2 | **ToT**     | true  | 22 | —  |
| 3 | chat        | true  | 44 | 58 |

Turn 2 proves the entry half (ToT opened the boundary chat left); turn 3 proves
the exit half, and 44 > 22 is what proves it hit ToT's boundary rather than
falling back to turn 1's. Legacy ToT has no `Context::save|open` at all, so this
is a capability that did not previously exist.

**The exit criterion was restated.** The plan said "exact hit"; that is
unsatisfiable by construction. `OpenOutcome.exact` requires a boundary named
over ALL of the new turn's messages, including its new user message, which
nothing has saved yet — so a cross-mode hit is always a ladder rung at
`cut = len-1`. Demanding `exact` would fail 100% of the time even when reuse
works perfectly, and the predictable repair is to weaken it until it proves
nothing. The gate asserts on `reused_tokens` instead, and compares the two
halves against each other.

Live ToT output matches the captured chat-apc stream in structure and content:
both `node_start`s before any delta, siblings interleaving, `node_scoring` for
n1 landing between n2's deltas, and a `tree_complete` byte-identical but for the
now gateway-owned tree id.

*Scope, stated rather than implied:* `TotTask::Chat` and the default
`coupled_sequential` exec strategy — what chat-apc ships. The `reasoning` task
mode, `sibling_penalty`, and the feature-gated phased strategies are ported but
unexercised. Gemma's `<|channel>thought` demux is NOT ported: `gen-core`'s chat
path already omits it, so both modes now degrade identically on Gemma rather
than diverging. Cooperative cancellation is not implemented in the guest (nor
was it in chat-apc); the gateway's terminate bounds it at ~251 ms.

**C — Best-of-N.** ✅ **Done.** `bestofn-core` + `bestofn.wasm` over `tot-core`;
digest-named candidates; validated resume; the §6.2 commit operation; a guarded
release.

*Exit met*, `./Gateway/dev/run.sh bon`:

| step | | `boundary_found` | `reused_tokens` |
|------|---|---|---|
| turn 1 | chat (cold) | false | 0 |
| turn 2 | **Best-of-N round** | true | 22 |
| — | **commit** | `boundary_saved=true, released=3, refused=0` | |
| turn 3 | chat | true | 44 |

Same shape as B2, and 44 > 22 again proves turn 3 hit the boundary the COMMIT
wrote rather than falling back to the one chat left before the round. As with
B2, the criterion is `reused_tokens`, not `exact` — see the note there.

### The destructive path

This is the only milestone where a guest deletes durable state on client
instruction, and legacy had no guard at all:

```rust
fn delete_snapshot(&mut self, name: &str) -> bool {
    Context::delete(self.model, name).is_ok()   // bestofn/release.rs:75-80
}
```

Every name in the request, unvalidated — and pie authorizes by
`(username, name)` with no program in the key, so a request naming
`conv/<other chat>/…` would have deleted another conversation's KV boundary.
`ratio_names::may_delete` now requires the name to PARSE as a digest-named
candidate AND to carry the round's tag. Verified live: a `conv/` boundary and
another round's candidates are both refused and counted, never deleted.

**No fallback for legacy names.** The obvious one — compare the segment after
`bon/` — degenerates to `bon/bon-0/`, which is every pre-port round of every
chat, because chat-apc minted that segment from a counter that restarts with
each wasm instance. A guard that authorizes a mass delete is worse than none,
because it reads as protection. Pre-port snapshots leak once and age out, and
the Swift sweep omits unscoped rounds rather than issuing requests that would
be refused.

### Three corrections the review forced

- **`save_boundary`'s `Result` cannot report whether anything was written.** It
  returns `Err` only for fork/flush faults; `save_one` swallowed every
  `ctx.save` error, and the function short-circuits to `Ok` when reuse is off.
  Gating an irreversible release on `save_boundary(...).await?` would have freed
  the round's KV after writing nothing. It now returns `SaveOutcome`, and commit
  gates on `full_saved`.
- **A resume digest mismatch degrades; it does not 400.** The digest covers the
  canonical tokens including the system turn, which the app recomputes from the
  live profile store at think-more time — so benign drift would have killed the
  round. `picked_text` is already mandatory precisely so the base can be rebuilt,
  and neither branch ever serves unverified KV. Only `WrongRound` is a 400: that
  is an authorization signal, not drift.
- **The release sweep must group by round.** A release is authorized against one
  `round_id`, so the app's flat cross-round name list would have had most of it
  refused while the ack looked like a benign short release.

### Auditing the other gates for the same blind spot

The C-gate lesson — *a gate that builds its own request can only test the half
it models* — was applied to the other three. Both findings were live, and
together they meant ToT and Best-of-N were **completely non-functional in the
shipped app** while all four gates were green.

**The app does not use the endpoint the gates use.**
`HTTPEngineClient.dispatchInferlet` sends streaming ToT and Best-of-N, and
Best-of-N release, to `/v1/chat/completions`; every gate posted to
`/v1/inferlet`. `chat_completions` resolved the route and then drove it with the
CHAT protocol, so a tree guest ran an entire search, returned, and the driver
reported `no_output` / "returned before ready" as a 500 — measured at 14 seconds
of generation thrown away per request. This was masked until
`TreeV1::implemented()` became true in B2: before that, `prepare` refused tree
routes here with an honest 501. Making the tree driver real is what opened it.
Both endpoints now dispatch by protocol class, so which URL a caller picks
cannot change behaviour.

**The bundle shipped a different inferlet set than the dev stack.**
`Scripts/build-gateway.sh` looped over a hardcoded `chat echo` while the repo
had grown `tot` and `bestofn`, so the shipped app registered neither and both
routes would 404 — with every gate green, because the dev driver staged its own
directory. Both scripts now DERIVE the list from which `Pie.toml` files declare
a `[ratio]` table (which also excludes the legacy `chat-apc` monolith), and the
bundle build fails if a declared inferlet does not stage.

**`run.sh endpoints`** is the new gate. It takes its routes from the SERVER's
own `/v1/inferlets`, so a newly registered inferlet is covered without editing
it, and it transcribes the CLIENT's routing rule as data — then asserts the two
agree. Verified as a negative control: reverting the protocol dispatch makes it
fail with `error:no_output` on exactly the routes that were broken.

### Two defects found after the milestone, and why the gate missed them

**P1 — think-more could not resume.** `sendBestOfN` minted a fresh
`UUID().uuidString` on every call, including the resume, so the guest correctly
refused `resume_from` as belonging to a different round. Reproduced: HTTP 400
`snapshot_not_in_round` on every attempt. A think-more CONTINUES its round, so
it now carries the prior scope; `level` is what distinguishes the steps.

**P2 — resumed candidate names were incomplete.** On a resume, the digest
covered the conversation prefix only, while the base the candidates actually
fork from also holds `assistant(picked_text)` and the deepen turn. That made a
level-2 name a function of `(answer)` alone, so two continuations differing only
in which candidate the user picked — or in the comment they typed — produced the
SAME name. Short answers collide constantly. Compounding it, `save_candidate`
returned success on "already exists" while `bon/` is registered
`Collision::ReplaceBeforeSave`: the code silently behaved as `AcceptExisting`,
justified by a comment claiming the digest made the delete unnecessary. It did
not. Both are fixed — the base tokens are complete, and the policy is read from
the registry rather than assumed.

**They interacted, and that is the lesson.** P1 was MASKING P2: a fresh scope
per call meant two continuations landed under different round tags, so their
names could not collide. Fixing P1 alone would have converted a loud 400 into a
silent wrong-KV resume — the UI showing one continuation's text while the engine
served another's context, which is precisely what content-addressing was
introduced to prevent.

**Why the gate stayed green.** `bon.py` built both hops itself and passed the
same `round_id` to each, so it tested whether the guest enforces its contract
and never whether the client can satisfy it. A gate that constructs its own
inputs can only test the half it models. It now mirrors the client — carries the
scope forward — and asserts `resume="warm"`, which required surfacing the resume
kind in the driver's log. Verified as a negative control: reverting the gate to
mint a fresh scope makes it fail.

### The view-side commit

Wired. A level-2 pick now runs the commit operation instead of a bare release,
so accepting an answer writes its `conv/` boundary. `./Gateway/dev/run.sh
view-commit` replays the exact body `ChatScaffoldView` builds and asserts the
next chat turn reuses it: **30 of 42 tokens**, with the app's system prompt in
the digested history.

**The ordering is the whole trick, and it is easy to get backwards.** The commit
is PREPARED before the answer is written locally and DISPATCHED after, because
two invariants pull opposite ways:

* the commit's `messages` must be the canonical history WITHOUT the accepted
  answer — the guest appends `assistant(answer)` itself, and a history already
  containing it names a boundary with the answer twice, which nothing asks for.
  An assistant row with empty content is excluded from request history
  (`excludesFromRequestHistory`), so the body must be built while the row is
  still empty;
* nothing may be deleted unless the local save succeeded — the existing rule
  that stops a rejected commit from discarding its recovery state.

A test asserts the wrong order *does* duplicate the answer, so the invariant has
teeth rather than being a comment.

Two failure paths that would otherwise leak: a commit that throws, and one that
returns `boundary_saved: false`. Both fall back to a plain guarded release —
once the answer is committed the round drops out of the abandon sweep, so
nothing else would ever free it. The boundary is lost (costing the next turn a
re-prefill); the pages come back.

Options are assembled once by `bestOfNSendOptions(for:)` and shared by the round
and the commit. That is not tidiness: the boundary name hashes `transcriptTurns`,
which prepends `systemPromptOverride`, so a commit built from separately
assembled options could name a boundary the next turn never asks for — with no
error, just a permanently cold turn.

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
