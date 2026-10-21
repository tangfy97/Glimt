# Design

Glimt should feel like a well-made Mac tool from a small studio: fast, quiet, and obvious. These are the principles the code and the interface follow. When a change is in doubt, these decide.

## Behaviour

1. **Never make the user wait for a picture.** Nothing on the main thread reads a file or decodes an image. Budgets: page turn under 16 ms from key press to frame, pinch at the display's refresh rate, launch to window under 300 ms, a 10,000-item folder listed in under a second.
2. **Never lose a file.** Every change to files can be undone, runs in the order it was issued, and keeps RAW+JPEG pairs and sidecars together. Deleting goes to the Trash.
3. **Keyboard first, mouse welcome.** Every action has a key; number keys sort; nothing requires a modifier that a one-handed user can't reach. Everything is also in the menus and works with the trackpad.
4. **Files stay where they are.** No import, no library, no database. Glimt shows folders as they are on disk and follows changes made elsewhere.
5. **Native before custom.** Toolbars, menus, settings, full screen, tabs and text come from AppKit. Custom drawing is reserved for the grid, the folder columns and the viewer, where performance or density needs it.
6. **Quiet.** No network, no accounts, no badges, no onboarding. Messages say what happened in a full sentence ("Moved to Keepers"), not with symbols.

## Look

- **Neutral surroundings.** A tinted background shifts how the eye reads a photo's white balance, so every surface around a picture is a neutral grey: the system content background for the grid, a neutral grey behind the viewer, black in full screen.
- **One spacing scale.** Spacing comes from 8, 16 and 24 pt. Every left edge in the window sits on the 16 pt margin: the folder names, the thumbnails, and the text in the bottom bar. Space inside a group is smaller than space between groups, so each file name clearly belongs to the picture above it.
- **No boxes for the sake of boxes.** No cards around settings, no filled slots in the sort bar, no rounded plates behind thumbnails. Photos keep square corners; a selection is a thin accent ring around them. In the folder columns, selected folders get a small bookmark tick, grey along the path and accent for the open folder.
- **Words over decoration.** Labels are short and specific. Empty states say what to do in one sentence, left-aligned, without stock illustrations. The welcome page lists recent folders instead.
- **The Mac Settings layout.** Toolbar tabs, right-aligned labels ending in a colon, checkboxes rather than switches, and only real content: the sort folders list shows assigned keys, not nine rows of "not set".
- **Motion with a purpose.** The only animations are zooming and the transition between grid and viewer, and both turn into a short cross-fade when Reduce Motion is on.

Design snapshots (`GLIMT_SNAPSHOT`) make it possible to check these by eye on every change. Alternatives that were tried and set aside are kept in [docs/design](design/), for example the six highlight styles for the folder columns and the four icon concepts.

## Prior art

Glimt began as a modern take on [Phoenix Slides](https://github.com/gobbledegook/creevey) (formerly Creevey) by Dominic Yu. It shares no code with it; the ideas it carries on are the folder columns above the thumbnails, number-key sorting, slideshows that respect the selection, Page Up/Down jumping ten pictures, file info on the picture, and lossless rotation.

From photo culling tools such as Photo Mechanic and FastRawViewer it takes showing a RAW file's embedded preview first, keeping RAW+JPEG pairs together, the hold-to-zoom loupe, and keeping zoom while paging.

Deliberately not included, to stay small: catalogs and libraries, ratings and keywords beyond Finder tags, editing, side-by-side comparison, histograms and focus peaking, archive browsing, and anything that needs a network connection.
