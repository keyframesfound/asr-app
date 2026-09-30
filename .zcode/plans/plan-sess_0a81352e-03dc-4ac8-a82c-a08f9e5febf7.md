## Goal
Consolidate the settings entries to just the sidebar "Settings" row (above the lessons list), remove the duplicate gear, and relocate the add (+) button into the sidebar as a "New Lesson" row above the lessons list.

Current state (both in `macapp/Sources/LessonTranscriber/`):
- Sidebar "Settings" row above the lessons — `Views/RootView.swift:14-19` (KEEP)
- Floating +/gear pair overlaid top-right of the detail pane — `Views/RootView.swift:52` and `85-109` (REMOVE both; + re-homed in sidebar)
- Hidden macOS `Settings` scene (app-menu "Settings…", Cmd-,) — `App.swift:25-31` (REMOVE per your choice)

## Changes

### 1. `Views/RootView.swift`
- **Remove the overlay** `.overlay(alignment: .topTrailing) { headerButtons }` (line 52) and delete the whole `headerButtons` computed property (lines 84-109). This removes the duplicate gear and the old + button.
- **Add a "New Lesson" sidebar row** in its own section between the Settings row and the lessons section, mirroring the Settings row style: `SidebarItem(icon: "plus", title: "New Lesson", subtitle: nil, ...)`. It is highlighted when `!state.showSettings && state.selection == nil` (exactly when the detail pane shows the New Lesson form).
- **Extend the `sidebarSelection` binding** (lines 71-82): handle the value `"new"` by setting `showSettings = false` and `selection = nil` (same action the old + button performed); the getter returns `"new"` when settings aren't shown and no lesson is selected.
- **Move the Cmd-, shortcut** onto the sidebar Settings row (the old gear button carried it; the Settings scene is going away). If `NavigationLink` ignores `keyboardShortcut`, fall back to attaching it via a background button.
- Update the stale comment at lines 54-56 that references the "+/gear buttons live in the content overlay".

### 2. `App.swift`
- Delete the `Settings { ... }` scene (lines 25-31). The sidebar row (inline detail pane) becomes the only settings entry.

## Verification
- Build with `DEVELOPER_DIR=/Applications/Xcode.app swift build` in `macapp/` (per project memory, CLT lacks SwiftUI macros).
- Confirm: only one gear in the UI (sidebar), + lives above the lessons list, Cmd-, opens the inline settings pane, clicking a lesson clears the New Lesson highlight.