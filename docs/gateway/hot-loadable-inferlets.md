# Hot-loadable inferlets and shared conversation KV

The gateway routes requests through a validated registry of wasm and manifest
pairs. Chat, Tree of Thought, and Best-of-N share a canonical conversation
boundary so a mode switch can reuse compatible KV without putting
mode-specific reasoning into the shared transcript.

## Registry contract

Each manifest declares a route and one supported protocol class:

```
protocol = "chat-v1" | "tree-v1" | "json-unary-v1"
```

The protocol class defines the response commit event, terminal events,
renderer, cancellation behavior, and interpretation of the process return.
Reload validates the whole candidate registry before an atomic swap. Artifact
digests key installation state, so replacing a wasm or manifest takes effect.

The configured directory is trusted. Declared snapshot prefixes allow
collision checks and scoped cleanup, but PIE does not enforce them as an ACL.

## Canonical boundary

All generative requests carry a top-level boundary directive containing the
conversation key, compatibility key, turn, policy, and retention. Names use
hashed components and a digest of the model, shared prompt marker, and
length-delimited prefix tokens:

```
conv/{hash(chat_key)}/{hash(compat)}/{digest}
```

Only `gen-core` may write `conv/` boundaries. A reusable boundary contains the
canonical client-visible transcript with no mode cue, `/no_think` directive,
hidden reasoning, branch text, or candidate-selection instruction.
`open_boundary` verifies that the current prompt actually starts with the
stored prefix tokens, rather than trusting length alone.

The canonical input is checkpointed before generation. If generation produces
a visible answer, `canonical input + assistant(answer)` is checkpointed as a
second boundary. A reasoning-only turn therefore retains a safe prompt-only
checkpoint without caching hidden reasoning.

## Mode behavior

Chat generates from a fork of the canonical input and saves a visible answer
boundary before its terminal event.

Tree of Thought keeps an untouched canonical root while branches run on forks.
After search, it saves the root and then the root plus the visible final answer
before `tree_complete`. This preserves shared pages and prevents the next chat
request from racing the save.

Best-of-N cannot choose its own canonical answer. Its terminal event exposes a
round and candidates; a separate commit request carries the selected answer and
boundary directive. Commit validates the round, saves the selected conversation
boundary, releases all round snapshots, and only then acknowledges success.

## Snapshot naming and cleanup

Round and candidate names include gateway-minted identity so concurrent rounds
cannot collide. Resume and commit validate that identity rather than accepting
arbitrary snapshot names from a client. Release is idempotent and bounded to
the declared round.

Snapshot reuse currently reports name-level reuse. PIE can suspend and replay a
snapshot without exposing whether its prefix remained resident, so
`reused_tokens` is not proof of a GPU-resident hit. Correctness under KV
pressure must therefore be tested separately; precise residency accounting
requires a PIE API change.

## Security and compatibility

- Boundary compatibility includes the model and prompt format.
- Adapters or custom masks that change KV semantics require a distinct
  compatibility key and must not write a shared boundary otherwise.
- Inferlets are trusted until PIE supports per-program snapshot-prefix ACLs.
- Adding an inferlet is data-only only when its interaction fits an implemented
  protocol class.
