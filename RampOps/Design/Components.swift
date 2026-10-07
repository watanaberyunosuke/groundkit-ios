import SwiftUI

// Built for the apron: large type, big tap targets for gloved hands, and status shown by
// symbol and words as well as colour (sunlight glare, colour blindness).

extension Rag {
    var color: Color {
        switch self {
        case .green: .green
        case .amber: .orange
        case .red: .red
        case .unknown: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .green: "checkmark.circle.fill"
        case .amber: "clock.badge.exclamationmark.fill"
        case .red: "exclamationmark.octagon.fill"
        case .unknown: "circle.dashed"
        }
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .info: .blue
        case .normal: .green
        case .caution: .orange
        case .warning: .red
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .normal: "checkmark.seal.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .warning: "xmark.octagon.fill"
        }
    }
}

/// A rounded panel on the grouped background.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: systemImage ?? "")
                    .labelStyle(TitleOnlyIfEmptyIcon(hasIcon: systemImage != nil))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

private struct TitleOnlyIfEmptyIcon: LabelStyle {
    var hasIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        if hasIcon { Label(configuration) } else { configuration.title }
    }
}

/// One reading, large: "Wind", "270° 15 kt".
struct Tile: View {
    var title: String
    var value: String
    var detail: String?
    var systemImage: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// Delay status as a capsule with a symbol, so it reads without colour.
struct StatusPill: View {
    var rag: Rag
    var text: String

    var body: some View {
        Label(text, systemImage: rag.symbol)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(rag == .unknown ? Color.primary : .white)
            .background(rag == .unknown ? Color.secondary.opacity(0.2) : rag.color, in: .capsule)
    }
}

/// Tags a flight the API marks as a freighter (is_freighter). Passenger flights carry belly
/// cargo too, so boards tag freighters rather than filter to them.
struct FreighterTag: View {
    var body: some View {
        Text("Freighter")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary))
            .accessibilityLabel("Freighter")
    }
}

/// Flight number large, with the ICAO callsign under it when they differ.
struct FlightCode: View {
    var iata: String?
    var callsign: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(iata ?? callsign)
                .font(.title3.weight(.bold).monospacedDigit())
            if iata != nil {
                Text(callsign).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A full-width button with a 60 pt minimum height, for gloves.
struct BigButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(.horizontal, 12)
            .foregroundStyle(filled ? Color.white : tint)
            .background(filled ? tint : tint.opacity(0.15), in: .rect(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Local and UTC clocks, ticking each minute.
struct Clocks: View {
    var iata: String
    var timeZone: TimeZone

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(LocalTime.hhmm(context.date, timeZone))
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    Text("\(iata) local").font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(LocalTime.hhmm(context.date, .gmt) + "Z")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("UTC").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(iata) local time \(LocalTime.hhmm(context.date, timeZone)), UTC \(LocalTime.hhmm(context.date, .gmt))")
        }
    }
}

/// "Updated 3 min ago" and any load error, under each screen.
struct FreshnessFooter: View {
    @Environment(AirportStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let live = store.live {
                Text("Live positions: \(live.source), \(live.at, format: .relative(presentation: .named))")
            }
            if store.snapshotIsCached {
                Label("Offline: showing saved data", systemImage: "wifi.slash").foregroundStyle(.orange)
            }
            if let error = store.liveError {
                Label("Live positions unavailable: \(error)", systemImage: "antenna.radiowaves.left.and.right.slash")
            }
            if let error = store.snapshotError {
                Label("Airport data unavailable: \(error)", systemImage: "exclamationmark.icloud")
            }
            Text("Advisory only. Follow your airport and airline procedures.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The airport switcher shown in every tab's toolbar.
struct AirportMenu: View {
    @Environment(AirportStore.self) private var store

    var body: some View {
        Menu {
            Picker("Airport", selection: Binding(get: { store.icao }, set: { store.select($0) })) {
                ForEach(store.airports.sorted { $0.iata < $1.iata }) { a in
                    Text("\(a.iata)  \(a.name)").tag(a.icao)
                }
            }
        } label: {
            Label(store.airport.iata, systemImage: "airplane.circle")
                .labelStyle(.titleAndIcon)
                .font(.headline)
        }
        .accessibilityLabel("Airport \(store.airport.name). Change airport")
    }
}

extension View {
    /// Standard toolbar: airport switcher and a refresh spinner.
    func rampToolbar() -> some View {
        modifier(RampToolbar())
    }
}

private struct RampToolbar: ViewModifier {
    @Environment(AirportStore.self) private var store

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarLeading) { AirportMenu() }
            ToolbarItem(placement: .topBarTrailing) {
                if store.isRefreshing { ProgressView() }
            }
        }
    }
}

extension Date {
    /// "14:05" in the airport's time zone, with "~" when approximate.
    func hhmm(_ timeZone: TimeZone, approx: Bool = false) -> String {
        (approx ? "~" : "") + LocalTime.hhmm(self, timeZone)
    }
}
