<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Braindump app icon: a cute brain with sticky notes">
</p>

<h1 align="center">Braindump</h1>

<p align="center">
  <b>A scratchpad for dumping thoughts.</b><br>
  It looks and feels like a plain text file, but it knows notes, to-dos and the things you want to keep on your radar.
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/badge/Download_for_macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS"></a>
</p>

<p align="center">
  <sub>Version 0.1 · macOS 26 or later · Apple silicon · free · a private, non-commercial project</sub>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
    <img src="docs/screenshot-light.png" width="900" alt="Braindump window: notes and to-dos on the left; on the right the radar, the to-do list and a suggestion to turn a note into a to-do">
  </picture>
</p>

## Highlights

- ✍️ **Just type.** No save button, no folders. Lines that sit together are one note, and a blank line starts the next one.
- ✅ **To-dos and radar.** Turn any note into a to-do with ⌘↩, or put it on your radar with ⇧⌘↩. Radar is for things other people are working on that you only want to check every few days.
- ✨ **Suggestions that stay on your Mac.** A small on-device model notices when a note looks like a to-do or a radar item and offers to convert it.
- 🔗 **Jira and Notion previews.** A link at the end of a line shows the ticket's or page's status and title.
- 📄 **Your notes stay readable.** Everything lives in one JSON file in Documents. You can edit it by hand, and Braindump picks up the changes live.

## Install

1. Download `Braindump.zip` from the [latest release](../../releases/latest).
2. Unzip it and drag **Braindump** into **Applications**.
3. Open it once. Braindump isn't from the App Store and isn't notarized, so macOS blocks it the first time. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

Or [build it yourself](#building-from-source).

## How it works

1. **Notes are blocks.** Lines directly below each other form one note: the first line is the title, the rest are details (quieter, connected by a line on the left). A blank line starts a new note.
2. **The icon left of a note shows its type:**
   - dashed circle = note
   - blue circle = to-do
   - blue check = done
   - orange crosshair = radar

   Clicking it does this:
   - on a note: a small menu opens, where you pick **To-Do** or **Radar**,
   - on a to-do: it gets checked off (another click reopens it),
   - on a radar item: a menu opens with **Checked Today**, **Make It a To-Do** and **Take Off the Radar**.

   Right-click any icon to pick any type.
3. **Radar** items sit at the top of the sidebar with a status dot. It turns from green to orange after a few days (you choose how many) and red three days later. The ✓ button resets the timer, the × (shown on hover) takes the item off the radar. The Dock icon shows how many are due.
4. **To-dos** are listed in the sidebar below the radar. Done ones collapse under "Done" and can be archived.
5. **Select several lines** and a small pop-up appears:
   - **Merge into one note** (the first one stays the title, the others become details)
   - **Split into separate notes**
   - make the selected notes **to-dos** or put them on the **radar**
6. **Suggestions.** When you leave a line, a model looks at each note's title. If it looks like a to-do or like something for your radar, a suggestion appears in the sidebar. Everything runs on your Mac:
   - Apple Intelligence when it's available,
   - otherwise a tiny model of its own (about 1.3 MB, Apple frameworks only). It trains once on first launch (~30 s) and then learns from what you mark, accept or dismiss.
7. **Jira and Notion.** A Jira or Notion link at the end of a line gets a pill with its status and title. The radar and to-do lists show it too. This needs a token once, see [below](#connecting-jira-and-notion).

Braindump saves shortly after you type, when you switch apps, and when you quit.

### Typing shortcuts

- `[ ] ` at the start of a line turns it into a to-do, `[x] ` into a done to-do, and `🚧 ` puts it on the radar. The characters disappear right away; only the icon shows the type.
- ↩ at the end of a one-line to-do starts the next to-do. ↩ again on the empty line ends the list.
- ↩ in a `- bullet` line continues the list.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘↩ | Note → to-do → done → to-do |
| ⇧⌘↩ | Radar on/off |
| ⌥⌘↩ | Back to a plain note |
| ⌘J | Merge the selected lines into one note |
| ⇧⌘J | Split the selected lines into separate notes |
| ⌘Z / ⇧⌘Z | Undo / redo (text and type changes) |
| ⌥⌘I | Show/hide the sidebar |
| ⌘F | Find |
| ⌘, | Settings |

## Connecting Jira and Notion

Both live in **Settings (⌘,) → Connections**. Tokens are stored in the macOS Keychain.

- **Jira:** enter your Jira site (e.g. `your-company.atlassian.net`), your email and an [API token](https://id.atlassian.com/manage-profile/security/api-tokens). Then click "Save & Test". Only links to that site get a preview; the token is never sent anywhere else.
- **Notion:** create an [internal integration](https://www.notion.so/profile/integrations) and paste its token. Then give pages access: open a page → ••• → Connections → your integration. Doing it on a top-level page covers everything below it.

Until a connection is set up, the link shows "Connect Jira …" / "Connect Notion …". Clicking it opens the settings.

## Where your data lives

Nothing leaves your Mac, except the Jira and Notion lookups you set up yourself.

Your notes are readable JSON in `~/Documents/Braindump/Braindump.json`, one entry per note:

```json
{
  "type" : "radar",
  "title" : "New onboarding flow",
  "details" : [
    "https://your-company.atlassian.net/browse/APP-123",
    "Backend done, iOS missing"
  ],
  "created" : "2026-11-06T14:12:20Z",
  "lastChecked" : "2026-11-06T18:00:00Z",
  "id" : "…"
}
```

- `type` is `note`, `todo`, `done` or `radar`.
- `spaceBefore` only appears when there isn't exactly one blank line before the note.
- You can edit the file by hand; Braindump picks up outside changes live.
- `Braindump-Archive.json` appears once you use "Archive Done".
- Settings → "Choose Another File…" opens another Braindump file or imports a plain text file.

`~/Library/Application Support/Braindump/` holds the daily backups (last 30), the trained mini model, what you taught it, the suggestions you dismissed and the link preview cache.

## Building from source

Requirements: macOS 26+, Xcode with Swift 6.2+. No Xcode project needed, it's a Swift package.

```bash
./build.sh --install
```

This builds the app (release, ad-hoc signed, no developer account needed), copies it to `~/Applications/Braindump.app` and launches it. Without `--install` it only lands in `build/`.

Because the ad-hoc signature changes with every build, macOS asks again for access to Documents after each rebuild, and the Keychain asks once for your password. Signing with your own certificate avoids that:

```bash
SIGN_ID="Apple Development: Your Name (TEAMID)" ./build.sh --install
```

## About

Braindump is a private, non-commercial hobby project: no ads, no sales, no tracking. It's provided free of charge and without warranty. Mac and macOS are trademarks of Apple Inc.; this project isn't affiliated with Apple.

Found a bug or have an idea? [Open an issue](../../issues).
