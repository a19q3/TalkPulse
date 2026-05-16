import Foundation
import WidgetKit

// MARK: - TalkFeedService (Local Read State — No Auth Required)

actor TalkFeedService {
    static let shared = TalkFeedService()
    private var categoryNameMap: [Int: String] = [:]
    private var categoryColorMap: [Int: String] = [:]

    private func baseURL() -> String {
        let rawURL = UserDefaults.talkPulse.loadConfig().baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawURL.hasSuffix("/") ? String(rawURL.dropLast()) : rawURL
    }

    // MARK: - App Lifecycle

    /// Call this when the host app is actually opened by the user.
    /// Updates `lastOpenedAt` and `lastSeenTopicId` so subsequent widget refreshes
    /// can correctly mark topics as "new" vs "unread".
    func onAppOpen() {
        var config = UserDefaults.talkPulse.loadConfig()
        config.lastOpenedAt = Date()
        // Only bump lastSeenTopicId if we already have a snapshot
        if let snapshot = UserDefaults.talkPulse.loadSnapshot() {
            config.lastSeenTopicId = snapshot.topics.first?.id
        }
        UserDefaults.talkPulse.saveConfig(config)
    }

    // MARK: - Fetch All

    enum FeedError: Error, LocalizedError {
        case httpError(Int, String)
        case decodeError(String)
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let path):
                return "HTTP \(code) for \(path)"
            case .decodeError(let msg):
                return "Decode error: \(msg)"
            case .networkError(let msg):
                return "Network error: \(msg)"
            }
        }
    }

    /// Fetches all topics in parallel, deduplicates, computes state, and saves snapshot.
    func fetchAll() async throws -> TalkPulseSnapshot {
        let categories = try await fetchCategories()
        categoryNameMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        categoryColorMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.color) })

        let config = UserDefaults.talkPulse.loadConfig()
        let readIds = await ReadStateManager.shared.allReadIds()

        // Parallel fetch: latest + all subscribed categories at once
        async let latestTask = fetchLatest(readIds: readIds)
        let catIds = config.subscribedCategoryIds.filter { $0 != 0 }
        let catTasks = catIds.map { catId in
            Task {
                do {
                    return (id: catId, topics: try await fetchCategory(catId, readIds: readIds), error: Optional<String>.none)
                } catch {
                    return (id: catId, topics: [], error: Optional(feedErrorMessage(error)))
                }
            }
        }

        var allTopics = try await latestTask
        var failedCategoryIds: [Int] = []
        for task in catTasks {
            let result = await task.value
            if result.error != nil {
                failedCategoryIds.append(result.id)
            }
            allTopics.append(contentsOf: result.topics)
        }

        // Deduplicate
        var seen = Set<Int>()
        allTopics = allTopics.filter { seen.insert($0.id).inserted }

        // Sort by last posted date
        allTopics.sort { ($0.lastPostedAt ?? $0.createdAt) > ($1.lastPostedAt ?? $1.createdAt) }

        // Calculate "new" based on last seen
        let lastSeenId = config.lastSeenTopicId ?? 0
        let lastOpened = config.lastOpenedAt ?? Date.distantPast

        allTopics = allTopics.map { topic in
            var t = topic
            t.isNew = (t.id > lastSeenId) || (t.createdAt > lastOpened)
            return t
        }

        // Calculate watch hits
        let watchHits = scanWatchHits(topics: allTopics, keywords: config.watchKeywords)

        // Calculate keyword counts
        var keywordCounts: [String: Int] = [:]
        for keyword in config.watchKeywords {
            let count = allTopics.filter { $0.title.lowercased().contains(keyword.lowercased()) }.count
            if count > 0 { keywordCounts[keyword] = count }
        }

        let newTopics = allTopics.filter { $0.isNew && !$0.isRead }
        let unreadTopics = allTopics.filter { !$0.isRead }
        let storedTopics = allTopics
        let partialError = failedCategoryIds.isEmpty
            ? nil
            : "Some categories could not be loaded: \(failedCategoryIds.map(String.init).joined(separator: ", "))."

        let snapshot = TalkPulseSnapshot(
            fetchedAt: Date(),
            topics: storedTopics,
            categories: categories,
            watchHits: watchHits,
            newTopicsCount: newTopics.count,
            unreadTopicsCount: unreadTopics.count,
            keywordCounts: keywordCounts,
            lastError: partialError
        )

        UserDefaults.talkPulse.saveSnapshot(snapshot)
        return snapshot
    }

    // MARK: - Cached Snapshot (for widget gallery / previews)

    func cachedSnapshot(lastError: String? = nil) -> TalkPulseSnapshot {
        var snapshot = UserDefaults.talkPulse.loadSnapshot() ?? sampleSnapshot()
        snapshot.lastError = lastError
        return snapshot
    }

    // MARK: - Private Fetch Methods

    private func fetchData(from path: String) async throws -> Data {
        guard let url = URL(string: baseURL() + path) else {
            throw FeedError.networkError("Invalid URL path: \(path)")
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw FeedError.networkError("Forum URL must start with http:// or https://")
        }
        var request = URLRequest(url: url)
        request.setValue("TalkPulse/1.0 (macOS Widget)", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FeedError.networkError("Could not reach \(baseURL())")
        }
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw FeedError.httpError(httpResponse.statusCode, path)
        }
        return data
    }

    private func fetchLatest(readIds: Set<Int>) async throws -> [TalkTopic] {
        let data = try await fetchData(from: "/latest.json")
        let list: DiscourseTopicList
        do {
            list = try JSONDecoder().decode(DiscourseTopicList.self, from: data)
        } catch {
            throw FeedError.decodeError("Latest topics did not match the expected Discourse format")
        }
        return list.topic_list.topics.map { convert($0, readIds: readIds) }
    }

    private func fetchCategory(_ id: Int, readIds: Set<Int>) async throws -> [TalkTopic] {
        let data = try await fetchData(from: "/c/\(id).json")
        let list: DiscourseTopicList
        do {
            list = try JSONDecoder().decode(DiscourseTopicList.self, from: data)
        } catch {
            throw FeedError.decodeError("Category \(id) did not match the expected Discourse format")
        }
        return list.topic_list.topics.map { convert($0, readIds: readIds) }
    }

    private func fetchCategories() async throws -> [DiscourseCategory] {
        let data = try await fetchData(from: "/categories.json")
        let list: DiscourseCategoryList
        do {
            list = try JSONDecoder().decode(DiscourseCategoryList.self, from: data)
        } catch {
            throw FeedError.decodeError("Categories did not match the expected Discourse format")
        }
        return list.category_list.categories
    }

    // MARK: - Converter

    private func convert(_ topic: DiscourseTopic, readIds: Set<Int>) -> TalkTopic {
        let createdAt = parseISO8601(topic.created_at) ?? Date()
        let lastPostedAt = topic.last_posted_at.flatMap { parseISO8601($0) }
        let isRead = readIds.contains(topic.id)

        return TalkTopic(
            id: topic.id,
            title: topic.displayTitle,
            slug: topic.slug,
            replyCount: topic.reply_count,
            postCount: topic.posts_count,
            categoryId: topic.category_id,
            categoryName: categoryNameMap[topic.category_id] ?? "Unknown",
            categoryColorHex: categoryColorMap[topic.category_id],
            lastPostedAt: lastPostedAt,
            createdAt: createdAt,
            excerpt: topic.excerpt?.replacingOccurrences(of: "\u{0026}hellip;", with: "..."),
            lastPoster: nil,
            isPinned: topic.pinned,
            url: "\(baseURL())/t/\(topic.slug)/\(topic.id)",
            isRead: isRead,
            isNew: false
        )
    }

    // MARK: - Watch Hits

    private func scanWatchHits(topics: [TalkTopic], keywords: [String]) -> [WatchHit] {
        var hits: [WatchHit] = []

        for topic in topics {
            let lowerTitle = topic.title.lowercased()
            for keyword in keywords {
                if lowerTitle.contains(keyword.lowercased()) {
                    hits.append(WatchHit(
                        id: topic.id,
                        keyword: keyword,
                        topicTitle: topic.title,
                        topicId: topic.id,
                        categoryName: topic.categoryName,
                        replyCount: topic.replyCount,
                        relativeTime: topic.relativeTime,
                        url: topic.url,
                        isUnread: !topic.isRead,
                        isNew: topic.isNew
                    ))
                }
            }
        }

        var seen = Set<String>()
        hits = hits.filter { seen.insert("\($0.topicId)-\($0.keyword)").inserted }
        return hits.prefix(10).map { $0 }
    }

    // MARK: - Sample Data

    private func sampleSnapshot() -> TalkPulseSnapshot {
        TalkPulseSnapshot(
            fetchedAt: Date(),
            topics: [
                TalkTopic(id: 1, title: "CKBA announcement — RGB++ launch", slug: "ckba", replyCount: 4, postCount: 5, categoryId: 40, categoryName: "News", categoryColorHex: "0088CC", lastPostedAt: Date(), createdAt: Date(), excerpt: nil, lastPoster: nil, isPinned: false, url: "https://example.discourse.host/t/ckba/1", isRead: false, isNew: true),
                TalkTopic(id: 2, title: "CellScript package management RFC", slug: "cellscript", replyCount: 8, postCount: 10, categoryId: 33, categoryName: "CKB Dev", categoryColorHex: "0088CC", lastPostedAt: Date(), createdAt: Date(), excerpt: nil, lastPoster: nil, isPinned: false, url: "https://example.discourse.host/t/cellscript/2", isRead: false, isNew: false),
                TalkTopic(id: 3, title: "Fiber Network testnet update", slug: "fiber", replyCount: 12, postCount: 15, categoryId: 42, categoryName: "L2 Dev", categoryColorHex: "0088CC", lastPostedAt: Date(), createdAt: Date(), excerpt: nil, lastPoster: nil, isPinned: false, url: "https://example.discourse.host/t/fiber/3", isRead: true, isNew: false)
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

func feedErrorMessage(_ error: Error) -> String {
    if let feedError = error as? TalkFeedService.FeedError {
        switch feedError {
        case .httpError(let code, _):
            if code == 404 { return "This forum does not look like a Discourse site." }
            return "The forum returned HTTP \(code). Try again later."
        case .decodeError(let message):
            return message
        case .networkError(let message):
            return message
        }
    }
    return "Could not refresh the feed. Check the forum URL and network connection."
}
