import Foundation

// MARK: - Discourse API Models

struct DiscourseTopicList: Codable {
    let topic_list: TopicList
}

struct TopicList: Codable {
    let topics: [DiscourseTopic]
    let per_page: Int?
}

struct DiscourseTopic: Codable, Identifiable {
    let id: Int
    let title: String
    let fancy_title: String?
    let slug: String
    let posts_count: Int
    let reply_count: Int
    let created_at: String
    let last_posted_at: String?
    let bumped_at: String?
    let category_id: Int
    let excerpt: String?
    let pinned: Bool
    let closed: Bool
    let visible: Bool
    let image_url: String?

    var displayTitle: String { fancy_title ?? title }
}

struct DiscourseCategoryList: Codable {
    let category_list: CategoryList
}

struct CategoryList: Codable {
    let categories: [DiscourseCategory]
}

struct DiscourseCategory: Codable, Identifiable {
    let id: Int
    let name: String
    let slug: String
    let color: String
    let topic_count: Int
    let topics_day: Int
    let topics_week: Int
    let topics_month: Int
    let subcategory_ids: [Int]?
    let description: String?
    let parent_category_id: Int?

    var displayName: String { name }
}

// MARK: - Internal Models

struct TalkTopic: Codable, Identifiable {
    let id: Int
    let title: String
    let slug: String
    let replyCount: Int
    let postCount: Int
    let categoryId: Int
    let categoryName: String
    let categoryColorHex: String?
    let lastPostedAt: Date?
    let createdAt: Date
    let excerpt: String?
    let lastPoster: String?
    let isPinned: Bool
    let url: String

    var isRead: Bool
    var isNew: Bool

    var relativeTime: String {
        let date = lastPostedAt ?? createdAt
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff/60))m ago" }
        if diff < 86400 { return "\(Int(diff/3600))h ago" }
        if diff < 604800 { return "\(Int(diff/86400))d ago" }
        return "\(Int(diff/604800))w ago"
    }

    var displayTime: String {
        if isNew && !isRead { return "NEW · \(relativeTime)" }
        else if !isRead { return "unread · \(relativeTime)" }
        return relativeTime
    }

    var statusLabel: String? {
        if isNew && !isRead { return "new" }
        if !isRead { return "unread" }
        return nil
    }
}

struct WatchHit: Codable, Identifiable {
    let id: Int
    let keyword: String
    let topicTitle: String
    let topicId: Int
    let categoryName: String
    let replyCount: Int
    let relativeTime: String
    let url: String
    var isUnread: Bool
    var isNew: Bool
}

struct TalkPulseSnapshot: Codable {
    let fetchedAt: Date
    var topics: [TalkTopic]
    let categories: [DiscourseCategory]
    var watchHits: [WatchHit]
    var newTopicsCount: Int
    var unreadTopicsCount: Int
    let keywordCounts: [String: Int]
    var lastError: String?

    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 3600
    }
}

// MARK: - Configuration

struct TalkPulseConfig: Codable {
    var baseURL: String
    var subscribedCategoryIds: [Int]
    var watchKeywords: [String]
    var lastOpenedAt: Date?
    var lastSeenTopicId: Int?

    static let `default` = TalkPulseConfig(
        baseURL: "https://talk.nervos.org",
        subscribedCategoryIds: [],
        watchKeywords: [],
        lastOpenedAt: nil,
        lastSeenTopicId: nil
    )
}

// MARK: - Read State Tracking (Local Only)

actor ReadStateManager {
    static let shared = ReadStateManager()
    private let readKey = "talkpulse.read.topics"

    private var readTopicIds: Set<Int> {
        get {
            let array = UserDefaults.talkPulse.array(forKey: readKey) as? [Int] ?? []
            return Set(array)
        }
        set {
            UserDefaults.talkPulse.set(Array(newValue), forKey: readKey)
        }
    }

    func isRead(topicId: Int) -> Bool {
        readTopicIds.contains(topicId)
    }

    func markAsRead(topicId: Int) {
        var ids = readTopicIds
        ids.insert(topicId)
        readTopicIds = ids
    }

    func markAsUnread(topicId: Int) {
        var ids = readTopicIds
        ids.remove(topicId)
        readTopicIds = ids
    }

    func markAllAsRead(topicIds: [Int]) {
        var ids = readTopicIds
        topicIds.forEach { ids.insert($0) }
        readTopicIds = ids
    }

    func clearAll() {
        UserDefaults.talkPulse.removeObject(forKey: readKey)
    }

    func allReadIds() -> Set<Int> {
        readTopicIds
    }
}

// MARK: - Date Formatter (cached, handles both fractional and plain ISO8601)

extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

func parseISO8601(_ string: String) -> Date? {
    ISO8601DateFormatter.withFractional.date(from: string)
        ?? ISO8601DateFormatter.shared.date(from: string)
}

// MARK: - Local Storage

let appGroupIdentifier: String = {
    if let configuredGroup = Bundle.main.object(forInfoDictionaryKey: "TalkPulseAppGroupIdentifier") as? String,
       !configuredGroup.isEmpty,
       !configuredGroup.contains("$(") {
        return configuredGroup
    }

    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.openclaw.talkpulse"
    let appBundleIdentifier = bundleIdentifier.hasSuffix(".widget")
        ? String(bundleIdentifier.dropLast(".widget".count))
        : bundleIdentifier
    return "group.\(appBundleIdentifier)"
}()
let snapshotKey = "talkpulse.snapshot"
let configKey = "talkpulse.config"

extension UserDefaults {
    static var talkPulse: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func migrateStandardDefaultsIfNeeded() {
        let migrationKey = "talkpulse.defaults.migrated"
        guard !talkPulse.bool(forKey: migrationKey) else { return }

        if talkPulse.data(forKey: snapshotKey) == nil,
           let snapshotData = UserDefaults.standard.data(forKey: snapshotKey) {
            talkPulse.set(snapshotData, forKey: snapshotKey)
        }

        if talkPulse.data(forKey: configKey) == nil,
           let configData = UserDefaults.standard.data(forKey: configKey) {
            talkPulse.set(configData, forKey: configKey)
        }

        if talkPulse.array(forKey: "talkpulse.read.topics") == nil,
           let readTopicIds = UserDefaults.standard.array(forKey: "talkpulse.read.topics") {
            talkPulse.set(readTopicIds, forKey: "talkpulse.read.topics")
        }

        talkPulse.set(true, forKey: migrationKey)
    }

    func saveSnapshot(_ snapshot: TalkPulseSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            set(data, forKey: snapshotKey)
        }
    }

    func loadSnapshot() -> TalkPulseSnapshot? {
        guard let data = data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(TalkPulseSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    func saveConfig(_ config: TalkPulseConfig) {
        if let data = try? JSONEncoder().encode(config) {
            set(data, forKey: configKey)
        }
    }

    func loadConfig() -> TalkPulseConfig {
        guard let data = data(forKey: configKey),
              let config = try? JSONDecoder().decode(TalkPulseConfig.self, from: data) else {
            return .default
        }
        return config
    }
}
