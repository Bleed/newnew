// Renders the app icon: swift Scripts/render-app-icon.swift <output.png>
// Then copy it to Newnew/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png.

import AppKit

// As Atelier's icon, reversed: dotted letters on a dot matrix, straight on black, no border, no
// shadow. "new" over "new", in the lower-case 5×7 face the app uses (rows 2–6 of each glyph),
// on a square grid of faint dots; the letters are almost white.
//
// iOS gets full-bleed square artwork, masked by the system; the grid keeps a margin so no dot
// is cut by the rounded corners.
let glyphs: [Character: [String]] = [
  "n": ["10110", "11001", "10001", "10001", "10001"],
  "e": ["01110", "10001", "11111", "10000", "01110"],
  "w": ["10001", "10001", "10101", "10101", "01010"],
]
let lines = ["new", "new"]

/// Lit cells: each line is its glyphs with one blank column between, the lines one blank row
/// apart, centred on an n × n grid.
func litCells(gridSize n: Int) -> Set<[Int]> {
  let width = lines.map { $0.count * 6 - 1 }.max()!
  let height = lines.count * 6 - 1
  let left = (n - width) / 2, top = (n - height) / 2
  var cells = Set<[Int]>()
  for (lineIndex, line) in lines.enumerated() {
    for (glyphIndex, character) in line.enumerated() {
      for (row, bits) in glyphs[character]!.enumerated() {
        for (column, bit) in bits.enumerated() where bit == "1" {
          cells.insert([top + lineIndex * 6 + row, left + glyphIndex * 6 + column])
        }
      }
    }
  }
  return cells
}

func render(size: CGFloat, to path: String) {
  let px = Int(size)
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  let ctx = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.current = ctx
  let cg = ctx.cgContext
  let tile = CGRect(x: 0, y: 0, width: size, height: size)
  cg.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
  cg.fill(tile)
  // The dots keep clear of the mask's rounded corners.
  let field = tile.insetBy(dx: size * 0.09, dy: size * 0.09)

  // 17 columns of letters ("new") and 11 rows (two lines), on a 19 × 19 grid.
  let n = 19
  let lit = litCells(gridSize: n)
  let pitch = field.width / CGFloat(n)
  let dot = pitch * 0.82
  // The app's dark-mode ink (0xF5F5F5) and its unlit dots (ink at 14 %, a touch more than on
  // white so they still read on black).
  let ink = CGColor(red: 0.961, green: 0.961, blue: 0.961, alpha: 1)
  let faint = CGColor(red: 1, green: 1, blue: 1, alpha: 0.14)
  for row in 0..<n {
    for column in 0..<n {
      cg.setFillColor(lit.contains([row, column]) ? ink : faint)
      let x = field.minX + (CGFloat(column) + 0.5) * pitch - dot / 2
      let y = field.maxY - (CGFloat(row) + 0.5) * pitch - dot / 2
      cg.fillEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
    }
  }
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(size: 1024, to: CommandLine.arguments[1])
