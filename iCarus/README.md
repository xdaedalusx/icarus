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

## Audio engine and equalizer

Playback uses `AVAudioEngine` (not `AVPlayer`) so it can run a 10-band EQ:

    player -> 10-band EQ -> balance mixer -> main mixer -> output

- **EQ panel:** press ⌘E in Play. Settings (bands, on/off, balance) are remembered.
- **Skin widgets:** a skin can place EQ controls with the bindings `bass`, `treble`,
  `eqBand1`...`eqBand10`, `balance`, `eqEnabled` and `eqReset`.
- **Visualizer:** in the default skin, click the artwork square to cycle
  off / bars / waveform / radial. `AudioAnalyzer` turns the engine's audio tap into
  a 32-band spectrum, a waveform and a loudness level; `VisualizerView` draws it.
  The tap only runs while a visualizer is on screen.
- **Video pane:** see below.

## Visualizations in skins

A skin places one with a widget of kind `visualization` and a `style` of `bars`,
`waveform` or `radial` (the binding is ignored). To add a new style, add a case to
`VisualizerStyle` and a draw function in `VisualizerView.swift`; it receives an
`AudioFrame` (`bands`, `waveform`, `level`).

## Video pane

Files with a video track show their picture in the video pane (in the default skin,
the artwork square becomes a widescreen frame). Under the hood:

- The SOUND still plays through the audio engine, so the EQ, balance and visualizer
  all work on videos.
- `VideoController` owns a muted `AVPlayer` that only supplies the picture.
  `PlayerEngine` is the clock: it starts, pauses and seeks the picture, and
  `correctDrift` re-syncs it if it ever strays more than 0.2 s from the audio.
- Skins place the pane with a widget of kind `videoPane` (binding ignored).
- Supported: MP4 / M4V / MOV with AAC audio (what AVFoundation can read). MKV and
  WebM aren't supported. In Get, choose "Video" to download an MP4 from YouTube.

## Image widgets, shaped windows and window actions

Skins can be built from their own artwork instead of the built-in look. New widget kinds:

| kind | draws | notes |
|---|---|---|
| `image` | static artwork | faceplate, decoration; never intercepts clicks |
| `imageButton` | `image` / `hoverImage` / `downImage` / `disabledImage` | toggles (shuffle, repeat, eqEnabled) stay "down" while on |
| `imageSlider` | `image` (track), `fillImage`, `thumbImage`, `thumbDownImage` | `inset` = how far in from each end the thumb's centre travels; `vertical: true` for bottom-to-top |
| `knob` | now rotates `image` if the skin supplies one | falls back to the built-in knob |

- **Sprite strips:** several buttons can share one file. Give each widget a `crop` of
  `[x, y, width, height]` in image pixels; the same crop is applied to its hover/down/disabled
  images, so those files line up cell for cell (this is how Windows Media Player skins work).
- **Images are looked up by file name inside the skin's own folder** (nothing outside it).
- **Layout options:** `showsFaceplate: false` hides the built-in faceplate;
  `shaped: true` makes the window borderless and transparent so its outline is the artwork's
  alpha. Shaped windows hide the title bar and toolbar, so use the menus instead:
  ⌘O add files, ⌘E equalizer, ⌘1/⌘2 Play/Get, and the new Playback menu
  (⌘P play/pause, ⌘→ next, ⌘← previous, ⌘. stop), plus ⌘W / ⌘M.
- **New bindings:** `play`, `pause`, `stop` (transport) and `closeWindow`, `minimizeWindow`.
  Transport buttons show their `disabledImage` when they can't do anything (e.g. nothing queued).

**Try it:** Settings (⌘,) → Import Skin Folder… → pick `SampleSkins/ImageDemo`.
It's a small shaped radio that uses every feature above.
