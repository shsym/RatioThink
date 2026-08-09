# Gateway data flow

## Current architecture

```
Rational.app
  -> EngineStatus.running(gateway port) over XPC
  -> ratio-gateway HTTP endpoint
  -> PIE WebSocket control plane
  -> selected inferlet wasm
  -> gen-core
```

The gateway owns HTTP, SSE framing, OpenAI response shapes, ids, timestamps,
status codes, routing, and cancellation. PIE owns model processes. Inferlets
own interaction semantics; `gen-core` owns validation, prompts, sampling, and
generation.

For a chat request, the gateway launches the registry entry and waits for its
first protocol event. `Ready` commits a streaming response. A pre-`Ready`
failure remains an HTTP error. Subsequent sequenced events render deltas,
finish state, usage, metrics, and the SSE terminator. Buffered requests consume
the same event stream and serialize the neutral result instead.

When the client disconnects, dropping the response body signals cancellation
to the PIE process. The guest races cancellation with model execution, and the
gateway terminates the process after a bounded grace period on every exit path.

## Legacy architecture

```
Rational.app
  -> PIE HTTP daemon
  -> fresh chat-apc wasm instance
```

The legacy component owns HTTP and generation together. It commits headers
before generation, implements separate streaming and buffered paths, and
cannot use `session::send` because daemon-hosted instances have no PIE Process
actor. This path stops working when PIE removes `wasi:http` daemon hosting.

## Operational differences

| Concern | Legacy daemon | Gateway |
|---|---|---|
| HTTP listener | PIE | native Rust gateway |
| Guest transport | HTTP request/response | PIE WebSocket process events |
| Response ownership | wasm | gateway |
| Request and prompt semantics | wasm | inferlet and `gen-core` |
| Commit point | headers before generation | protocol commit event |
| Cancellation | no process signal | cooperative signal plus termination |
| Streaming and buffered generation | separate loops | shared loop |
| Endpoint publication | daemon port | gateway port |

The app-side URL resolution mechanism is unchanged. Only the helper-published
port changes.
