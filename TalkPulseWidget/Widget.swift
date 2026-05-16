import WidgetKit
import SwiftUI

private let widgetDividerIndent: CGFloat = 18

// MARK: - TalkPulse Widget Bundle

@main
struct TalkPulseWidgetBundle: WidgetBundle {
    var body: some Widget {
        TalkPulseWidget()
    }
}

// MARK: - Timeline Provider

struct TalkPulseProvider: AppIntentTimelineProvider {
    typealias Intent = TalkPulseConfigurationIntent

    func placeholder(in context: Context) -> TalkPulseEntry {
        TalkPulseEntry(date: Date(), snapshot: sampleSnapshot(), entryCount: 3)
    }

    func snapshot(for configuration: TalkPulseConfigurationIntent, in context: Context) async -> TalkPulseEntry {
        if context.isPreview {
            return TalkPulseEntry(date: Date(), snapshot: sampleSnapshot(), entryCount: configuration.entryCount)
        }
        let snapshot = await TalkFeedService.shared.cachedSnapshot()
        return TalkPulseEntry(date: Date(), snapshot: snapshot, entryCount: configuration.entryCount)
    }

    func timeline(for configuration: TalkPulseConfigurationIntent, in context: Context) async -> Timeline<TalkPulseEntry> {
        if context.isPreview {
            let entry = TalkPulseEntry(date: Date(), snapshot: sampleSnapshot(), entryCount: configuration.entryCount)
            return Timeline(entries: [entry], policy: .never)
        }

        do {
            let snapshot = try await TalkFeedService.shared.fetchAll()
            let entry = TalkPulseEntry(date: Date(), snapshot: snapshot, entryCount: configuration.entryCount)
            return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1800)))
        } catch {
            let cached = await TalkFeedService.shared.cachedSnapshot(lastError: feedErrorMessage(error))
            let entry = TalkPulseEntry(date: Date(), snapshot: cached, entryCount: configuration.entryCount)
            return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300)))
        }
    }

    private func sampleSnapshot() -> TalkPulseSnapshot {
        TalkPulseSnapshot(
            fetchedAt: Date(),
            topics: [
                TalkTopic(id: 1, title: "CKBA announcement - RGB++ launch", slug: "ckba", replyCount: 4, postCount: 5, categoryId: 40, categoryName: "News", categoryColorHex: "0088CC", lastPostedAt: Date(), createdAt: Date(), excerpt: nil, lastPoster: nil, isPinned: false, url: "https://example.discourse.host/t/ckba/1", isRead: false, isNew: true),
                TalkTopic(id: 2, title: "CellScript package management RFC", slug: "cellscript", replyCount: 8, postCount: 10, categoryId: 33, categoryName: "CKB Dev", categoryColorHex: "6B9E3F", lastPostedAt: Date(), createdAt: Date(), excerpt: nil, lastPoster: nil, isPinned: false, url: "https://example.discourse.host/t/cellscript/2", isRead: false, isNew: false),
                TalkTopic(id: 3, title: "Fiber Network testnet update", slug: "fiber", replyCount: 12, postCount: 15, categoryId: 42, categoryName: "L2 Dev", categoryColorHex: "C17D11", lastPostedAt: Date(), createdAt: Date(), excerpt: nil, lastPoster: nil, isPinned: false, url: "https://example.discourse.host/t/fiber/3", isRead: true, isNew: false)
            ],
            categories: [],
            watchHits: [
                WatchHit(id: 1, keyword: "CellScript", topicTitle: "CellScript package management RFC", topicId: 2, categoryName: "CKB Dev", replyCount: 8, relativeTime: "2h ago", url: "https://example.discourse.host/t/cellscript/2", isUnread: true, isNew: true),
                WatchHit(id: 2, keyword: "CKBA", topicTitle: "CKBA announcement", topicId: 1, categoryName: "News", replyCount: 4, relativeTime: "1h ago", url: "https://example.discourse.host/t/ckba/1", isUnread: true, isNew: true)
            ],
            newTopicsCount: 2,
            unreadTopicsCount: 2,
            keywordCounts: ["CellScript": 1, "CKBA": 2, "Fiber": 1],
            lastError: nil
        )
    }
}

struct TalkPulseEntry: TimelineEntry {
    let date: Date
    let snapshot: TalkPulseSnapshot
    let entryCount: Int
}

// MARK: - Widget Views

struct SmallWidgetView: View {
    let entry: TalkPulseEntry

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 9) {
                SmallHeaderView(entry: entry)

                if let warning = warningText {
                    WidgetWarningView(text: warning, compact: true)
                }

                if let first = entry.snapshot.topics.first {
                    SmallTopicLink(topic: first)
                } else {
                    EmptyStateView()
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var warningText: String? {
        if entry.snapshot.lastError != nil { return "Offline cache" }
        if entry.snapshot.isStale { return "Stale feed" }
        return nil
    }
}

struct MediumWidgetView: View {
    let entry: TalkPulseEntry

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 0) {
                HeaderView(entry: entry, compact: false)
                    .padding(.bottom, 8)

                if let warning = warningText {
                    WidgetWarningView(text: warning, compact: false)
                        .padding(.bottom, 6)
                }

                let displayed = Array(entry.snapshot.topics.prefix(mediumEntryCount))

                if displayed.isEmpty {
                    EmptyStateView()
                } else {
                    ForEach(displayed) { topic in
                        TopicLink(topic: topic, compact: false)
                        if topic.id != displayed.last?.id {
                            Divider().padding(.leading, widgetDividerIndent)
                        }
                    }
                }
            }
        }
    }

    private var warningText: String? {
        if let error = entry.snapshot.lastError { return error }
        if entry.snapshot.isStale { return "This feed is more than an hour old." }
        return nil
    }

    private var mediumEntryCount: Int {
        min(2, max(1, entry.entryCount), entry.snapshot.topics.count)
    }
}

struct LargeWidgetView: View {
    let entry: TalkPulseEntry

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 0) {
                HeaderView(entry: entry, compact: false)
                    .padding(.bottom, 8)

                if let warning = warningText {
                    WidgetWarningView(text: warning, compact: false)
                        .padding(.bottom, 6)
                }

                let displayed = Array(entry.snapshot.topics.prefix(largeEntryCount))

                if displayed.isEmpty {
                    EmptyStateView()
                } else {
                    ForEach(displayed) { topic in
                        TopicLink(topic: topic, compact: false)
                        if topic.id != displayed.last?.id {
                            Divider().padding(.leading, widgetDividerIndent)
                        }
                    }
                }

                if !entry.snapshot.watchHits.isEmpty {
                    Divider().padding(.vertical, 6)
                    HStack(spacing: 5) {
                        Image(systemName: "eye")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Watchlist")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(.orange)
                    .padding(.bottom, 3)

                    ForEach(entry.snapshot.watchHits.prefix(2)) { hit in
                        WatchHitLink(hit: hit, compact: false)
                    }
                } else if !displayed.isEmpty {
                    Divider().padding(.vertical, 6)
                    WidgetFreshnessFooter(snapshot: entry.snapshot)
                }
            }
        }
    }

    private var warningText: String? {
        if let error = entry.snapshot.lastError { return error }
        if entry.snapshot.isStale { return "This feed is more than an hour old." }
        return nil
    }

    private var largeEntryCount: Int {
        min(4, max(1, entry.entryCount), entry.snapshot.topics.count)
    }
}

struct WidgetShell<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .containerBackground(for: .widget) {
                Color(nsColor: .windowBackgroundColor)
            }
    }
}

// MARK: - Header View

struct HeaderView: View {
    let entry: TalkPulseEntry
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Label("TalkPulse", systemImage: "waveform.path.ecg")
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)

                Text(entry.snapshot.cacheFreshnessText)
                    .font(.system(size: compact ? 8 : 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            WidgetCountBadge(count: entry.snapshot.newTopicsCount, suffix: "new", color: .green, compact: compact)
        }
    }
}

struct SmallHeaderView: View {
    let entry: TalkPulseEntry

    var body: some View {
        HStack(spacing: 6) {
            Label("TalkPulse", systemImage: "waveform.path.ecg")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 4)

            if entry.snapshot.newTopicsCount > 0 {
                Text("\(entry.snapshot.newTopicsCount) new")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else {
                Text(entry.snapshot.cacheFreshnessText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

struct WidgetCountBadge: View {
    let count: Int
    let suffix: String
    let color: Color
    let compact: Bool

    var body: some View {
        if count > 0 {
            Text("\(count) \(suffix)")
                .font(.system(size: compact ? 10 : 11, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

// MARK: - Links

struct TopicLink: View {
    let topic: TalkTopic
    let compact: Bool

    var body: some View {
        if let url = widgetLink(for: topic) {
            Link(destination: url) {
                TopicRowWidget(topic: topic, compact: compact)
            }
            .buttonStyle(.plain)
        } else {
            TopicRowWidget(topic: topic, compact: compact)
        }
    }
}

struct WatchHitLink: View {
    let hit: WatchHit
    let compact: Bool

    var body: some View {
        if let url = widgetLink(for: hit) {
            Link(destination: url) {
                WatchHitRow(hit: hit, compact: compact)
            }
            .buttonStyle(.plain)
        } else {
            WatchHitRow(hit: hit, compact: compact)
        }
    }
}

struct SmallTopicLink: View {
    let topic: TalkTopic

    var body: some View {
        if let url = widgetLink(for: topic) {
            Link(destination: url) {
                SmallTopicRow(topic: topic)
            }
            .buttonStyle(.plain)
        } else {
            SmallTopicRow(topic: topic)
        }
    }
}

func widgetLink(for topic: TalkTopic) -> URL? {
    URL(string: topic.url)
}

func widgetLink(for hit: WatchHit) -> URL? {
    URL(string: hit.url)
}

// MARK: - Rows

struct TopicRowWidget: View {
    let topic: TalkTopic
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            WidgetStatusDot(isNew: topic.isNew)
                .padding(.top, compact ? 5 : 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(topic.title)
                    .font(.system(size: compact ? 12 : 11, weight: topic.isNew ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text(topic.categoryName)
                        .font(.system(size: compact ? 9 : 10, weight: .medium))
                        .foregroundStyle(widgetHexColor(topic.categoryColorHex) ?? .blue)
                        .lineLimit(1)

                    if topic.isNew {
                        Text("new")
                            .font(.system(size: compact ? 8 : 9, weight: .bold))
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    }

                    Text("\(topic.replyCount) replies")
                        .lineLimit(1)

                    Text(topic.displayTime)
                        .lineLimit(1)
                }
                .font(.system(size: compact ? 9 : 10))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 3 : 4)
        .contentShape(Rectangle())
        .accessibilityLabel("\(topic.title), \(topic.displayTime)")
    }
}

struct SmallTopicRow: View {
    let topic: TalkTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 7) {
                WidgetStatusDot(isNew: topic.isNew)
                    .padding(.top, 6)

                Text(topic.title)
                    .font(.system(size: 12, weight: topic.isNew ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.88)
            }

            Text(smallMetaText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("\(topic.title), \(topic.displayTime)")
    }

    private var smallMetaText: String {
        "\(topic.replyCount) replies · \(topic.relativeTime)"
    }
}

struct WatchHitRow: View {
    let hit: WatchHit
    let compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            WidgetStatusDot(isNew: hit.isNew)

            Text(hit.keyword)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)

            Text(hit.topicTitle)
                .font(.system(size: compact ? 10 : 11, weight: hit.isNew ? .semibold : .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(compact ? "\(hit.replyCount) replies" : "\(hit.replyCount) replies")
                .font(.system(size: compact ? 10 : 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, compact ? 2 : 3)
        .contentShape(Rectangle())
        .accessibilityLabel("\(hit.keyword), \(hit.topicTitle), \(hit.replyCount) replies")
    }
}

struct WidgetStatusDot: View {
    let isNew: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(isNew ? 1 : 0.22)
            .accessibilityHidden(true)
    }

    private var color: Color {
        isNew ? .green : .secondary
    }
}

struct WidgetFreshnessFooter: View {
    let snapshot: TalkPulseSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: snapshot.isStale ? "clock.badge.exclamationmark" : "clock")
                .font(.system(size: 10, weight: .semibold))
            Text(snapshot.cacheFreshnessText)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if snapshot.watchHits.isEmpty {
                Text("No watchlist hits")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(snapshot.isStale ? .orange : .secondary)
    }
}

struct WidgetWarningView: View {
    let text: String
    let compact: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
            Text(text)
                .font(.system(size: compact ? 9 : 10, weight: .medium))
                .lineLimit(compact ? 1 : 2)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct EmptyStateView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "tray")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("No topics saved")
                    .font(.system(size: 12, weight: .semibold))
                Text("Check your settings, then refresh.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Widget Configuration

struct TalkPulseWidgetEntryView: View {
    var entry: TalkPulseProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

struct TalkPulseWidget: Widget {
    let kind: String = "TalkPulseWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: TalkPulseConfigurationIntent.self,
            provider: TalkPulseProvider()
        ) { entry in
            TalkPulseWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("TalkPulse")
        .description("Discourse forum feed with new topics, freshness, and watchlist status.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private func widgetHexColor(_ hex: String?) -> Color? {
    guard let hex else { return nil }
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard cleaned.count == 6 else { return nil }

    let scanner = Scanner(string: cleaned)
    var rgb: UInt64 = 0
    guard scanner.scanHexInt64(&rgb) else { return nil }

    let r = Double((rgb >> 16) & 0xFF) / 255.0
    let g = Double((rgb >> 8) & 0xFF) / 255.0
    let b = Double(rgb & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}
