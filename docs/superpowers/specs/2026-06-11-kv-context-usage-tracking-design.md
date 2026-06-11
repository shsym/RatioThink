# KV context usage tracking design

Date: 2026-06-11
Ticket: #517
Project: pie-mac

## Summary

RatioThink should track KV pressure from the runtime's actual page accounting, not from chat transcript length or configured token limits. The authoritative global source is pie's existing WebSocket control-plane `query` subject `model_status`. Per-chat/session attribution is a separate layer: today normal chat completions are request-local, so v1 can attribute only active/in-flight request usage unless persistent chat contexts or snapshots are deliberately introduced.

This design creates a safe observability foundation for future context caching and eviction without overclaiming that inactive chats currently keep resident KV pages.

## Current behavior and verified facts

### Existing channels

RatioThink currently uses three channels around pie:

1. App ⇄ Helper: XPC.
2. Helper ⇄ pie: WebSocket control plane during launch/liveness.
3. App ⇄ chat-apc: loopback HTTP/SSE for `/healthz`, `/v1/models`, `/v1/models/load`, and `/v1/chat/completions`.

`model_status` belongs to channel 2. It is handled by pie itself, not by chat-apc.

### Existing pie `model_status` query

pie's control protocol already supports:

```text
Client -> pie WS MessagePack:
{ type: "query", corr_id: N, subject: "model_status", record: "" }

pie -> Client WS MessagePack:
{ type: "response", corr_id: N, ok: true, result: "<JSON object string>" }
```

The JSON result includes model-qualified keys:

- `<model>.kv_pages_used`
- `<model>.kv_pages_total`
- `<model>.total_batches`
- `<model>.total_tokens_processed`
- `<model>.last_batch_latency_us`
- `<model>.avg_batch_latency_us`

The server builds `kv_pages_used/total` from `context::get_stats(model_idx)`, which asks the runtime context manager for per-device page-store `(used, total)` counts. pie's monitor TUI already uses this query and sums `*.kv_pages_used` and `*.kv_pages_total`.

Session validation on 2026-06-11 launched a local dummy-only pie server and sent the real WebSocket query. It returned:

```json
{
  "default.kv_pages_used": 0,
  "default.kv_pages_total": 256,
  "default.total_batches": 0,
  "default.total_tokens_processed": 0,
  "default.last_batch_latency_us": 0,
  "default.avg_batch_latency_us": 0
}
```

This confirms the endpoint exists and returns actual runtime KV page totals for a live engine.

### Existing inferlet context counters

The pie inferlet SDK already exposes per-context counters on `Context`:

- `tokens_per_page`
- `committed_page_count`
- `working_page_count`
- `working_page_token_count`

chat-apc can use these counters while it owns the active request `Context`. These counters are the correct source for per-request usage reports and streaming checkpoints.

### Current chat context lifetime

Normal `/v1/chat/completions` requests create and fill a fresh `Context` from the request's full messages list. The daemon request instance is dropped after the HTTP request, and process unregister destroys its contexts. Therefore current v1 must treat normal chat contexts as request-local. Inactive chats do not yet have a persistent resident KV context to evict.

## Goals

1. Surface authoritative global KV page usage in the App from pie runtime data.
2. Surface request-local context counters from chat-apc where they are known.
3. Represent unknown or non-resident per-chat states explicitly instead of estimating.
4. Prepare data structures for future persistent chat contexts/snapshots and whole-context LRU eviction.
5. Coordinate with #489: `max_num_kv_pages` bounds the physical pool, while this ticket observes actual usage.

## Non-goals

- Do not implement committed suffix or tail-page truncation.
- Do not derive warnings from transcript length or estimated token counts alone.
- Do not claim inactive chats consume resident pages until persistent chat contexts or snapshots exist.
- Do not move global KV accounting into chat-apc unless pie removes or changes the control-plane source.

## Architecture

### Global usage path

Add a typed App-facing `KVUsageSnapshot` sourced from pie's `model_status` query.

Proposed value types:

```swift
public struct KVUsageSnapshot: Codable, Equatable, Sendable {
  public let modelID: String
  public let pagesUsed: UInt64
  public let pagesTotal: UInt64
  public let observedAt: Date
  public let generation: UInt64
  public let source: KVUsageSource
}

public enum KVUsageSource: String, Codable, Sendable {
  case pieModelStatus
}
```

A refresh should:

1. Open or reuse a pie control-plane connection from the Helper side.
2. Authenticate with `auth_identify` on no-auth engines, matching the liveness probe pattern.
3. Send `query(subject: "model_status", record: "")`.
4. Decode the JSON result into per-model rows.
5. Attach `observedAt` and a monotonically increasing helper-side generation.
6. Return rows to the App over XPC.

The App should discard or visually age snapshots whose generation predates an engine restart, model switch, or failed refresh. Missing fields should decode as unknown/unavailable rather than zero unless pie explicitly reported zero.

### Why not chat-apc for global totals?

chat-apc is the HTTP inferlet and does not currently expose global runtime page-store totals. Adding a chat-apc endpoint would either duplicate pie runtime accounting or require new WIT imports solely to forward global state. The existing pie control-plane path is already runtime-owned, validated, and used by pie's monitor. It is the right source of authority for global totals.

### Request-local usage reports

Add or design a chat-apc SSE meta-frame for request context usage:

```json
{
  "event": "context_usage",
  "scope": "request",
  "model": "<model-id>",
  "request_id": "<opaque-id>",
  "tokens_per_page": 32,
  "committed_page_count": 4,
  "working_page_count": 1,
  "working_page_token_count": 7,
  "checkpoint": "after_prefill"
}
```

Checkpoints should be stable and race-safe:

- `model_ready`: global model is resident; no context claim yet unless counters are included.
- `after_prefill`: request messages have been flushed into the context.
- `periodic_decode`: optional low-frequency progress for long streams.
- `final`: terminal committed/working counts before the request context is dropped.

The HTTP client should tolerate missing `context_usage` frames and unknown checkpoints. Usage frames should update attribution records only when their `request_id` matches the active request identity for the chat.

### Per-chat attribution model

Define a record that can represent known and unknown states honestly:

```swift
public struct ContextUsageRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: ContextUsageID
  public let chatID: UUID
  public let modelID: String
  public let requestID: String?
  public let lastUsedAt: Date
  public let residency: ContextResidency
  public let usage: ContextPageUsage?
}

public enum ContextResidency: String, Codable, Sendable {
  case unknown
  case requestLocalActive
  case requestLocalDestroyed
  case persistentActive
  case persistentSuspended
  case persistentSnapshotBacked
  case destroyed
}

public struct ContextPageUsage: Codable, Equatable, Sendable {
  public let tokensPerPage: UInt32
  public let committedPages: UInt32
  public let workingPages: UInt32
  public let workingTokens: UInt32
  public let checkpoint: String
  public let observedAt: Date
}
```

For current v1 chat completions:

- On send start: create/update a record as `requestLocalActive` with `usage == nil` until a usage frame arrives.
- On matching `context_usage`: update `usage`.
- On finish/cancel/error: mark `requestLocalDestroyed` after the terminal request identity resolves.
- On engine restart/model switch: mark records for the old generation as `unknown` or `destroyed`, depending on whether the App knows the request ended.

The UI or diagnostics must not sum inactive request-local records as resident global usage. Only `persistent*` records should be candidates for future inactive-context eviction.

## Eviction design boundary

The preferred future eviction unit is a whole inactive persistent context/snapshot: suspend or destroy the least-recently-used inactive context when global page pressure crosses a threshold. Active streaming contexts are protected.

Do not implement or promise "drop pages from the back of the oldest chat" unless pie exposes a safe committed-suffix truncation API or chat-apc stores turn-boundary snapshots that can rebuild from a retained prefix. Current SDK truncation applies to working pages, not already committed pages.

## Error handling

Global snapshot refresh should handle:

- Missing `model_status` fields: return `unknown` for affected rows and keep the last good snapshot marked stale.
- Non-JSON `result`: surface a typed decode error and keep stale data visually distinct.
- Control-plane disconnect: surface engine-not-ready/engine-gone separately from decode errors.
- Model switch or engine restart: increment generation and invalidate older records.
- Multiple models in one response: parse each `<model>.*` prefix independently and avoid splitting incorrectly on model IDs that contain dots by matching known suffixes.

Request attribution should handle:

- Missing usage frames: keep `usage == nil` rather than estimating.
- Stale request IDs: ignore the frame.
- Cancel/retry/chat switch: update only the record whose request identity matches the terminal event.

## Testing plan

1. `PieControlClient` request framing:
   - Assert `query/model_status` emits the exact MessagePack shape expected by pie.
2. `KVUsageSnapshot` parser:
   - Decodes `*.kv_pages_used/total` and ignores unrelated counters.
   - Handles missing used or total without fabricating zero.
   - Handles model IDs containing dots by suffix matching.
   - Handles non-JSON and wrong-type fields with typed errors.
3. Refresh generation:
   - Stale snapshots are distinguishable across model switches and engine restarts.
4. Live/diagnostic harness:
   - Launch dummy pie, query `model_status`, and compare App-visible totals with runtime response fields.
5. chat-apc usage frame tests if frames are implemented:
   - Verify counters match `Context` committed/working page counts at `after_prefill` and `final` checkpoints.
   - Verify stale request IDs do not mutate the active chat record.

## Implementation sequence

1. Finish Swift control-plane query support and add a typed parser for `model_status` JSON.
2. Add Helper/XPC method to refresh global KV usage snapshots from the retained or reopened control-plane URL.
3. Add App-side store/state to hold current and stale snapshots keyed by model and generation.
4. Add per-chat `ContextUsageRecord` model and state transitions for request-local active/destroyed records.
5. Add chat-apc `context_usage` frame support only after the frame schema is pinned with tests.
6. Add diagnostic/live test that exercises dummy pie `model_status` and asserts the decoded totals.

## Open follow-ups

- Decide the user-facing UI placement for global KV usage after the data path is green.
- Decide whether persistent chat contexts/snapshots are in scope for a later ticket before implementing LRU eviction.
- Coordinate with #507/#513/#516 so stop/retry/chat switching preserve request identity semantics.
