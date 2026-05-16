import WidgetKit
import AppIntents

// MARK: - Widget Configuration Intent

struct TalkPulseConfigurationIntent: WidgetConfigurationIntent, CustomStringConvertible {
    static var title: LocalizedStringResource { "Widget Settings" }
    static var description: IntentDescription { "Choose how many feed entries to show. TalkPulse clamps the value to each widget size." }

    @Parameter(title: "Entries to Show", default: 4)
    var entryCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(clampedEntryCount) entries")
    }

    var description: String {
        "Show \(clampedEntryCount) entries"
    }

    private var clampedEntryCount: Int {
        min(max(1, entryCount), 5)
    }
}
