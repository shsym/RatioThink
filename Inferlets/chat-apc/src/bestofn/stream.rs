//! Best-of-N **streaming** wire format (#690).
//!
//! A round reuses the tree-of-thought streaming frames so the app's existing
//! `ToTStream` decoder + `ToTTree` accumulator + `TreeSearchSection` render it
//! unchanged: `tree_start` opens (the round shape), each candidate streams as
//! `node_start` / `node_delta` (emitted inside
//! [`generate_branch`](crate::tot::branch::generate_branch) via the shared
//! [`BranchSink`](crate::tot::branch::BranchSink) — siblings co-batch and
//! interleave by node id, the #650 multiplex) and is finalized by a
//! `node_complete` (carried by `level_pruned`'s preceding batch). The round
//! ends — deliberately WITHOUT auto-selecting a final answer — with one new
//! `awaiting_selection` terminal listing the pickable candidates (those whose
//! KV was saved), so the **user** is the judge.
//!
//! ```text
//! tree_start         {event,id,model,breadth,depth,beam_width}   // once, opens (tot::stream)
//! node_start         {event,id,parent_id,depth,branch_index}     // per candidate (tot::stream)
//! node_delta         {event,id,kind,text}                        // streamed chunks (tot::stream)
//! node_complete      {event,node:{…}}                            // per candidate, terminal (tot::stream)
//! level_pruned       {event,level,kept:[…]}                      // all pickable kept (tot::stream)
//! awaiting_selection {event,level,candidates:[{id,branch_index,snapshot_name}]}  // terminal: no auto-pick
//! error              {event:"error",code,message}                // terminal failure
//! [DONE]
//! ```
//!
//! Only the `awaiting_selection` terminal is Best-of-N-specific; everything
//! else is the verbatim tree-of-thought wire.

use serde::Serialize;

use crate::sse::{EmitError, Emitter};

/// One pickable candidate handed to the client in the terminal frame: its
/// node id, pane order, and the snapshot name to post back when the user picks
/// it for a think-more round.
#[derive(Debug, Clone, Serialize)]
pub struct Pick {
    pub id: String,
    pub branch_index: usize,
    pub snapshot_name: String,
}

#[derive(Serialize)]
struct AwaitingSelectionFrame<'a> {
    event: &'static str,
    level: usize,
    candidates: &'a [Pick],
}

/// Emit the terminal `awaiting_selection` frame: the round generated these
/// pickable candidates and is now waiting for the user to choose one (and
/// think-more vs stop). Deliberately not a success/answer frame — there is no
/// auto-selected final answer in Best-of-N.
pub async fn emit_awaiting_selection(
    em: &mut Emitter,
    level: usize,
    candidates: &[Pick],
) -> Result<(), EmitError> {
    em.emit_json(&AwaitingSelectionFrame {
        event: "awaiting_selection",
        level,
        candidates,
    })
    .await
}

/// Terminal failure `code`/`message` for a round in which no candidate
/// produced a usable, saveable answer (every branch failed). Shared so the
/// streamed `error` frame carries stable text.
pub const NO_CANDIDATES_CODE: &str = "no_candidates";
pub const NO_CANDIDATES_MESSAGE: &str =
    "best-of-n produced no usable candidate: every branch failed to generate or persist";

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn awaiting_selection_lists_pickable_candidates() {
        let picks = vec![
            Pick { id: "bon-n1".to_string(), branch_index: 0, snapshot_name: "bon/r/1/0".to_string() },
            Pick { id: "bon-n2".to_string(), branch_index: 1, snapshot_name: "bon/r/1/1".to_string() },
        ];
        let v = serde_json::to_value(AwaitingSelectionFrame {
            event: "awaiting_selection",
            level: 1,
            candidates: &picks,
        })
        .unwrap();
        assert_eq!(v["event"], "awaiting_selection");
        assert_eq!(v["level"], 1);
        assert_eq!(v["candidates"][0]["id"], "bon-n1");
        assert_eq!(v["candidates"][0]["branch_index"], 0);
        assert_eq!(v["candidates"][1]["snapshot_name"], "bon/r/1/1");
        assert_eq!(v["candidates"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn awaiting_selection_empty_is_empty_array() {
        let v = serde_json::to_value(AwaitingSelectionFrame {
            event: "awaiting_selection",
            level: 1,
            candidates: &[],
        })
        .unwrap();
        assert_eq!(v["candidates"], json!([]));
    }
}
