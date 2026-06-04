// Visual-verification harness for the #424 branded menu-bar icon.
//
// Compiles the REAL `Helper/MenuBarBrandIcon.swift` (no separate preview
// implementation, so there is no drift) and renders the four engine
// states on light + dark menu-bar backgrounds, at both a large preview
// size and the actual ~18 pt menu-bar size, into one PNG grid for
// eyeballing. The live `NSStatusItem` image is not XCUITest-assertable
// (sandboxed runner), so this harness + the pure `HelperStatusItemModel.Dot`
// contract are the authoritative coverage.
//
// Run:
//   swiftc -parse-as-library Helper/MenuBarBrandIcon.swift \
//     Scripts/render-menubar-icon.swift -o /tmp/render-menubar-icon \
//     && /tmp/render-menubar-icon && open /tmp/menubar-icon-preview.png

import AppKit

// The PRODUCT tint mapping lives in `HelperMain.colorForDot` (private to
// the Helper target). Mirror it here for the preview only — the drawing
// code itself is shared via MenuBarBrandIcon, which is what we verify.
struct StateRender {
  let name: String
  let filled: Bool
  let errorBadge: Bool
  let color: NSColor
}

func drawText(_ s: String, in rect: NSRect, color: NSColor = .black, size: CGFloat = 11) {
  let para = NSMutableParagraphStyle()
  para.alignment = .center
  let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: size),
    .foregroundColor: color,
    .paragraphStyle: para,
  ]
  let str = NSAttributedString(string: s, attributes: attrs)
  let h = str.size().height
  str.draw(in: NSRect(x: rect.minX + 4, y: rect.midY - h / 2, width: rect.width - 8, height: h))
}

@main
struct RenderMenuBarIcon {
  static func main() {
    let states: [StateRender] = [
      .init(name: "stopped", filled: false, errorBadge: false, color: .secondaryLabelColor),
      .init(name: "starting", filled: false, errorBadge: false, color: .labelColor),
      .init(name: "running", filled: true, errorBadge: false, color: .systemGreen),
      .init(name: "error", filled: true, errorBadge: true, color: .systemOrange),
    ]
    let backgrounds: [(name: String, color: NSColor, appearance: NSAppearance.Name)] = [
      ("light", NSColor(white: 0.95, alpha: 1), .aqua),
      ("dark", NSColor(white: 0.13, alpha: 1), .darkAqua),
    ]

    let bigSize: CGFloat = 56     // large preview
    let realSize: CGFloat = 18    // actual menu-bar size
    let tileW: CGFloat = 150
    let tileH: CGFloat = 84
    let headerH: CGFloat = 26
    let labelW: CGFloat = 84

    let cols = backgrounds.count
    let rows = states.count
    let canvasW = labelW + CGFloat(cols) * tileW
    let canvasH = headerH + CGFloat(rows) * tileH

    let canvas = NSImage(size: NSSize(width: canvasW, height: canvasH))
    canvas.lockFocus()

    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: canvasW, height: canvasH).fill()

    // Column headers (background names).
    for (ci, bg) in backgrounds.enumerated() {
      let x = labelW + CGFloat(ci) * tileW
      drawText(bg.name, in: NSRect(x: x, y: canvasH - headerH, width: tileW, height: headerH))
    }

    // Rows: top-to-bottom = states[0...]. Canvas origin is bottom-left, so
    // the first state goes at the TOP.
    for (ri, st) in states.enumerated() {
      let y = canvasH - headerH - CGFloat(ri + 1) * tileH
      drawText(st.name, in: NSRect(x: 0, y: y, width: labelW, height: tileH))

      for (ci, bg) in backgrounds.enumerated() {
        let x = labelW + CGFloat(ci) * tileW
        let tile = NSRect(x: x, y: y, width: tileW, height: tileH)

        bg.color.setFill()
        tile.fill()

        guard let appearance = NSAppearance(named: bg.appearance) else { continue }
        appearance.performAsCurrentDrawingAppearance {
          // Big preview, left of the tile.
          let big = MenuBarBrandIcon.image(filled: st.filled, errorBadge: st.errorBadge,
                                           color: st.color, pointSize: bigSize)
          big.draw(in: NSRect(x: x + 18, y: y + (tileH - bigSize) / 2,
                              width: bigSize, height: bigSize))
          // Actual menu-bar size, right of the tile.
          let real = MenuBarBrandIcon.image(filled: st.filled, errorBadge: st.errorBadge,
                                            color: st.color, pointSize: realSize)
          real.draw(in: NSRect(x: x + tileW - 18 - realSize, y: y + (tileH - realSize) / 2,
                               width: realSize, height: realSize))
        }
      }
    }

    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
      FileHandle.standardError.write(Data("failed to encode PNG\n".utf8))
      exit(1)
    }
    let out = "/tmp/menubar-icon-preview.png"
    do {
      try png.write(to: URL(fileURLWithPath: out))
      print("wrote \(out) (\(Int(canvasW))x\(Int(canvasH)))")
    } catch {
      FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
      exit(1)
    }
  }
}
