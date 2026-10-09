import SwiftData
import SwiftUI

struct TurnaroundDetailView: View {
    @Environment(AirportStore.self) private var store
    @Environment(\.modelContext) private var context
    @Bindable var turnaround: Turnaround
    @State private var lastDone: TurnaroundStep?
    @State private var confirmClose = false
    @State private var confirmDelete = false
    /// Deleted once this screen has gone, so it never draws a deleted model.
    @State private var deleteOnDisappear = false
    @Environment(\.dismiss) private var dismiss
    /// Taps in the first moment after opening are the tail of the tap that opened this
    /// screen (or a double tap with gloves), not a step being done.
    @State private var openedAt = Date.now

    var body: some View {
        let t = turnaround
        let done = t.completed
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(done)
                ForEach(TurnaroundStep.Phase.allCases, id: \.self) { phase in
                    let steps = t.steps.filter { $0.phase == phase }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(phase.rawValue).font(.headline).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(steps) { step in
                                StepButton(step: step, doneAt: done[step], isNext: step == t.nextStep,
                                           timeZone: store.timeZone) { toggle(step, isDone: done[step] != nil) }
                            }
                        }
                    }
                }
                counts
                details
                Button(t.isClosed ? "Reopen turnaround" : "Close turnaround", systemImage: t.isClosed ? "arrow.uturn.left" : "flag.checkered") {
                    if t.isClosed { t.closedAt = nil } else { confirmClose = true }
                }
                .buttonStyle(BigButtonStyle(tint: t.isClosed ? .secondary : .statusOK))
                Button("Delete turnaround", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .padding()
        }
        .navigationTitle(t.label)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: lastDone)
        .onAppear { openedAt = .now }
        .onDisappear { if deleteOnDisappear { context.delete(turnaround) } }
        .confirmationDialog("Close this turnaround?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close turnaround") { t.closedAt = .now }
        } message: {
            if let next = t.nextStep { Text("\(next.title) and later steps are not marked done.") }
        }
        .confirmationDialog("Delete this turnaround?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleteOnDisappear = true
                dismiss()
            }
        } message: {
            Text("Its steps, counts and notes are removed.")
        }
    }

    private func header(_ done: [TurnaroundStep: Date]) -> some View {
        let t = turnaround
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.label).font(.system(size: 40, weight: .heavy, design: .rounded))
                Text([t.origin.map { "From \($0)" }, t.destination.map { "To \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                if let onBlocks = t.onBlocksAt {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text("On blocks \(onBlocks.hhmm(store.timeZone)), \(Int(ctx.date.timeIntervalSince(onBlocks) / 60)) min on stand")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: t.progress).frame(maxWidth: 220)
            }
            Spacer()
            if let off = t.targetOffBlock, t.completed[.chocksOff] == nil {
                OffBlockCountdown(target: off, timeZone: store.timeZone)
            }
        }
    }

    private var counts: some View {
        Card(title: "Counts", systemImage: "number") {
            CountRow(title: "Bags off", value: $turnaround.bagsOffloaded)
            CountRow(title: "Bags loaded", value: $turnaround.bagsLoaded)
            CountRow(title: "ULDs off", value: $turnaround.uldsOffloaded)
            CountRow(title: "ULDs loaded", value: $turnaround.uldsLoaded)
        }
    }

    private var details: some View {
        Card(title: "Details", systemImage: "info.circle") {
            LabeledField(title: "Stand", text: $turnaround.stand)
            LabeledField(title: "Registration", text: $turnaround.registration)
            Toggle("Dangerous goods on board", isOn: $turnaround.hasDangerousGoods)
                .font(.headline)
                .frame(minHeight: 44)
            Text("Notes").font(.subheadline).foregroundStyle(.secondary)
            TextField("Damage, delays, special loads…", text: $turnaround.notes, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func toggle(_ step: TurnaroundStep, isDone: Bool) {
        guard Date.now.timeIntervalSince(openedAt) > 0.8 else { return }
        if isDone {
            for e in turnaround.events ?? [] where e.step == step.rawValue { context.delete(e) }
        } else {
            let event = TurnaroundEvent(step: step)
            event.turnaround = turnaround
            context.insert(event)
            lastDone = step
        }
    }
}

/// One step: tap to mark it done at the current time; tap again to undo, after a confirm.
struct StepButton: View {
    var step: TurnaroundStep
    var doneAt: Date?
    var isNext: Bool
    var timeZone: TimeZone
    var action: () -> Void
    @State private var confirmUndo = false

    var body: some View {
        let done = doneAt != nil
        Button {
            if done { confirmUndo = true } else { action() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : step.symbol)
                    .font(.title2)
                    .foregroundStyle(done ? Color.statusOK : .primary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.headline).multilineTextAlignment(.leading)
                    Text(doneAt.map { $0.hhmm(timeZone) } ?? (isNext ? "Next" : " "))
                        .font(.subheadline.monospacedDigit())
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .foregroundStyle(.primary)
            .background(done ? Color.statusOKContainer : isNext ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                        in: .rect(cornerRadius: 14))
            .overlay {
                if isNext { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step.title)
        .accessibilityValue(doneAt.map { "Done at \($0.hhmm(timeZone))" } ?? "Not done")
        .confirmationDialog("Undo \(step.title)?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Undo", role: .destructive, action: action)
        }
    }
}

struct CountRow: View {
    var title: String
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button { value = max(0, value - 1) } label: { Image(systemName: "minus").frame(width: 52, height: 48) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Decrease \(title)")
            Text("\(value)")
                .font(.title2.weight(.bold).monospacedDigit())
                .frame(minWidth: 52)
            Button { value += 1 } label: { Image(systemName: "plus").frame(width: 52, height: 48) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Increase \(title)")
        }
        .sensoryFeedback(.increase, trigger: value)
        .accessibilityElement(children: .contain)
    }
}

struct LabeledField: View {
    var title: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title).font(.headline)
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
        .frame(minHeight: 44)
    }
}
