import SwiftUI

/// The 1H / 24H / 7D / 30D control. Lives in the header of each history chart, so it's on
/// screen exactly when the chart it controls is. All pickers share one setting and stay in sync.
struct HistoryRangePicker: View {
    @AppStorage(SettingsKeys.historyRange) private var rangeRaw = HistoryRange.hour.rawValue

    var body: some View {
        Picker("History range", selection: $rangeRaw) {
            ForEach(HistoryRange.allCases) { range in
                Text(range.label).tag(range.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .pointerStyle(.link)
        .help("How far back the chart goes")
    }
}
