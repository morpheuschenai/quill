import SwiftUI

/// 原生 SwiftUI 的點陣思考球，靈感來自 Thinking Orbs 的「working」狀態。
/// 不嵌入網頁或 JavaScript，並尊重 macOS 的「減少動態效果」設定。
struct ThinkingOrb: View {
  var size: CGFloat = 20
  var speed: Double = 1

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 45, paused: reduceMotion)) { context in
      Canvas { graphics, canvasSize in
        let side = min(canvasSize.width, canvasSize.height)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let radius = side * 0.41
        let time = reduceMotion ? 0.6 : context.date.timeIntervalSinceReferenceDate * speed
        let ringCount = side < 18 ? 4 : 7
        let dotCount = side < 18 ? 10 : 16

        for ring in 0..<ringCount {
          drawOrbit(
            ring: ring,
            dotCount: dotCount,
            time: time,
            center: center,
            radius: radius,
            side: side,
            graphics: &graphics
          )
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private func drawOrbit(
    ring: Int,
    dotCount: Int,
    time: TimeInterval,
    center: CGPoint,
    radius: CGFloat,
    side: CGFloat,
    graphics: inout GraphicsContext
  ) {
    let ringSeed = Double(ring + 1)
    let orbitRadius = radius * CGFloat(0.52 + seeded(ringSeed, 2.7) * 0.48)
    let squash = CGFloat(0.28 + seeded(ringSeed, 6.1) * 0.42)
    let rotation = seeded(ringSeed, 9.3) * .pi
    let direction = ring.isMultiple(of: 2) ? 1.0 : -1.0
    let phase = seeded(ringSeed, 4.4) * .pi * 2
    let baseDot = max(0.55, side * 0.026)

    for index in 0..<dotCount {
      let angle = Double(index) / Double(dotCount) * .pi * 2
      let point = projectedPoint(
        angle: angle,
        orbitRadius: orbitRadius,
        squash: squash,
        rotation: rotation,
        center: center
      )
      let depth = (sin(angle) + 1) / 2
      let alpha = 0.08 + depth * 0.22
      drawDot(
        at: point,
        radius: baseDot * CGFloat(0.75 + depth * 0.45),
        alpha: alpha,
        graphics: &graphics
      )
    }

    for particle in 0..<2 {
      let angle = time * (0.72 + seeded(ringSeed, 7.8) * 0.7) * direction
        + phase + Double(particle) * .pi
      let point = projectedPoint(
        angle: angle,
        orbitRadius: orbitRadius,
        squash: squash,
        rotation: rotation,
        center: center
      )
      let depth = (sin(angle) + 1) / 2
      drawDot(
        at: point,
        radius: baseDot * CGFloat(1.1 + depth * 0.85),
        alpha: 0.48 + depth * 0.48,
        graphics: &graphics
      )
    }
  }

  private func projectedPoint(
    angle: Double,
    orbitRadius: CGFloat,
    squash: CGFloat,
    rotation: Double,
    center: CGPoint
  ) -> CGPoint {
    let rawX = cos(angle) * Double(orbitRadius)
    let rawY = sin(angle) * Double(orbitRadius * squash)
    let rotatedX = rawX * cos(rotation) - rawY * sin(rotation)
    let rotatedY = rawX * sin(rotation) + rawY * cos(rotation)
    return CGPoint(x: center.x + rotatedX, y: center.y + rotatedY)
  }

  private func drawDot(
    at point: CGPoint,
    radius: CGFloat,
    alpha: Double,
    graphics: inout GraphicsContext
  ) {
    let ink = colorScheme == .dark ? Color.white : Color.black
    let rect = CGRect(
      x: point.x - radius,
      y: point.y - radius,
      width: radius * 2,
      height: radius * 2
    )
    graphics.fill(Path(ellipseIn: rect), with: .color(ink.opacity(alpha)))
  }

  private func seeded(_ value: Double, _ salt: Double) -> Double {
    let raw = sin(value * 12.9898 + salt * 78.233) * 43_758.5453
    return raw - floor(raw)
  }
}
