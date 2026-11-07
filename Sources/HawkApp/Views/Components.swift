//
//  Components.swift
//  Hawk
//
//  Small reusable pieces: the card container, meters, sparklines, gauges and
//  legend rows. They take plain values, never the model.
//

import AppKit
import SwiftUI

struct Card<Accessory: View, Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .font(Typography.cardTitle)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(Palette.secondary)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Palette.cardStroke))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

/// A horizontal level meter, 0...1.
struct MeterBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        // Scaled rather than resized, so an update only redraws and never relayouts the window.
        Capsule().fill(Palette.track)
            .overlay(alignment: .leading) {
                Capsule().fill(color.gradient)
                    .scaleEffect(x: min(max(value, 0), 1), anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(height: height)
    }
}

/// Segments laid end to end, each a fraction of the whole.
struct StackedBar: View {
    struct Segment: Identifiable {
        let id: String
        let fraction: Double
        let color: Color
    }
    let segments: [Segment]
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments) { s in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(s.color)
                        .frame(width: max(0, geo.size.width * s.fraction - 2))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.track))
    }
}

/// A tiny line chart drawn with a path: cheap enough for a dozen per-core tiles.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var maximum: Double = 1

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, maximum > 0 else { return }
            let step = size.width / CGFloat(values.count - 1)
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(max(values[i] / maximum, 0), 1))))
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), lineWidth: 1.2)
        }
    }
}

/// A 270° arc gauge. `value` and `marker` are 0...1 along the arc.
struct ArcGauge<Center: View>: View {
    let value: Double
    var gradient = Palette.heatGradient
    var marker: Double?
    var lineWidth: CGFloat = 10
    @ViewBuilder var center: Center

    private let sweep = 0.75

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: sweep)
                .stroke(Palette.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle().trim(from: 0, to: sweep * min(max(value, 0), 1))
                .stroke(AngularGradient(gradient: gradient, center: .center, startAngle: .zero, endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            if let marker {
                let m = sweep * min(max(marker, 0), 1)
                Circle().trim(from: max(m - 0.004, 0), to: m + 0.004)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth + 6, lineCap: .butt))
            }
        }
        .rotationEffect(.degrees(135))
        .padding(lineWidth / 2 + 3)
        .overlay { center }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Fan blades turning at a speed that tracks the real one (slowed down, so it reads
/// as motion rather than a blur). Core Animation spins the layer in the render
/// server, so a turning fan costs the app nothing per frame. Still when the fan is
/// off or Reduce Motion is on.
struct SpinningFan: NSViewRepresentable {
    let rpm: Double
    var size: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> SpinnerView { SpinnerView(size: size) }

    func updateNSView(_ view: SpinnerView, context: Context) {
        // Quantised so small rpm jitter between samples does not restart the animation.
        let turnsPerSecond = (rpm / 100).rounded() * 100 / 1000 * 0.6
        view.spin(turnsPerSecond: reduceMotion ? 0 : turnsPerSecond)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinnerView, context: Context) -> CGSize? {
        CGSize(width: size * 1.2, height: size * 1.2)
    }
}

/// Hosts the blades in a sublayer, whose anchor stays at its centre (AppKit owns
/// the view's own layer and resets its geometry on layout).
final class SpinnerView: NSView {
    private let blades = CALayer()
    private var turnsPerSecond = 0.0

    init(size: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(.init(paletteColors: [.secondaryLabelColor]))
        blades.contents = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        blades.contentsGravity = .resizeAspect
        layer?.addSublayer(blades)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        blades.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        blades.contentsScale = window?.backingScaleFactor ?? 2
    }

    func spin(turnsPerSecond: Double) {
        guard turnsPerSecond != self.turnsPerSecond else { return }
        self.turnsPerSecond = turnsPerSecond
        blades.removeAnimation(forKey: "spin")
        guard turnsPerSecond > 0 else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1 / turnsPerSecond
        spin.repeatCount = .infinity
        blades.add(spin, forKey: "spin")
    }
}

/// Coloured dot, label, value: the legend under charts and the rows of a card.
struct LegendValue: View {
    let color: Color
    let label: String
    let value: String
    var valueColor: Color = .white

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(Typography.small).foregroundStyle(Palette.secondary)
            Spacer(minLength: 4)
            Text(value).font(Typography.value).foregroundStyle(valueColor)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A big number with a caption under it.
struct BigStat: View {
    let value: String
    let caption: String
    var color: Color = .white
    var font = Typography.large

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(font).foregroundStyle(color)
            Text(caption).font(Typography.caption).foregroundStyle(Palette.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
