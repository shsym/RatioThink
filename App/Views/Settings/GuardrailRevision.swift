import SwiftUI

/// Cross-tab signal that the memory-guardrail dial (*Settings → Models*)
/// wrote a new RAM fraction. The dial bumps `revision` after a successful
/// `GuardrailSettings.saveFraction`; the `ProfileEditor` (in the sibling
/// *Profiles* tab) keys its model-options refresh on `revision` so the
/// picker's over-limit "exceeds …" badges recompute against the
/// just-saved ceiling.
///
/// Without it the badges go stale: `ProfileEditor.refreshModelOptions`
/// runs in a `.task` that only fires on appear, so a dial change in
/// another tab never reaches it and the picker can disagree with the
/// launch-time guardrail until the view reappears (#334). The fraction
/// itself stays file-backed (`guardrail.json`, the App↔Helper source of
/// truth); this object only carries the in-process "re-read it" tick.
@MainActor
final class GuardrailRevision: ObservableObject {
  @Published private(set) var revision: Int = 0

  func bump() { revision += 1 }
}
