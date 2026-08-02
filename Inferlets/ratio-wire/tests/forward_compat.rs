//! Forward-compatibility contract (doc/chat-refactor.md §5.2, §5.3, §12 L3/L4).
//!
//! These guard the rules that silently regress if someone later "simplifies"
//! the envelope decode into a plain derived enum.

use ratio_wire::envelope::{Envelope, ProtocolError, SeqChecker};
use ratio_wire::event::Event;

// --- §5.3 rule 5: unknown optional event tags are ignored -------------------

#[test]
fn unknown_tag_decodes_as_ignorable_not_error() {
    let raw = r#"{"v":1,"seq":0,"e":{"t":"some_future_event","payload":42}}"#;
    let env = SeqChecker::default()
        .accept(raw)
        .expect("an unknown tag must not fail the ENVELOPE decode");
    assert_eq!(env.tag(), Some("some_future_event"));
    assert_eq!(
        env.decode_event().expect("well-formed, just unknown"),
        None,
        "unknown tags must yield None (ignore), never an error"
    );
}

/// A derived internally-tagged enum errors on an unknown tag. If someone
/// replaces `decode_event`'s tolerant path with `serde_json::from_value`
/// directly, this fails.
#[test]
fn plain_derive_would_reject_unknown_tag() {
    let v = serde_json::json!({"t":"some_future_event"});
    assert!(
        serde_json::from_value::<Event>(v).is_err(),
        "if this passes, serde gained tolerance and decode_event can be simplified"
    );
}

#[test]
fn unknown_optional_field_is_ignored() {
    let v = serde_json::json!({"t":"content_delta","text":"hi","field_from_the_future":true});
    let ev: Event = serde_json::from_value(v).expect("additive fields must not break decode");
    assert_eq!(ev, Event::ContentDelta { text: "hi".into() });
}

// --- §5.3 rule 6: an unsupported major version fails CLOSED ----------------

#[test]
fn future_version_fails_closed() {
    assert_eq!(
        SeqChecker::default().accept(r#"{"v":2,"seq":0,"e":{"t":"ready"}}"#),
        Err(ProtocolError::UnsupportedVersion(2)),
        "graceful degradation applies to tags, not versions"
    );
}

// --- §2.4 / §5.3 rule 4: seq gaps are protocol failures --------------------

#[test]
fn sequence_gap_is_detected() {
    let mut c = SeqChecker::default();
    c.accept(r#"{"v":1,"seq":0,"e":{"t":"ready"}}"#).unwrap();
    // `session::send` swallows delivery failures, so the gap is the ONLY
    // evidence that an event was lost.
    assert_eq!(
        c.accept(r#"{"v":1,"seq":2,"e":{"t":"content_delta","text":"x"}}"#),
        Err(ProtocolError::SequenceGap { expected: 1, got: 2 })
    );
}

#[test]
fn in_order_sequence_accepted() {
    let mut c = SeqChecker::default();
    for i in 0..64 {
        let line = Envelope::new(i, &Event::ContentDelta { text: i.to_string() }).to_line();
        assert!(c.accept(&line).is_ok(), "seq {i} rejected");
    }
}

#[test]
fn malformed_payload_is_an_error() {
    assert!(matches!(
        SeqChecker::default().accept("not json at all"),
        Err(ProtocolError::Malformed(_))
    ));
}

// --- round-trip ------------------------------------------------------------

#[test]
fn every_event_round_trips_through_the_envelope() {
    use ratio_wire::event::{Channel, FinishReason, NodeView, Pick};
    let cases = vec![
        Event::Ready,
        Event::Warning { code: "feature_unavailable".into(), message: "m".into() },
        Event::Error { code: "server_busy".into(), message: "m".into(), param: None },
        Event::Usage { prompt_tokens: 1, completion_tokens: 2, context_window: Some(3) },
        Event::GenerationMetrics { output_tokens: 4, elapsed_s: 1.5, tokens_per_sec: 2.5 },
        Event::Finish { reason: FinishReason::Stop },
        Event::ContentDelta { text: "a".into() },
        Event::ReasoningDelta { text: "b".into() },
        Event::TreeStart { breadth: 2, depth: 1, beam_width: 1 },
        Event::NodeStart {
            id: "n1".into(),
            parent_id: "root".into(),
            depth: 1,
            branch_index: 0,
        },
        Event::NodeDelta { id: "n1".into(), channel: Channel::Answer, text: "t".into() },
        Event::NodeScoring { id: "n1".into() },
        Event::NodeComplete {
            node: NodeView {
                id: "n1".into(),
                parent_id: Some("root".into()),
                depth: 1,
                branch_index: Some(0),
                content: "c".into(),
                reasoning: String::new(),
                score: Some(7),
                status: "ok".into(),
                error: None,
                score_error: None,
            },
        },
        Event::LevelPruned { level: 1, kept: vec!["n1".into()] },
        Event::FinalDelta { text: "f".into() },
        Event::TreeComplete {
            selected_node_id: Some("n1".into()),
            final_answer: Some("a".into()),
            synthesized: true,
        },
        Event::AwaitingSelection {
            level: 1,
            candidates: vec![Pick {
                id: "n1".into(),
                branch_index: 0,
                snapshot_name: "bon/x/1/0".into(),
            }],
        },
    ];

    let mut c = SeqChecker::default();
    for (i, ev) in cases.iter().enumerate() {
        let line = Envelope::new(i as u32, ev).to_line();
        let env = c.accept(&line).unwrap_or_else(|e| panic!("{ev:?} rejected: {e}"));
        let back = env
            .decode_event()
            .unwrap_or_else(|e| panic!("{ev:?} decode failed: {e}"))
            .unwrap_or_else(|| panic!("{ev:?} decoded as unknown — tag mismatch"));
        assert_eq!(&back, ev, "round-trip changed the event");
    }
}
