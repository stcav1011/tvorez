import CoreGraphics
import CoreText
import ImageIO
import Foundation

let W: CGFloat = 740, H: CGFloat = 124
let out = CommandLine.arguments[1]
let rgb = CGColorSpaceCreateDeviceRGB()
func white(_ a: CGFloat) -> CGColor { CGColor(red: 1, green: 1, blue: 1, alpha: a) }
func red(_ a: CGFloat) -> CGColor { CGColor(red: 1, green: 0.231, blue: 0.184, alpha: a) }
func black(_ a: CGFloat) -> CGColor { CGColor(red: 0, green: 0, blue: 0, alpha: a) }

func render(_ path: String, _ w: CGFloat, _ h: CGFloat, _ scale: CGFloat, _ draw: (CGContext) -> Void) {
  let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0, space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.scaleBy(x: scale, y: scale)
  ctx.setAllowsAntialiasing(true); ctx.setShouldSmoothFonts(false)
  draw(ctx)
  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
}

// Текст в координатах «сверху вниз»: (x, baseline от верхнего края)
func text(_ c: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, font: String, size: CGFloat, color: CGColor, kern: CGFloat = 0, h: CGFloat = H) {
  let f = CTFontCreateWithName(font as CFString, size, nil)
  let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): f, .init(kCTForegroundColorAttributeName as String): color, .init(kCTKernAttributeName as String): kern]
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
  c.textPosition = CGPoint(x: x, y: h - y)
  CTLineDraw(line, c)
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: H - y) }

// детерминированный «шум»
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }

let cx: CGFloat = 620, cy: CGFloat = 62, R: CGFloat = 48

func banner(_ c: CGContext) {
  c.setFillColor(CGColor(red: 0.024, green: 0.024, blue: 0.031, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))

  // рельефные контуры, огибающие радар
  var redPath: CGPath? = nil
  for k in 0..<17 {
    let base = -6 + CGFloat(k) * 8.4
    let a1 = 3 + rnd() * 5, f1 = 0.008 + rnd() * 0.01, p1 = rnd() * 6.28
    let a2 = 1 + rnd() * 2.5, f2 = 0.03 + rnd() * 0.03, p2 = rnd() * 6.28
    let isRed = k == 11
    let path = CGMutablePath()
    var x: CGFloat = 0
    while x <= W {
      var y = base + a1 * sin(x * f1 + p1) + a2 * sin(x * f2 + p2)
      let dx = x - cx
      let side: CGFloat = base < cy ? -1 : 1
      let near = max(0, 1 - abs(base - cy) / 90)
      y += side * (R + 8) * near * exp(-(dx * dx) / (2 * 70 * 70))
      if x == 0 { path.move(to: P(x, y)) } else { path.addLine(to: P(x, y)) }
      x += 2
    }
    if isRed {
      // красная линия проявляется из темноты правее логотипа
      redPath = path
    } else {
      c.addPath(path); c.setStrokeColor(white(0.07 + rnd() * 0.16)); c.setLineWidth(0.8); c.strokePath()
    }
  }

  // затемнение под логотипом, чтобы текст читался
  let fade = CGGradient(colorsSpace: rgb, colors: [black(0.92), black(0.75), black(0)] as CFArray, locations: [0, 0.55, 1])!
  c.drawLinearGradient(fade, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 400, y: 0), options: [])
  let fadeR = CGGradient(colorsSpace: rgb, colors: [black(0), black(0.85)] as CFArray, locations: [0, 1])!
  c.saveGState(); c.addEllipse(in: CGRect(x: cx - R - 4, y: H - cy - R - 4, width: 2 * R + 8, height: 2 * R + 8)); c.clip()
  c.drawRadialGradient(fadeR, startCenter: P(cx, cy), startRadius: 0, endCenter: P(cx, cy), endRadius: R, options: [])
  c.restoreGState()

  if let rp = redPath {
    let mask = CGGradient(colorsSpace: rgb, colors: [red(0), red(0), red(1)] as CFArray, locations: [0, 0.42, 0.62])!
    for (width, alpha) in [(CGFloat(4), CGFloat(0.2)), (CGFloat(1.3), CGFloat(1))] {
      c.saveGState()
      c.addPath(rp); c.setLineWidth(width); c.replacePathWithStrokedPath(); c.clip()
      c.setAlpha(alpha)
      c.drawLinearGradient(mask, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: 0), options: [])
      c.restoreGState()
    }
  }

  // радар
  c.setStrokeColor(white(0.6)); c.setLineWidth(1)
  c.strokeEllipse(in: CGRect(x: cx - R, y: H - cy - R, width: 2 * R, height: 2 * R))
  for d in stride(from: 0, to: 360, by: 5) {
    let a = CGFloat(d) * .pi / 180
    let major = d % 30 == 0
    let r1 = R - (major ? 7 : 3.5)
    c.move(to: P(cx + cos(a) * r1, cy + sin(a) * r1)); c.addLine(to: P(cx + cos(a) * (R - 1), cy + sin(a) * (R - 1)))
    c.setStrokeColor(white(major ? 0.75 : 0.3)); c.setLineWidth(major ? 1 : 0.6); c.strokePath()
  }
  c.setLineDash(phase: 0, lengths: [2, 3])
  c.setStrokeColor(white(0.25)); c.setLineWidth(0.7)
  c.strokeEllipse(in: CGRect(x: cx - 33, y: H - cy - 33, width: 66, height: 66))
  c.setLineDash(phase: 0, lengths: [])
  c.setFillColor(white(0.05)); c.fillEllipse(in: CGRect(x: cx - 18, y: H - cy - 18, width: 36, height: 36))
  c.setStrokeColor(white(0.7)); c.strokeEllipse(in: CGRect(x: cx - 18, y: H - cy - 18, width: 36, height: 36))
  // перекрестие
  c.setStrokeColor(white(0.28)); c.setLineWidth(0.6)
  c.move(to: P(cx - R - 16, cy)); c.addLine(to: P(cx + R + 16, cy))
  c.move(to: P(cx, cy - R - 10)); c.addLine(to: P(cx, cy + R + 10)); c.strokePath()
  // луч
  let beam = CGFloat(-38) * .pi / 180
  c.setStrokeColor(white(0.8)); c.setLineWidth(0.9)
  c.move(to: P(cx, cy)); c.addLine(to: P(cx + cos(beam) * (R + 6), cy + sin(beam) * (R + 6))); c.strokePath()
  // красная дуга и центр
  c.setStrokeColor(red(1)); c.setLineWidth(2.2)
  c.addArc(center: P(cx, cy), radius: R + 3.5, startAngle: 200 * .pi / 180, endAngle: 250 * .pi / 180, clockwise: false); c.strokePath()
  c.setLineWidth(1.2)
  c.move(to: P(cx - 4, cy)); c.addLine(to: P(cx + 4, cy)); c.move(to: P(cx, cy - 4)); c.addLine(to: P(cx, cy + 4)); c.strokePath()
  // метка на кольце
  let m = CGFloat(-140) * .pi / 180
  let mp = CGPoint(x: cx + cos(m) * (R + 7), y: cy + sin(m) * (R + 7))
  c.setFillColor(white(0.9))
  c.move(to: P(mp.x, mp.y)); c.addLine(to: P(mp.x + 5, mp.y - 2)); c.addLine(to: P(mp.x + 2, mp.y + 4)); c.fillPath()
  text(c, "114", mp.x - 18, mp.y + 2, font: "Menlo-Regular", size: 6.5, color: white(0.7))
  // точки
  c.setFillColor(white(0.85))
  for (x, y) in [(cx - 30, cy + 40), (cx + 36, cy - 30), (cx + 58, cy + 22)] as [(CGFloat, CGFloat)] {
    c.fillEllipse(in: CGRect(x: x - 1.2, y: H - y - 1.2, width: 2.4, height: 2.4))
  }

  // телеметрия слева от радара
  text(c, "SRC", 492, 30, font: "Menlo-Regular", size: 6.5, color: white(0.45), kern: 1)
  text(c, "1800+", 492, 48, font: "DINAlternate-Bold", size: 17, color: white(0.92), kern: 0.5)
  text(c, "RES", 492, 70, font: "Menlo-Regular", size: 6.5, color: white(0.45), kern: 1)
  text(c, "2160", 492, 88, font: "DINAlternate-Bold", size: 17, color: white(0.92), kern: 0.5)
  c.setFillColor(white(0.6)); c.fill(CGRect(x: 492, y: H - 96, width: 3, height: 1))
  c.setFillColor(white(0.25)); c.fill(CGRect(x: 497, y: H - 96, width: 34, height: 1))

  // логотип
  c.setFillColor(red(1)); c.fill(CGRect(x: 22, y: H - 25, width: 5, height: 5))
  text(c, "SYS.ONLINE   //   MEDIA INGEST UNIT", 34, 25, font: "Menlo-Regular", size: 7, color: white(0.5), kern: 1)
  text(c, "TVOREZ", 20, 72, font: "DINAlternate-Bold", size: 46, color: white(1), kern: 9)
  text(c, "ЗАГРУЗКА ВИДЕО И ЗВУКА ПРЯМО В MEDIA POOL", 23, 93, font: "Menlo-Regular", size: 7.5, color: white(0.55), kern: 1.2)
  // тег версии
  c.setStrokeColor(red(1)); c.setLineWidth(1)
  c.stroke(CGRect(x: 262.5, y: H - 71.5, width: 34, height: 14))
  text(c, "V2.1", 268, 67, font: "Menlo-Bold", size: 8, color: red(1), kern: 1)

  // линейка снизу
  var x: CGFloat = 22
  var i = 0
  while x <= W - 22 {
    let major = i % 10 == 0
    c.setFillColor(white(major ? 0.35 : 0.14))
    c.fill(CGRect(x: x, y: 4, width: 0.8, height: major ? 6 : 3))
    x += 6; i += 1
  }
  c.setFillColor(white(0.14)); c.fill(CGRect(x: 22, y: 4, width: W - 44, height: 0.8))
  c.setFillColor(red(1)); c.fill(CGRect(x: 22, y: 4, width: 60, height: 1.2))
}

render(out + "/banner.png", W, H, 1, banner)
render(out + "/banner@2x.png", W, H, 2, banner)

// стрелка выпадающего списка и галочка
render(out + "/arrow.png", 10, 6, 2) { c in
  c.setStrokeColor(white(0.7)); c.setLineWidth(1.2); c.setLineCap(.square)
  c.move(to: CGPoint(x: 1, y: 5)); c.addLine(to: CGPoint(x: 5, y: 1.2)); c.addLine(to: CGPoint(x: 9, y: 5)); c.strokePath()
}
render(out + "/check.png", 11, 11, 2) { c in
  c.setFillColor(black(1)); c.fill(CGRect(x: 3.5, y: 3.5, width: 4, height: 4))
}
