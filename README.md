# NotesOverlay

Plain-text notes in a floating window, toggled with a global hotkey.
Menu-bar-only macOS app, pure Swift + AppKit, no dependencies, no Xcode project.

- **Hotkey** (default ⌃⌥Space) toggles the note window. Visible but unfocused → focuses it. Focused → hides it.
- **Esc**, **⌘W**, or the red close button hide it. It stays on top of everything, including full-screen apps, and follows you across Spaces.
- Notes are **plain `.txt` files in `~/Notes/NotesOverlay/`**, one per note, named after the note's first line. They autosave while you type and reload when another program changes the file.
- The title bar is empty until you move the mouse over the window; then it shows the close button, the note's first line, and buttons for **New Note** and **Switch Note**. **⌘+ / ⌘−** change the font size.

## Markdown

Notes are Markdown, rendered live: headings, **bold**, *italic*, ~~strike~~, `code`, fenced
code blocks (``` or ~~~, drawn as a shaded band), `- ` bullets (drawn as •), `- [ ]` / `- [x]`
tasks (drawn as checkboxes), `> ` quotes and `[links](url)`. Titles and file names use the first line with
its Markdown stripped. The line(s) your cursor is on show the raw source with the markers dimmed,
so you always see what you are editing. The file on disk, and anything you copy or paste,
is plain Markdown text; rendering never changes a character.

## Switching notes (⌘P)

Inside the note window, **⌘P** opens the note switcher:

| Key | Action |
|---|---|
| type | fuzzy-filter notes by title and content |
| ↑ ↓ | move selection (opens with the previously used note preselected, so ⌘P ↩ toggles between two notes) |
| ↩ | open the selected note, or create a note titled with the query when nothing matches |
| ⌘N | new empty note (also works in the editor) |
| ⌘⇧P | pin / unpin the selected note (pinned notes sort first) |
| ⌘⌫ | move the selected note to the macOS Trash (recoverable, no confirmation) |
| Esc, ⌘P | close the switcher |

Rows show the title plus "Current", or when the note was last opened, and its character count.

## Build & run

Requires the Xcode Command Line Tools (`xcode-select --install`), macOS 14+.

```sh
make run        # build, then open build/NotesOverlay.app
make install    # build, copy to /Applications, launch
```

`make install` is what you want for daily use: "Launch at Login" in the menu is only
offered when the app runs from `/Applications`.

## Change the hotkey

Menu bar icon → **Change Hotkey…** → press the new combination. It must include ⌃, ⌥ or ⌘.
Esc cancels, ⌫ restores ⌃⌥Space. If macOS or another app already owns a combination,
NotesOverlay tells you and lets you pick another.

## Change where notes are stored

Menu bar icon → **Choose Notes Folder…** opens the folder picker (its "New Folder" button
creates one on the spot). Pick a folder and choose whether to move your existing notes
there or just switch. Notes are always stored flat: one `.txt` per note, directly in that
folder. Hover the menu item to see the current folder. Default: `~/Notes/NotesOverlay/`.

The same setting from the command line (restart the app afterwards):

```sh
defaults write com.niid.NotesOverlay notesDirectory ~/Documents/Notes
defaults delete com.niid.NotesOverlay notesDirectory   # back to the default
```

Notes are renamed to match their first line when you hide the window or switch notes.
Pinned state and "last opened" times are kept in the app's preferences, keyed by file name.
