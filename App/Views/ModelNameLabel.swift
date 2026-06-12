import SwiftUI

/// Width-bounding for any at-rest model-name label (#462).
///
/// A model's stored identity is the resolvable `<repo>/<file>` slug; UI
/// renders the friendly leaf (`ModelDisplayName.leaf`). But even the leaf
/// of a real GGUF — `Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf` — is long
/// enough that a `.fixedSize()` label pins it non-compressible and pushes
/// the surrounding toolbar/menu past the window edge, clipping controls.
///
/// This modifier is the single reusable truncation primitive for model
/// labels: it makes the label *compressible* and caps it — one
/// middle-truncated line (keeps the family head + the quant/`.gguf` tail,
/// the two parts that disambiguate one model from another) with a max
/// width — so the enclosing layout shrinks the model label first instead
/// of breaking. Pass `maxWidth: .infinity` to truncate within a slot whose
/// width its parent already fixes (e.g. `ProfileModelPickerLabel`).
///
/// It deliberately does NOT attach a tooltip: keeping the full id
/// inspectable (`.help` / accessibility) is the SURFACE's responsibility,
/// since each surface already owns its own help text (the toolbar menu's
/// `modelMenuHelp`, the picker label's slug help, the popover header).
///
/// The default 240pt cap suits a toolbar/menu label that shares its row;
/// `ProfileModelPickerLabel` instead passes `maxWidth: .infinity` and lets
/// its own outer `.frame(maxWidth: 360)` set the cap for the wider Settings
/// row — keep those two caps in mind when reusing this. Pair with REMOVING
/// any `.fixedSize()` on the enclosing menu — `.fixedSize()` forces the
/// ideal (full) width and defeats the cap — UNLESS an enclosing frame
/// already supplies a definite `idealWidth` (as `ProfileModelPickerLabel`
/// does), in which case `.fixedSize()` is safe because the ideal is already
/// bounded.
extension View {
  func boundedModelName(maxWidth: CGFloat = 240) -> some View {
    self
      .lineLimit(1)
      .truncationMode(.middle)
      .frame(maxWidth: maxWidth, alignment: .leading)
  }
}
