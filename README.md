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

## Importing Windows Media Player skins (in progress)

Settings (⌘,) has an **Import WMP Skin…** button. Piece 1 of the importer is done: it unzips a
`.wmz`, reads its `.wms` layout with a forgiving parser (`WMSParser`; real skins aren't valid XML)
and shows a report of the controls, images and script it found. It doesn't install anything yet.
Piece 2 is done too: `WMPArtwork` converts the skin's bitmaps to PNGs (the layout's
`transparencyColor` / `clippingColor` pixels become transparent) and finds each button inside its
sprite strip from the colour-coded mapping images. The report shows both.
Piece 3 is done: the report sheet has an **Install Skin** button. `WMPSkinBuilder` stacks the
pictures in WMP's order (children above their parent, negative `zIndex` underneath, which is how
Cerulean's eye shows through the face) on a shaped window of the layout's size, writes a `skin.json`
and installs it like any other skin. To get back to another skin, use Settings (⌘,).
Piece 4 is done: the builder now turns the skin's controls into working widgets: the transport
buttons (previous / play / pause / stop / next, using their mapped boxes cropped from the sprite
strips, with hover, pressed and disabled pictures), the seek slider (the track, thumb and
`borderSize` end caps), the title and time text (new plain text style, new `positionTime`
binding), and the minimize / close buttons. Simple positions like `jscript:metadata.top` are resolved.
Piece 5 is done: the skin's `effects` window becomes a bare visualizer sitting behind the face
(so it shows through the eye), the small "next visualization" button cycles bars / waveform /
radial / off, and the Audio controls and Playlist buttons open the Equalizer and a new Playlist
window (also ⌘L). New bindings: `showEqualizer`, `showPlaylist`, `nextVisualization`.
Not carried over: sliding panes, scrolling title text, and the video window (the skin hides it by
script until a video plays).

### Other `.wmz` skins

The builder isn't Cerulean-specific. It recognises clicks such as `controls.play/pause/stop/next/previous`,
`view.minimize/close`, effects/visualization "next", equalizer and playlist panes, shuffle and repeat;
sliders by tag or by their `value` (position, volume, balance, `eq.gainLevelN`); text by tag or by
`wmpprop:` values (title, artist, position, duration); and falls back to the background picture's size
when the view has no width/height. After **Install Skin** a short summary lists what was skipped:
unrecognised buttons and sliders, text labels, other elements, positions worked out by script, and
elements the skin hides until a script shows them. Only Cerulean has been checked so far.

Added after trying "Cyberchannel": button boxes are matched by exact colour first (skins with
near-identical mapping colours were being merged); button groups with no picture of their own sit on
the view's background; transparent / outside colours declared on the `<view>` also apply to the hover
and disabled strips; `progressbar` works as a seek bar; `customslider` (a filmstrip of pictures plus a
grey position map, like a dial along an arc) works as a new `filmstripSlider` widget; the `video`
element shows the picture only while a video plays (the visualizer steps aside); and new bindings
`previousVisualization`, `openFiles`, `skipBack` / `skipForward` (±10 s, from rewind / fast-forward).

## Cover art

Get now converts the YouTube thumbnail to JPG (`--convert-thumbnails jpg`) before embedding it, because
the original WebP can't be embedded reliably in MP3/M4A. The player reads the cover art from the file
(or a same-named `.jpg`/`.png` next to it) and shows it where a video would be, with the visualizer
along the bottom if it's on (click to change it). Imported skins show it in their video window.
Songs downloaded before this change have no embedded picture; to get one, download them again
(turn off "skip songs I already have", or delete their line in `.downloaded.txt`).

## Get: Advanced tab

Get has Basic and Advanced tabs. Advanced (`AdvancedOptions` / `GetAdvancedView`) adds: audio quality
(bitrate) or video size, file-name styles and a custom yt-dlp template, plain file names, toggles for
cover art / tags and for splitting "Artist - Title" video titles, playlist item ranges and reverse
order, downloading just a time range, SponsorBlock cutting (non-music parts, sponsors, intros...),
embedded subtitles, cookies from a browser, a speed limit, and a free-text box for any other yt-dlp
options (options that run other programs, like `--exec`, are blocked). The exact command is shown and
can be copied into Terminal. Settings are remembered; "Reset to Defaults" restores normal behaviour,
which matches what Get did before this tab existed.
