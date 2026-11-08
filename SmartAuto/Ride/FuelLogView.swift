import CoreLocation
import SwiftUI

/// Fill-ups, newest first, with km per litre, baht per km and this month's spend on top.
struct FuelLogView: View {
    @ObservedObject private var log = FuelLog.shared
    @State private var editing: FuelFill?
    @State private var adding = false

    var body: some View {
        let stats = log.stats
        List {
            if log.fills.isEmpty {
                Section {
                    Text("บันทึกทุกครั้งที่เติม ใส่เลขไมล์ตอนเติมเต็มถัง แอปจะคำนวณ กม./ลิตร ให้")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    HStack(spacing: 0) {
                        RideStat(value: stats.overallKmPerLiter.map { String(format: "%.1f", $0) } ?? "–", label: "กม./ลิตร")
                        RideStat(value: stats.bahtPerKm.map { String(format: "%.2f", $0) } ?? "–", label: "บาท/กม.")
                        RideStat(value: RideFormat.baht(log.month().baht), label: "เดือนนี้")
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    ForEach(log.fills) { fill in
                        Button { editing = fill } label: { FuelRow(fill: fill, kmPerLiter: stats.kmPerLiter[fill.id]) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in log.delete(Set(offsets.map { log.fills[$0].id })) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("เติมน้ำมัน")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("บันทึกการเติม")
            }
        }
        .sheet(isPresented: $adding) { FuelEntryView(fill: nil) }
        .sheet(item: $editing) { fill in FuelEntryView(fill: fill) }
    }
}

private struct FuelRow: View {
    let fill: FuelFill
    let kmPerLiter: Double?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fill.station.isEmpty ? "แก๊สโซฮอล์ \(fill.fuel)" : fill.station)
                    .lineLimit(1)
                Text(RideFormat.day(fill.date) + (fill.full ? "" : " · ไม่เต็มถัง"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(RideFormat.baht(fill.total))
                    .font(.body.weight(.semibold).monospacedDigit())
                Text(String(format: "%.2f ลิตร", fill.liters) + (kmPerLiter.map { String(format: " · %.1f กม./ลิตร", $0) } ?? ""))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// One fill-up: litres and baht from the pump, the dash's odometer, full or not. The station fills
/// itself in when we are at one.
struct FuelEntryView: View {
    let fill: FuelFill?
    @ObservedObject private var log = FuelLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var liters = ""
    @State private var total = ""
    @State private var odometer = ""
    @State private var full = true
    @State private var fuel = FuelFill.fuels[0]
    @State private var station = ""
    @State private var date = Date()
    @FocusState private var focused: Field?

    private enum Field { case liters, total, odometer, station }

    init(fill: FuelFill?) {
        self.fill = fill
    }

    private var litersValue: Double? { Self.number(liters) }
    private var totalValue: Double? { Self.number(total) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    numberField("ลิตร", text: $liters, field: .liters)
                    numberField("บาท", text: $total, field: .total)
                } footer: {
                    if let litersValue, let totalValue, litersValue > 0 {
                        Text(String(format: "ลิตรละ %.2f บาท", totalValue / litersValue))
                    }
                }
                Section {
                    Picker("น้ำมัน", selection: $fuel) {
                        ForEach(FuelFill.fuels, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("เติมเต็มถัง", isOn: $full)
                }
                Section {
                    numberField("เลขไมล์ (กม.)", text: $odometer, field: .odometer, decimals: false)
                } footer: {
                    if let last = log.lastOdometer, fill == nil {
                        Text("ครั้งก่อน \(Int(last)) กม. · ใส่ตอนเติมเต็มถังเพื่อคำนวณ กม./ลิตร")
                    } else {
                        Text("ใส่ตอนเติมเต็มถังเพื่อคำนวณ กม./ลิตร")
                    }
                }
                Section {
                    TextField("ปั๊ม", text: $station)
                        .focused($focused, equals: .station)
                    DatePicker("วันที่", selection: $date)
                }
            }
            .navigationTitle(fill == nil ? "บันทึกการเติม" : "แก้ไข")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ยกเลิก") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("บันทึก") { save() }
                        .disabled((litersValue ?? 0) <= 0 || (totalValue ?? 0) <= 0)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func numberField(_ title: String, text: Binding<String>, field: Field, decimals: Bool = true) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: text)
                .keyboardType(decimals ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused, equals: field)
                .frame(maxWidth: 160)
        }
    }

    @MainActor
    private func load() {
        if let fill {
            liters = Self.text(fill.liters)
            total = Self.text(fill.total)
            odometer = fill.odometer.map { String(Int($0)) } ?? ""
            full = fill.full
            fuel = fill.fuel
            station = fill.station
            date = fill.date
            return
        }
        fuel = log.lastFuel
        focused = .liters
        // A recent fix from the app's own location use; no new request needed.
        guard let location = CLLocationManager().location, location.horizontalAccuracy < 200,
              Date().timeIntervalSince(location.timestamp) < 15 * 60 else { return }
        Task { @MainActor in
            if let name = await FuelLog.station(near: location), station.isEmpty { station = name }
        }
    }

    private func save() {
        guard let litersValue, let totalValue else { return }
        var saved = fill ?? FuelFill(liters: litersValue, total: totalValue, fuel: fuel)
        saved.liters = litersValue
        saved.total = totalValue
        saved.odometer = Self.number(odometer)
        saved.full = full
        saved.fuel = fuel
        saved.station = station.trimmingCharacters(in: .whitespaces)
        saved.date = date
        log.save(saved)
        dismiss()
    }

    static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private static func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
