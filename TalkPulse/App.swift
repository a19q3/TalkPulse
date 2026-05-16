import SwiftUI
import AppKit
import WidgetKit

// MARK: - Host App

@main
struct TalkPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("TalkPulse") {
            ContentView()
        }
        .defaultSize(width: 680, height: 720)
        .windowStyle(.titleBar)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.migrateStandardDefaultsIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleWidgetURL(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    private func handleWidgetURL(_ url: URL) {
        guard url.scheme == "talkpulse",
              url.host == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let targetURL = URL(string: urlParam) else {
            return
        }

        if let topicId = extractTopicId(from: targetURL) {
            Task {
                await ReadStateManager.shared.markAsRead(topicId: topicId)
                WidgetCenter.shared.reloadAllTimelines()
            }
        }

        NSWorkspace.shared.open(targetURL)
        NSApp.hide(nil)
    }
}

func extractTopicId(from url: URL) -> Int? {
    let components = url.pathComponents
    guard components.count >= 4,
          components[1] == "t",
          let id = Int(components.last ?? "") else {
        return nil
    }
    return id
}

// MARK: - Content View

@MainActor
struct ContentView: View {
    private let widgetHintDismissedKey = "talkpulse.widgetHintDismissed"

    private enum Panel: String, CaseIterable, Identifiable {
        case feed = "Feed"
        case settings = "Settings"

        var id: String { rawValue }
    }

    @State private var selectedPanel: Panel = .feed
    @State private var snapshot: TalkPulseSnapshot?
    @State private var isLoading = false
    @State private var lastError: String?
    @State private var configMessage: String?
    @State private var baseURL = ""
    @State private var categoryIds = ""
    @State private var watchKeywords = ""
    @State private var availableCategories: [DiscourseCategory] = []
    @State private var isTestingForum = false
    @State private var isLoadingCategories = false
    @State private var showingResetConfirmation = false
    @State private var showWidgetSetupHint = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

            Divider()

            Picker("View", selection: $selectedPanel) {
                ForEach(Panel.allCases) { panel in
                    Text(panel.rawValue).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            ScrollView {
                Group {
                    switch selectedPanel {
                    case .feed:
                        feedPanel
                    case .settings:
                        settingsPanel
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 620, minHeight: 640)
        .onAppear(perform: loadInitialState)
        .alert("Reset settings?", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) {
                loadConfigDraft(TalkPulseConfig.default)
                availableCategories = []
                saveSettings(refreshAfterSave: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores the default forum URL and clears category and watch keyword fields.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("TalkPulse")
                    .font(.system(size: 22, weight: .semibold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let snap = snapshot {
                CountBadge(label: "new", count: snap.newTopicsCount, color: .green)
                CountBadge(label: "unseen", count: snap.unreadTopicsCount, color: .red)
            }

            Button(action: refresh) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isLoading)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityLabel("Refresh feed")
        }
    }

    private var headerSubtitle: String {
        let forum = UserDefaults.talkPulse.loadConfig().baseURL
        guard let snapshot else { return "\(forum) - no feed saved" }
        return "\(forum) - \(snapshot.cacheFreshnessText)"
    }

    private var feedPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = lastError {
                MessageBanner(text: error, style: .error) {
                    refresh()
                }
            }

            if let snap = snapshot, let staleError = snap.lastError {
                MessageBanner(text: "\(staleError) Showing the last saved feed.", style: .warning)
            } else if let snap = snapshot, snap.isStale {
                MessageBanner(text: "This feed is more than an hour old. Refresh when you are online.", style: .warning)
            }

            if isLoading && snapshot == nil {
                LoadingRows()
            } else if let snap = snapshot, !snap.topics.isEmpty {
                feedSummary(snap)

                if showWidgetSetupHint {
                    WidgetSetupHint {
                        UserDefaults.talkPulse.set(true, forKey: widgetHintDismissedKey)
                        showWidgetSetupHint = false
                    }
                }

                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(snap.topics.prefix(12)) { topic in
                        TopicRow(topic: topic) {
                            openTopic(topic)
                        }
                    }
                }

                if !snap.watchHits.isEmpty {
                    WatchlistSection(hits: Array(snap.watchHits.prefix(8))) { hit in
                        openWatchHit(hit)
                    }
                }
            } else {
                EmptyStateCard(
                    title: "No feed saved yet",
                    message: "Confirm a public Discourse forum in Settings, then save and refresh to load the latest topics.",
                    actionLabel: "Open Settings"
                ) {
                    selectedPanel = .settings
                }
            }
        }
    }

    private func feedSummary(_ snap: TalkPulseSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Latest topics")
                .font(.system(size: 15, weight: .semibold))

            Text(snap.cacheFreshnessText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !snap.watchHits.isEmpty {
                Label("\(snap.watchHits.count) watchlist", systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if snap.unreadTopicsCount > 0 {
                Button {
                    markAllAsRead()
                } label: {
                    Label("Mark all seen", systemImage: "checkmark.circle")
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let message = configMessage {
                MessageBanner(text: message, style: .success)
            }

            SettingsCard(title: "Forum") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Discourse URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://talk.nervos.org", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Button {
                            testForum()
                        } label: {
                            if isTestingForum {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 16, height: 16)
                            } else {
                                Label("Test forum", systemImage: "checkmark.seal")
                            }
                        }
                        .disabled(isTestingForum || isLoading)

                        Text("Uses /latest.json to verify this is a reachable Discourse forum.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            SettingsCard(title: "Filters") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Category IDs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("1, 5, 10", text: $categoryIds)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 8) {
                            Button {
                                loadCategories()
                            } label: {
                                if isLoadingCategories {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Label("Load categories", systemImage: "list.bullet.rectangle")
                                }
                            }
                            .disabled(isLoadingCategories || isLoading)

                            Text("Latest topics are always included; categories add focused coverage.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if !availableCategories.isEmpty {
                            CategorySelectionGrid(
                                categories: availableCategories,
                                selectedIds: currentCategoryIdSet,
                                toggle: toggleCategory
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Watch keywords")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Swift, Rust, Grants", text: $watchKeywords)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    saveSettings(refreshAfterSave: true)
                } label: {
                    Label("Save and refresh", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showingResetConfirmation = true
                } label: {
                    Label("Reset defaults", systemImage: "arrow.counterclockwise")
                }

                Spacer()

                Button(role: .destructive) {
                    clearReadState()
                } label: {
                    Label("Clear seen state", systemImage: "circle.dashed")
                }
            }

            DiagnosticsDisclosure(snapshot: snapshot)
        }
    }

    private func loadInitialState() {
        UserDefaults.migrateStandardDefaultsIfNeeded()
        let savedSnapshot = UserDefaults.talkPulse.loadSnapshot()
        snapshot = savedSnapshot
        showWidgetSetupHint = savedSnapshot != nil && !UserDefaults.talkPulse.bool(forKey: widgetHintDismissedKey)
        loadConfigDraft(UserDefaults.talkPulse.loadConfig())
        if savedSnapshot == nil {
            selectedPanel = .settings
            configMessage = "Start by confirming a forum URL, then save and refresh."
        }
        Task {
            await TalkFeedService.shared.onAppOpen()
        }
    }

    private func loadConfigDraft(_ config: TalkPulseConfig) {
        baseURL = config.baseURL
        categoryIds = config.subscribedCategoryIds.map(String.init).joined(separator: ", ")
        watchKeywords = config.watchKeywords.joined(separator: ", ")
    }

    private func saveSettings(refreshAfterSave: Bool) {
        do {
            var config = try draftConfig()
            let previous = UserDefaults.talkPulse.loadConfig()
            config.lastOpenedAt = previous.lastOpenedAt
            config.lastSeenTopicId = previous.lastSeenTopicId
            UserDefaults.talkPulse.saveConfig(config)
            configMessage = "Settings saved."
            lastError = nil
            WidgetCenter.shared.reloadAllTimelines()

            if refreshAfterSave {
                refresh()
            }
        } catch {
            configMessage = nil
            lastError = error.localizedDescription
            selectedPanel = .settings
        }
    }

    private func draftConfig() throws -> TalkPulseConfig {
        let normalizedURL = try normalizedDraftBaseURL()

        return TalkPulseConfig(
            baseURL: normalizedURL,
            subscribedCategoryIds: try parseCategoryIds(categoryIds),
            watchKeywords: parseKeywords(watchKeywords),
            lastOpenedAt: nil,
            lastSeenTopicId: nil
        )
    }

    private func normalizedDraftBaseURL() throws -> String {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = trimmedURL.hasSuffix("/") ? String(trimmedURL.dropLast()) : trimmedURL

        guard let url = URL(string: normalizedURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else {
            throw ConfigError.invalidURL
        }

        return normalizedURL
    }

    private func parseCategoryIds(_ text: String) throws -> [Int] {
        let pieces = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var ids: [Int] = []
        for piece in pieces {
            guard let id = Int(piece), id > 0 else {
                throw ConfigError.invalidCategoryIds
            }
            ids.append(id)
        }

        return Array(Set(ids)).sorted()
    }

    private func parseKeywords(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var currentCategoryIdSet: Set<Int> {
        Set(categoryIds
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 })
    }

    private func toggleCategory(_ category: DiscourseCategory) {
        var ids = currentCategoryIdSet
        if ids.contains(category.id) {
            ids.remove(category.id)
        } else {
            ids.insert(category.id)
        }
        categoryIds = ids.sorted().map(String.init).joined(separator: ", ")
    }

    private func testForum() {
        isTestingForum = true
        lastError = nil
        configMessage = nil

        Task {
            do {
                let data = try await fetchDraftDiscourseData(path: "/latest.json")
                _ = try JSONDecoder().decode(DiscourseTopicList.self, from: data)
                await MainActor.run {
                    isTestingForum = false
                    configMessage = "Forum looks good. Save and refresh to update the feed and widget."
                }
            } catch {
                await MainActor.run {
                    isTestingForum = false
                    configMessage = nil
                    lastError = feedErrorMessage(error)
                    selectedPanel = .settings
                }
            }
        }
    }

    private func loadCategories() {
        isLoadingCategories = true
        lastError = nil
        configMessage = nil

        Task {
            do {
                let data = try await fetchDraftDiscourseData(path: "/categories.json")
                let categoryList = try JSONDecoder().decode(DiscourseCategoryList.self, from: data)
                let categories = categoryList.category_list.categories
                    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

                await MainActor.run {
                    availableCategories = categories
                    isLoadingCategories = false
                    configMessage = categories.isEmpty
                        ? "No categories were returned. You can still use the latest feed."
                        : "Loaded \(categories.count) categories."
                }
            } catch {
                await MainActor.run {
                    availableCategories = []
                    isLoadingCategories = false
                    configMessage = nil
                    lastError = feedErrorMessage(error)
                    selectedPanel = .settings
                }
            }
        }
    }

    private func fetchDraftDiscourseData(path: String) async throws -> Data {
        let base = try normalizedDraftBaseURL()
        guard let url = URL(string: base + path) else {
            throw TalkFeedService.FeedError.networkError("Invalid URL path: \(path)")
        }

        var request = URLRequest(url: url)
        request.setValue("TalkPulse/1.0 (macOS App)", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TalkFeedService.FeedError.networkError("Could not reach \(base)")
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw TalkFeedService.FeedError.httpError(httpResponse.statusCode, path)
        }

        return data
    }

    private func refresh() {
        isLoading = true
        lastError = nil
        configMessage = nil

        Task {
            do {
                let newSnapshot = try await TalkFeedService.shared.fetchAll()
                await MainActor.run {
                    snapshot = newSnapshot
                    isLoading = false
                    selectedPanel = .feed
                    showWidgetSetupHint = !UserDefaults.talkPulse.bool(forKey: widgetHintDismissedKey)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    lastError = feedErrorMessage(error)
                }
            }
        }
    }

    private func openTopic(_ topic: TalkTopic) {
        guard let url = URL(string: topic.url) else { return }

        Task {
            await ReadStateManager.shared.markAsRead(topicId: topic.id)
        }

        if var snap = snapshot, let index = snap.topics.firstIndex(where: { $0.id == topic.id }) {
            let wasUnread = !snap.topics[index].isRead
            let wasNew = snap.topics[index].isNew
            snap.topics[index].isRead = true
            if wasUnread {
                snap.unreadTopicsCount = max(0, snap.unreadTopicsCount - 1)
            }
            if wasUnread && wasNew {
                snap.newTopicsCount = max(0, snap.newTopicsCount - 1)
            }
            snapshot = snap
            UserDefaults.talkPulse.saveSnapshot(snap)
            WidgetCenter.shared.reloadAllTimelines()
        }

        NSWorkspace.shared.open(url)
    }

    private func openWatchHit(_ hit: WatchHit) {
        guard let url = URL(string: hit.url) else { return }

        Task {
            await ReadStateManager.shared.markAsRead(topicId: hit.topicId)
        }

        if var snap = snapshot {
            if let index = snap.topics.firstIndex(where: { $0.id == hit.topicId }) {
                let wasUnread = !snap.topics[index].isRead
                let wasNew = snap.topics[index].isNew
                snap.topics[index].isRead = true
                if wasUnread {
                    snap.unreadTopicsCount = max(0, snap.unreadTopicsCount - 1)
                }
                if wasUnread && wasNew {
                    snap.newTopicsCount = max(0, snap.newTopicsCount - 1)
                }
            }

            snap.watchHits = snap.watchHits.map { current in
                guard current.topicId == hit.topicId else { return current }
                var updated = current
                updated.isUnread = false
                updated.isNew = false
                return updated
            }

            snapshot = snap
            UserDefaults.talkPulse.saveSnapshot(snap)
            WidgetCenter.shared.reloadAllTimelines()
        }

        NSWorkspace.shared.open(url)
    }

    private func markAllAsRead() {
        guard var snap = snapshot else { return }
        let topicIds = snap.topics.map(\.id)

        Task {
            await ReadStateManager.shared.markAllAsRead(topicIds: topicIds)
        }

        snap.topics = snap.topics.map { topic in
            var updated = topic
            updated.isRead = true
            return updated
        }
        snap.watchHits = snap.watchHits.map { hit in
            var updated = hit
            updated.isUnread = false
            updated.isNew = false
            return updated
        }
        snap.newTopicsCount = 0
        snap.unreadTopicsCount = 0
        snapshot = snap
        UserDefaults.talkPulse.saveSnapshot(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func clearReadState() {
        Task {
            await ReadStateManager.shared.clearAll()
            await MainActor.run {
                if var snap = snapshot {
                    snap.topics = snap.topics.map { topic in
                        var updated = topic
                        updated.isRead = false
                        return updated
                    }
                    snap.newTopicsCount = snap.topics.filter { $0.isNew }.count
                    snap.unreadTopicsCount = snap.topics.count
                    snapshot = snap
                    UserDefaults.talkPulse.saveSnapshot(snap)
                }
                configMessage = "Seen state cleared."
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}

enum ConfigError: LocalizedError {
    case invalidURL
    case invalidCategoryIds

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid forum URL that starts with http:// or https://."
        case .invalidCategoryIds:
            return "Category IDs must be positive numbers separated by commas."
        }
    }
}

// MARK: - Host Components

struct TopicRow: View {
    let topic: TalkTopic
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(topic: topic)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 6) {
                    Text(topic.title)
                        .font(.system(size: 13, weight: topic.isRead ? .medium : .semibold))
                        .foregroundStyle(topic.isRead ? .secondary : .primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        CategoryPill(name: topic.categoryName, color: categoryColor(for: topic))
                        if let status = topic.statusLabel {
                            StatusLabel(text: status == "unread" ? "unseen" : status, color: status == "new" ? .green : .red)
                        }
                        Text("\(topic.replyCount) replies")
                        Text(topic.displayTime)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .accessibilityLabel("Open topic \(topic.title)")
        .accessibilityHint(topic.displayTime)
    }

    private var rowBackground: Color {
        if isHovering { return Color(nsColor: .selectedContentBackgroundColor).opacity(0.10) }
        if !topic.isRead { return Color(nsColor: .controlBackgroundColor).opacity(0.72) }
        return Color(nsColor: .controlBackgroundColor).opacity(0.36)
    }

    private func categoryColor(for topic: TalkTopic) -> Color {
        hexColor(topic.categoryColorHex) ?? .secondary
    }
}

struct WatchlistSection: View {
    let hits: [WatchHit]
    let action: (WatchHit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eye")
                    .foregroundStyle(.orange)
                Text("Watchlist")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            VStack(spacing: 6) {
                ForEach(hits) { hit in
                    Button {
                        action(hit)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(hit.isNew ? Color.green : (hit.isUnread ? Color.red : Color.secondary))
                                .frame(width: 7, height: 7)
                                .opacity(hit.isUnread ? 1 : 0.22)

                            Text(hit.keyword)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.orange)
                                .lineLimit(1)

                            Text(hit.topicTitle)
                                .font(.system(size: 12, weight: hit.isUnread ? .semibold : .medium))
                                .foregroundStyle(hit.isUnread ? .primary : .secondary)
                                .lineLimit(1)

                            Spacer()

                            Text("\(hit.replyCount) replies")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open watchlist topic \(hit.topicTitle)")
                }
            }
        }
        .padding(.top, 4)
    }
}

struct CategorySelectionGrid: View {
    let categories: [DiscourseCategory]
    let selectedIds: Set<Int>
    let toggle: (DiscourseCategory) -> Void

    private let columns = [GridItem(.adaptive(minimum: 148), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(categories, id: \DiscourseCategory.id) { (category: DiscourseCategory) in
                Button {
                    toggle(category)
                } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(hexColor(category.color) ?? .secondary)
                            .frame(width: 8, height: 18)

                        Text(category.displayName)
                            .font(.system(size: 11, weight: selectedIds.contains(category.id) ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if selectedIds.contains(category.id) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectedIds.contains(category.id) ? Color.accentColor.opacity(0.12) : Color(nsColor: .textBackgroundColor).opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(selectedIds.contains(category.id) ? "Remove" : "Add") category \(category.displayName)")
            }
        }
        .padding(.top, 2)
    }
}

struct WidgetSetupHint: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.grid.1x2")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text("Add TalkPulse to your desktop")
                    .font(.system(size: 13, weight: .semibold))
                Text("Right-click the desktop, choose Edit Widgets, search TalkPulse, then drag a size into place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss widget setup hint")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct DiagnosticsDisclosure: View {
    let snapshot: TalkPulseSnapshot?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                DiagnosticRow(label: "Widget click behavior", value: "Opens forum links directly")
                DiagnosticRow(label: "Shared storage", value: appGroupIdentifier)
                DiagnosticRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "Unknown")
                DiagnosticRow(label: "Cache", value: snapshot?.cacheFreshnessText ?? "No saved feed")
                DiagnosticRow(label: "Host-app seen state", value: "Shared with the widget when App Group access is available")
            }
            .padding(.top, 8)
        } label: {
            Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                .font(.system(size: 12, weight: .semibold))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct DiagnosticRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusDot: View {
    let topic: TalkTopic

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(topic.isRead ? 0.18 : 1)
            .accessibilityHidden(true)
    }

    private var color: Color {
        if topic.isNew && !topic.isRead { return .green }
        if !topic.isRead { return .red }
        return .secondary
    }
}

struct StatusLabel: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct CountBadge: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        if count > 0 {
            Text("\(count) \(label)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

struct CategoryPill: View {
    let name: String
    let color: Color

    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct EmptyStateCard: View {
    let title: String
    let message: String
    let actionLabel: String?
    let action: (() -> Void)?

    init(title: String, message: String, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct LoadingRows: View {
    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                    .frame(height: 54)
                    .overlay(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 8) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.18))
                                .frame(width: 260, height: 9)
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                                .frame(width: 170, height: 7)
                        }
                        .padding(.leading, 14)
                    }
            }
        }
    }
}

enum BannerStyle {
    case error
    case warning
    case success

    var color: Color {
        switch self {
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        }
    }

    var icon: String {
        switch self {
        case .error: return "exclamationmark.triangle"
        case .warning: return "clock.badge.exclamationmark"
        case .success: return "checkmark.circle"
        }
    }
}

struct MessageBanner: View {
    let text: String
    let style: BannerStyle
    let retryAction: (() -> Void)?

    init(text: String, style: BannerStyle, retryAction: (() -> Void)? = nil) {
        self.text = text
        self.style = style
        self.retryAction = retryAction
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let retryAction {
                Button("Retry", action: retryAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(style.color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

func hexColor(_ hex: String?) -> Color? {
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
