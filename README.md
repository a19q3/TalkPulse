# TalkPulse

TalkPulse is a macOS desktop widget for following a public Discourse forum.

Set a forum URL, optionally add category IDs and watch keywords, then keep the latest discussions visible from the desktop or Notification Center. No Discourse login, API key, or server component is required.

## What You Get

- Small widget: one important topic plus the current new-topic count.
- Medium widget: up to two readable topic rows.
- Large widget: three readable topic rows plus compact recent rows or watchlist hits, so the large surface stays useful even when one section is sparse.
- Clickable rows: open the topic directly in your browser.
- Local seen state: topics opened from the host app are marked seen on the next refresh.
- New-topic badges in the widget, plus local seen/unseen controls in the host app.
- In-app settings for forum URL, category IDs, and watch keywords.
- Offline cache with stale/error hints instead of a blank widget.
- Per-user configuration, so different people can build the app with their own Apple account and their own forum settings.

## Requirements

- macOS 14 or newer.
- Xcode with the macOS SDK installed.
- XcodeGen. The setup script installs it through Homebrew if possible.
- A public Discourse forum. Private forums are not supported because TalkPulse does not use a Discourse login or API token.
- An Apple signing team for running the host app and WidgetKit extension.

## Quick Start

Clone the project:

```bash
git clone https://github.com/a19q3/TalkPulse.git
cd TalkPulse
```

Generate the Xcode project with bundle IDs that belong to your Apple account:

```bash
BUNDLE_ID_PREFIX=com.yourname ./setup.sh
```

This creates:

| Item | Example |
| --- | --- |
| Host app bundle ID | `com.yourname.talkpulse` |
| Widget bundle ID | `com.yourname.talkpulse.widget` |
| App Group | `group.com.yourname.talkpulse` |

In Xcode:

1. Select the `TalkPulse` target.
2. Set your signing team.
3. Select the `TalkPulseWidgetExtension` target.
4. Set the same signing team.
5. Build and run the host app once.
6. Save and refresh a forum in the host app.
7. Follow the in-app hint to add TalkPulse to the desktop.

Desktop path: right-click desktop -> Edit Widgets -> search for TalkPulse -> drag a size to the desktop.

## Configure Your Forum

Open the TalkPulse app and go to Settings.

| Setting | What to enter | Example |
| --- | --- | --- |
| Forum URL | The Discourse site root | `https://forum.swift.org` |
| Category IDs | Optional comma-separated IDs | `1, 5, 10` |
| Watch keywords | Optional comma-separated keywords | `Swift, Rust, Grants` |

Category IDs are optional. If you leave them empty, TalkPulse still reads the forum's latest feed.

Use **Test forum** to verify the URL before saving. Use **Load categories** to pick categories by name in a bounded selector instead of manually inspecting JSON.

After the first successful refresh, TalkPulse shows a dismissible reminder with the exact desktop-widget path.

To find category IDs, open:

```text
https://your.discourse.host/categories.json
```

Look for each category's `id`. TalkPulse also uses the category `color` field when rendering category pills.

## Use Your Own Apple Account

The default project IDs are for local development only. Anyone else should generate unique IDs before opening Xcode:

```bash
BUNDLE_ID_PREFIX=com.yourname ./setup.sh
```

If your Apple account or developer portal already has a specific App Group, pass it explicitly:

```bash
BUNDLE_ID_PREFIX=com.yourname \
APP_GROUP_ID=group.com.yourname.talkpulse \
./setup.sh
```

You can also set every identifier directly:

```bash
APP_BUNDLE_ID=com.yourname.talkpulse \
WIDGET_BUNDLE_ID=com.yourname.talkpulse.widget \
APP_GROUP_ID=group.com.yourname.talkpulse \
./setup.sh
```

Both targets must use the same App Group if you want the host app and widget to share settings, cached feed data, and seen state. If App Groups are not available for your account, the app can still fetch data, but the host app and widget may not stay fully in sync.

## Widget Behavior

- The widget refreshes about every 30 minutes.
- Fetch failures retry sooner and keep showing cached content.
- The host app's Refresh button updates the cache immediately.
- Widgets show feed freshness so stale cache is visible.
- Clicking a widget topic opens the browser directly. The host app is not brought forward, because having both the app and website pop up is noisy.
- Opening a topic from inside the host app records that topic as seen locally.
- Watchlist hits are based on keyword matches in topic titles.

## If The Widget Does Not Appear

First check the basics:

- Build and run the host app once.
- Make sure `TalkPulse` and `TalkPulseWidgetExtension` use the same signing team.
- Make sure the widget extension is embedded in the app.
- Remove old copies of TalkPulse from other folders if you have built it before.
- Restart Notification Center, then reopen the widget picker:

```bash
killall NotificationCenter
```

If you changed bundle IDs or App Groups, regenerate the project and rebuild:

```bash
OPEN_XCODE=0 BUNDLE_ID_PREFIX=com.yourname ./setup.sh
```

For advanced debugging, replace the bundle ID with your own widget ID:

```bash
pluginkit -m -A -D -v -i com.yourname.talkpulse.widget
```

## Development

The Xcode project is generated from `project.yml`, so `TalkPulse.xcodeproj` is intentionally ignored by git.

Regenerate without opening Xcode:

```bash
OPEN_XCODE=0 ./setup.sh
```

Compile from the command line:

```bash
xcodebuild \
  -project TalkPulse.xcodeproj \
  -scheme TalkPulse \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=NO \
  build
```

This command is useful for compile checks. For actually using the widget on your Mac, build and run from Xcode with your signing team.

## Project Layout

```text
Shared/
  FeedService.swift      Discourse fetching, category merging, watchlist scan
  Models.swift           Models, configuration, local seen state, shared storage

TalkPulse/
  App.swift              macOS host app and settings UI
  Info.plist             Host app metadata
  TalkPulse.entitlements Host app sandbox and App Group entitlements

TalkPulseWidget/
  Widget.swift                 WidgetKit views and timeline provider
  ConfigurationIntent.swift    Widget edit-panel settings
  Info.plist                   Widget extension metadata
  TalkPulseWidget.entitlements Widget sandbox and App Group entitlements
```

## Privacy

TalkPulse stores your forum URL, category IDs, watch keywords, cached feed snapshot, and seen state locally. It does not send data to any service other than the Discourse forum URL you configure.

## License

MIT.
