//
//  OverviewFeature.swift
//  Hawk
//
//  The Overview tab: the fan card across the full width, then a grid of cards
//  that reflows from one to several columns as the window is resized. It needs
//  nothing beyond the Monitor's basic snapshot.
//

import SwiftUI

final class OverviewFeature: Feature {
    let id = "overview"
    let title = "Overview"
    let symbol = "gauge.with.dots.needle.67percent"

    func makeView() -> AnyView { AnyView(OverviewView()) }
}

private struct OverviewView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.contentWidth) private var width

    var body: some View {
        // Nothing until the first sample (a fraction of a second), rather than a spinner
        // that would flash and then jump to the cards.
        if monitor.hasData {
            ScrollView {
                VStack(spacing: Metrics.spacing) {
                    FanCard(wide: width >= 900)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.minCardWidth), spacing: Metrics.spacing, alignment: .top)],
                              spacing: Metrics.spacing) {
                        CPUCard()
                        TemperatureCard()
                        GPUCard()
                        MemoryCard()
                        PowerCard()
                        DiskCard()
                        NetworkCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        } else {
            Color.clear
        }
    }
}
