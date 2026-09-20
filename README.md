# NotesOverlay

One plain-text scratchpad in a floating window, toggled with a global hotkey.
Menu-bar-only macOS app, pure Swift + AppKit, no dependencies, no Xcode project.

- **Hotkey** (default ⌃⌥Space) toggles the note. Visible but unfocused → focuses it. Focused → hides it.
- **Esc**, **⌘W**, or the red close button hide it. It stays on top of everything, including full-screen apps, and follows you across Spaces.
- The note lives in **`~/Notes/scratchpad.txt`** as plain text. It autosaves while you type and reloads when another program changes the file.
- Title bar shows the first line, footer shows the character count. **⌘+ / ⌘−** change the font size.

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

## Change where the note is stored

```sh
defaults write com.niid.NotesOverlay notePath ~/Documents/scratchpad.txt
```

Restart the app afterwards. Delete the key to go back to `~/Notes/scratchpad.txt`:

```sh
defaults delete com.niid.NotesOverlay notePath
```
