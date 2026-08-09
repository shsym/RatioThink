//! Golden wire-contract tests (doc/chat-refactor.md §12 L1).
//!
//! Fixtures in `tests/fixtures/` are REAL streams captured from the running
//! `chat-apc` daemon serving Qwen2.5-7B — not hand-written. Each test rebuilds
//! the neutral `Event` sequence that fixture represents, renders it, and
//! asserts the bytes match exactly.
//!
//! The tree/Best-of-N cases are here even though no inferlet emits those
//! events yet. Capturing them BEFORE porting ToT is what makes that port a
//! port rather than a redesign.

use ratio_wire::event::{Channel, Event, FinishReason, NodeView, Pick};
use ratio_wire::render::OpenAiSse;
use serde_json::Value;

fn fixture(name: &str) -> String {
    std::fs::read_to_string(format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR")))
        .unwrap_or_else(|e| panic!("missing fixture {name}: {e}"))
}

/// The `data:` payloads of a captured stream, in order.
fn payloads(raw: &str) -> Vec<String> {
    raw.lines()
        .filter_map(|l| l.strip_prefix("data: "))
        .map(str::to_string)
        .collect()
}

fn meta_kind(p: &str) -> Option<String> {
    let v: Value = serde_json::from_str(p).ok()?;
    v.get("event")?.as_str().map(str::to_string)
}

// ---------------------------------------------------------------------------
// Linear chat — the slice-1 path the renderer actually produces.
// ---------------------------------------------------------------------------

#[test]
fn reproduces_captured_chat_stream_byte_for_byte() {
    let raw = fixture("chat_stream.sse");
    let expected = payloads(&raw);
    assert!(!expected.is_empty(), "fixture had no data frames");

    // Recover the gateway-owned identity from the capture so the comparison is
    // byte-exact rather than normalized.
    let first_chunk: Value = expected
        .iter()
        .find_map(|p| {
            let v: Value = serde_json::from_str(p).ok()?;
            v.get("object")?.as_str().filter(|s| *s == "chat.completion.chunk")?;
            Some(v)
        })
        .expect("no chunk in fixture");
    let id = first_chunk["id"].as_str().unwrap().to_string();
    let model = first_chunk["model"].as_str().unwrap().to_string();
    let created = first_chunk["created"].as_i64().unwrap();

    // Rebuild the neutral event sequence the fixture represents.
    let mut events = vec![Event::Ready];
    let mut finish = None;
    let (mut metrics_counts, mut usage_counts) = (None, None);
    for p in &expected {
        if p == "[DONE]" {
            continue;
        }
        let v: Value = serde_json::from_str(p).unwrap();
        match v.get("event").and_then(Value::as_str) {
            Some("model_ready") => {}
            Some("generation_metrics") => {
                metrics_counts = Some(ratio_wire::MetricsCounts {
                    output_tokens: v["output_tokens"].as_u64().unwrap() as u32,
                    elapsed_s: v["elapsed_s"].as_f64().unwrap(),
                });
            }
            Some("usage") => {
                usage_counts = Some(ratio_wire::UsageCounts {
                    prompt_tokens: v["prompt_tokens"].as_u64().unwrap() as u32,
                    completion_tokens: v["completion_tokens"].as_u64().unwrap() as u32,
                    context_window: v.get("context_window").and_then(Value::as_u64).map(|x| x as u32),
                });
            }
            Some(other) => panic!("unhandled meta frame in fixture: {other}"),
            None => {
                let ch = &v["choices"][0];
                let delta = &ch["delta"];
                if let Some(t) = delta.get("content").and_then(Value::as_str) {
                    events.push(Event::ContentDelta { text: t.into() });
                } else if let Some(t) = delta.get("reasoning_content").and_then(Value::as_str) {
                    events.push(Event::ReasoningDelta { text: t.into() });
                }
                if let Some(fr) = ch.get("finish_reason").and_then(Value::as_str) {
                    finish = Some(match fr {
                        "stop" => FinishReason::Stop,
                        "length" => FinishReason::Length,
                        "tool_calls" => FinishReason::ToolCalls,
                        other => panic!("unexpected finish_reason {other}"),
                    });
                }
            }
        }
    }
    let mut r = OpenAiSse::new(id, model, created);
    let mut got: Vec<String> = events.iter().flat_map(|e| r.render(e)).collect();
    // The terminal sequence has a fixed order that no per-event rendering can
    // produce, so it is emitted as a unit.
    got.extend(r.terminal(
        finish.expect("fixture had no finish_reason"),
        usage_counts,
        metrics_counts,
        None,
    ));

    assert_eq!(
        got.len(),
        expected.len(),
        "frame count differs\n got: {got:#?}\n exp: {expected:#?}"
    );
    for (i, (g, e)) in got.iter().zip(expected.iter()).enumerate() {
        assert_eq!(g, e, "frame {i} differs\n got: {g}\n exp: {e}");
    }
}

// ---------------------------------------------------------------------------
// Tree / interactive — no producer yet, but the shapes are pinned now.
// ---------------------------------------------------------------------------

/// Every distinct tree frame in the captured ToT stream must round-trip
/// through `Event` and re-render to the identical bytes.
#[test]
fn reproduces_captured_tree_frames() {
    check_tree_fixture("tot_stream.sse", "tot-0");
}

#[test]
fn reproduces_captured_bestofn_frames() {
    check_tree_fixture("bestofn_stream.sse", "bon-0");
}

/// Parse one captured meta frame back into the neutral `Event` it represents.
///
/// `None` for frames that belong to the linear path and are covered by the chat
/// golden test. Panicking on anything unrecognized is deliberate: a new frame
/// kind appearing in a capture means the `Event` vocabulary is incomplete, and
/// silently skipping it would let a port drop it unnoticed.
fn tree_event(kind: &str, v: &Value) -> Option<Event> {
    Some(match kind {
        "tree_start" => Event::TreeStart {
            breadth: v["breadth"].as_u64().unwrap() as u32,
            depth: v["depth"].as_u64().unwrap() as u32,
            beam_width: v["beam_width"].as_u64().unwrap() as u32,
        },
        "node_start" => Event::NodeStart {
            id: v["id"].as_str().unwrap().into(),
            parent_id: v["parent_id"].as_str().unwrap().into(),
            depth: v["depth"].as_u64().unwrap() as u32,
            branch_index: v["branch_index"].as_u64().unwrap() as u32,
        },
        "node_delta" => Event::NodeDelta {
            id: v["id"].as_str().unwrap().into(),
            channel: match v["kind"].as_str().unwrap() {
                "reasoning" => Channel::Reasoning,
                "answer" => Channel::Answer,
                o => panic!("unknown node_delta kind {o}"),
            },
            text: v["text"].as_str().unwrap().into(),
        },
        "node_scoring" => Event::NodeScoring { id: v["id"].as_str().unwrap().into() },
        "node_complete" => {
            let n = &v["node"];
            Event::NodeComplete {
                node: NodeView {
                    id: n["id"].as_str().unwrap().into(),
                    parent_id: n["parent_id"].as_str().map(Into::into),
                    depth: n["depth"].as_u64().unwrap() as u32,
                    branch_index: n["branch_index"].as_u64().map(|x| x as u32),
                    content: n["content"].as_str().unwrap().into(),
                    reasoning: n.get("reasoning").and_then(Value::as_str).unwrap_or("").into(),
                    score: n["score"].as_u64().map(|x| x as u8),
                    status: n["status"].as_str().unwrap().into(),
                    error: n.get("error").and_then(Value::as_str).map(Into::into),
                    score_error: n.get("score_error").and_then(Value::as_str).map(Into::into),
                },
            }
        }
        "level_pruned" => Event::LevelPruned {
            level: v["level"].as_u64().unwrap() as u32,
            kept: v["kept"]
                .as_array()
                .unwrap()
                .iter()
                .map(|x| x.as_str().unwrap().to_string())
                .collect(),
        },
        "final_delta" => Event::FinalDelta { text: v["text"].as_str().unwrap().into() },
        "generation_metrics" => Event::GenerationMetrics {
            output_tokens: v["output_tokens"].as_u64().unwrap() as u32,
            elapsed_s: v["elapsed_s"].as_f64().unwrap(),
            tokens_per_sec: v["tokens_per_sec"].as_f64().unwrap(),
        },
        "tree_complete" => Event::TreeComplete {
            selected_node_id: v.get("selected_node_id").and_then(Value::as_str).map(Into::into),
            final_answer: v.get("final_answer").and_then(Value::as_str).map(Into::into),
            synthesized: v["synthesized"].as_bool().unwrap(),
        },
        "awaiting_selection" => Event::AwaitingSelection {
            level: v["level"].as_u64().unwrap() as u32,
            candidates: v["candidates"]
                .as_array()
                .unwrap()
                .iter()
                .map(|c| Pick {
                    id: c["id"].as_str().unwrap().into(),
                    branch_index: c["branch_index"].as_u64().unwrap() as u32,
                    snapshot_name: c["snapshot_name"].as_str().unwrap().into(),
                })
                .collect(),
        },
        // Linear-path frames; the chat golden test owns these.
        "usage" | "model_ready" => return None,
        other => panic!("unhandled frame `{other}` — the Event vocabulary is incomplete"),
    })
}

fn check_tree_fixture(name: &str, tree_id: &str) {
    let raw = fixture(name);
    let payloads = payloads(&raw);
    let mut checked = std::collections::BTreeSet::new();

    for p in &payloads {
        let Some(kind) = meta_kind(p) else { continue };
        let v: Value = serde_json::from_str(p).unwrap();
        let model = v.get("model").and_then(Value::as_str).unwrap_or("qwen");
        let Some(ev) = tree_event(&kind, &v) else { continue };

        let mut r = OpenAiSse::new(tree_id, model, 0).with_tree_metrics(true);
        let out = r.render(&ev);
        assert_eq!(out.len(), 1, "{kind} should render exactly one frame");
        assert_eq!(out[0], *p, "{kind} frame differs\n got: {}\n exp: {p}", out[0]);
        checked.insert(kind);
    }

    assert!(!checked.is_empty(), "{name} produced no tree frames");
    println!("{name}: verified {} distinct frame kinds: {checked:?}", checked.len());
}

// ---------------------------------------------------------------------------
// Whole-stream acceptance
// ---------------------------------------------------------------------------

/// The per-frame test above is NOT acceptance: it renders each frame with a
/// fresh renderer and never checks order, count, or the `[DONE]` sentinel. A
/// port could emit these frames in any sequence, drop `generation_metrics`
/// entirely, and omit `[DONE]`, and it would still pass.
///
/// This is the real B2 target — the whole captured stream, in order, through
/// ONE renderer, byte for byte. Note what it pins beyond bytes:
///
/// * **No `Ready`, no finish chunk, no `usage`.** A tree stream contains zero
///   `chat.completion.chunk` objects. `terminal()` unconditionally emits a
///   finish chunk, so the tree driver must never call it.
/// * **`generation_metrics` is mid-stream**, before `tree_complete`.
/// * **Interleaving is load-bearing.** Both `node_start`s precede every delta
///   and the two nodes' deltas alternate — evidence the branches ran
///   concurrently. A sequential port produces a stream that decodes the same
///   and compares differently.
/// * **`node_complete` is batched.** Both arrive together, in branch_index
///   order, immediately before `level_pruned` — not when each branch finishes.
#[test]
fn reproduces_captured_tree_stream_byte_for_byte() {
    check_tree_stream("tot_stream.sse", "tot-0");
}

#[test]
fn reproduces_captured_bestofn_stream_byte_for_byte() {
    check_tree_stream("bestofn_stream.sse", "bon-0");
}

fn check_tree_stream(name: &str, tree_id: &str) {
    let raw = fixture(name);
    let expected = payloads(&raw);
    assert!(!expected.is_empty(), "fixture had no data frames");
    assert_eq!(expected.last().map(String::as_str), Some("[DONE]"), "{name} must end with [DONE]");

    let model = expected
        .iter()
        .find_map(|p| {
            let v: Value = serde_json::from_str(p).ok()?;
            v.get("model")?.as_str().map(str::to_string)
        })
        .expect("no frame carried a model id");

    let events: Vec<Event> = expected
        .iter()
        .filter(|p| p.as_str() != "[DONE]")
        .filter_map(|p| {
            let kind = meta_kind(p)?;
            let v: Value = serde_json::from_str(p).unwrap();
            tree_event(&kind, &v)
        })
        .collect();

    let mut r = OpenAiSse::new(tree_id, &model, 0).with_tree_metrics(true);
    let mut got: Vec<String> = events.iter().flat_map(|e| r.render(e)).collect();
    // The guest's terminal event ends the stream; the gateway appends only the
    // sentinel. `terminal()` is deliberately NOT called — it would prepend an
    // OpenAI finish chunk that no tree capture contains.
    got.push("[DONE]".into());

    assert_eq!(
        got.len(),
        expected.len(),
        "{name}: frame count differs (got {}, want {})",
        got.len(),
        expected.len()
    );
    for (i, (g, e)) in got.iter().zip(expected.iter()).enumerate() {
        assert_eq!(g, e, "{name}: frame {i} differs\n got: {g}\n exp: {e}");
    }
}

/// `generation_metrics` must vanish in chat mode and appear in tree mode. The
/// default is chat, so a tree driver that forgets `with_tree_metrics` silently
/// drops the frame rather than failing.
#[test]
fn generation_metrics_renders_only_in_tree_mode() {
    let ev = Event::GenerationMetrics {
        output_tokens: 283,
        elapsed_s: 14.017725042,
        tokens_per_sec: 0.0, // deliberately wrong: the renderer recomputes
    };
    assert!(
        OpenAiSse::new("tot-0", "qwen", 0).render(&ev).is_empty(),
        "chat mode must defer metrics to terminal()"
    );
    let out = OpenAiSse::new("tot-0", "qwen", 0).with_tree_metrics(true).render(&ev);
    assert_eq!(
        out,
        vec![
            r#"{"event":"generation_metrics","output_tokens":283,"elapsed_s":14.017725042,"tokens_per_sec":20.188725285456343}"#
                .to_string()
        ],
        "tree mode must emit the frame and recompute tokens_per_sec"
    );
}
