//
//  HistoryChart.swift
//  Hawk
//
//  Line charts over the recent history, drawn with Canvas: one draw call per
//  chart per update. (Swift Charts rebuilt and diffed every mark each second and
//  cost most of the app's CPU.) The x axis is seconds before the latest sample,
//  so the chart always ends at "now" on the right.
//

import SwiftUI

struct ChartPoint {
    let x: Double
    let y: Double
}

struct ChartSeries: Identifiable {
    let name: String
    let color: Color
    let points: [ChartPoint]
    var id: String { name }

    init(_ name: String, _ color: Color, _ samples: [Sample], value: (Sample) -> Double?) {
        self.name = name
        self.color = color
        let now = samples.last?.date ?? .now
        points = samples.compactMap { s in value(s).map { ChartPoint(x: s.date.timeIntervalSince(now), y: $0) } }
    }

    var maximum: Double { points.map(\.y).max() ?? 0 }
    var minimum: Double { points.map(\.y).min() ?? 0 }
}

struct HistoryChart: View {
    let series: [ChartSeries]
    let range: Double
    let yDomain: ClosedRange<Double>
    var fill = false
    var height: CGFloat = 100
    let format: (Double) -> String

    /// Room on the right for the axis labels.
    private static let labelWidth: CGFloat = 46

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 0, y: 4, width: max(size.width - Self.labelWidth, 1), height: max(size.height - 8, 1))
            let span = max(yDomain.upperBound - yDomain.lowerBound, .ulpOfOne)
            func y(_ v: Double) -> CGFloat { plot.maxY - plot.height * CGFloat((min(max(v, yDomain.lowerBound), yDomain.upperBound) - yDomain.lowerBound) / span) }
            func x(_ t: Double) -> CGFloat { plot.minX + plot.width * CGFloat((t + range) / range) }

            for tick in [yDomain.lowerBound, (yDomain.lowerBound + yDomain.upperBound) / 2, yDomain.upperBound] {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(tick)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(tick)))
                context.stroke(line, with: .color(Palette.grid), lineWidth: 0.5)
                context.draw(Text(format(tick)).font(Typography.caption).foregroundStyle(Palette.tertiary),
                             at: CGPoint(x: size.width, y: y(tick)), anchor: .trailing)
            }

            for s in series {
                let visible = s.points.filter { $0.x >= -range }
                guard visible.count > 1 else { continue }
                var line = Path()
                line.move(to: CGPoint(x: x(visible[0].x), y: y(visible[0].y)))
                for p in visible.dropFirst() { line.addLine(to: CGPoint(x: x(p.x), y: y(p.y))) }
                if fill {
                    var area = line
                    area.addLine(to: CGPoint(x: x(visible[visible.count - 1].x), y: plot.maxY))
                    area.addLine(to: CGPoint(x: x(visible[0].x), y: plot.maxY))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(Gradient(colors: [s.color.opacity(0.28), s.color.opacity(0)]),
                                                             startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
                }
                context.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(series.map(\.name).joined(separator: ", ") + " history")
    }

    /// 0...top, where top is a round number above the data and never below `floor`.
    static func domain(_ series: [ChartSeries], floor: Double) -> ClosedRange<Double> {
        0...niceCeiling(max(series.map(\.maximum).max().map { $0 * 1.1 } ?? 0, floor))
    }

    /// The next 1, 2, 2.5 or 5 × 10ⁿ at or above `v`, so the axis labels read cleanly.
    static func niceCeiling(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(v)))
        return [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= v } ?? 10 * magnitude
    }
}
