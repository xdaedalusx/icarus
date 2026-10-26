# iCarus

A SwiftUI media player for macOS 13+ with a skinnable interface.

## Run it

1. Open `Package.swift` in Xcode (File → Open, pick this folder).
2. Choose the `iCarus` scheme, destination **My Mac**, and press ⌘R.

Or from Terminal: `swift run`.

The app has two modes, switched with the toolbar control or ⌘1 / ⌘2:

- **Play** – the media player (skinnable).
- **Get** – paste a YouTube link and download it with yt-dlp. Finished songs go
  to `~/Music/iCarus` (changeable) and are added to Play automatically.

Get needs yt-dlp and ffmpeg: `brew install yt-dlp ffmpeg`. If downloads start
failing later, `brew upgrade yt-dlp` usually fixes it (YouTube changes often).

In Play, use ⌘O (or drag files onto the window) to add songs. Press ⌘, to open
the skin picker. To try an imported skin, choose "Import Skin Folder…" and pick
`SampleSkins/Sunset`.

## How it's organised

```
Core/    PlayerEngine (AVPlayer wrapper, queue, shuffle/repeat), Track,
         DownloadManager (yt-dlp process wrapper), Library, AppState
Skins/   Skin model, built-in skins, SkinManager (load/import/select)
Views/   Components (shared controls), Layouts, PlayerView, GetView, SkinSettingsView
```

The rule that makes skinning safe and simple:

- **Functionality** lives only in `PlayerEngine`.
- **Presentation** lives in `Skin` + the views. Views read the active skin via
  `@Environment(\.skin)` and never contain playback logic.

So any skin, however different it looks, controls the same engine.

## Skin format

A skin is a folder with a `skin.json` (see `SampleSkins/Sunset/skin.json`)
plus optional images (currently `backgroundImage`). Skins are data only: they
pick a built-in `layout`, colours, font design/sizes and metrics. They can't run
code, which keeps third-party skins safe.

## Growing it

Suggested next steps, roughly in order:

1. **More layouts:** add a case to `LayoutKind`, a view in `Layouts.swift`, and a
   branch in `PlayerView`.
2. **Image-based skins:** per-control images (play button, seek-bar track),
   loaded from the skin folder like `backgroundImage`.
3. **Declarative layouts:** describe the arrangement in JSON (a tree of
   `stack`, `button`, `seekbar`, `title`, `playlist` nodes with positions) and
   render it with a generic `SkinRenderer` view. This is the step that lets
   skin authors invent entirely new layouts without shipping code.
4. **Skin packaging:** zip import (`.iCarus` files), version checks, and a
   preview thumbnail in the picker.
5. **Player features:** persistent playlists, album art from metadata, media
   keys / Now Playing integration, equalizer.
