# Simple Photos for macOS

A lightweight, native macOS image viewer (`Swift` / `SwiftUI` + `AppKit`) that works like **Windows Photo Viewer** with an **ultra-minimal borderless interface**, automatic edge-matched background color, and zero-distraction fullscreen.

## Features

- **Automatic Sibling Discovery (Windows Photo Viewer style)**: Open any single image file (from Finder, drag-and-drop, or `⌘O`) and Simple Photos automatically discovers all sibling photos in the same folder in Finder's natural sort order—just press **`←`** / **`→`** or click the left/right sides of the window to browse through the entire folder.
- **Automatic Seamless Background Color (`B`)**: Samples the dominant border color of each image so letterbox/pillarbox bars blend seamlessly with the artwork's background color (green with green, white with white, etc.). Toggleable anytime via `B`, the bottom hover dock, or the menu bar.
- **Invisible Left / Right Side Click Navigation**: Click anywhere on the left or right side of the window or screen (including the very edge of the screen) to step backward or forward through photos without visible button clutter.
- **Distraction-Free Fullscreen**: Double-click the center of any image (or press `F`) to toggle Fullscreen with zero UI overlays—just the photo.
- **Images & Animated GIFs / WebPs Only**: Fast neighbor pre-caching for instant photo switching, plus smooth playback of animated GIFs, animated WebPs, and APNGs (excluding video files).

## Build & Run

```bash
./build.sh
open SimplePhotos.app
```

To install into `/Applications`:

```bash
cp -R SimplePhotos.app /Applications/
```

## Setting as Default Photo Viewer in Finder

1. Right-click any image (`.jpg`, `.png`, `.webp`, `.heic`, `.gif`, etc.) in Finder and click **Get Info** (`⌘I`).
2. Under **Open with:**, choose **Simple Photos.app**.
3. Click **Change All…** to open all images of that type with Simple Photos by default.

## Keyboard & Mouse Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `←` / `→` (or `A` / `D`) | Previous / Next image in folder |
| `Click Left / Right Side` | Previous / Next image in folder |
| `Double-Click Center` / `F` | Toggle Fullscreen (100% distraction-free) |
| `B` / `⌘B` | Toggle Automatic Seamless Background Color |
| `Scroll Wheel` / `Pinch` | Zoom in / out anchored at cursor |
| `0` / `1` | Fit to Window / Actual Size (`1:1`) |
| `[` / `]` (or `⌘L` / `⌘R`) | Rotate Left / Rotate Right (`90°`) |
| `M` | Flip Horizontally |
| `G` | Toggle Transparency Checkerboard Grid |
| `I` | Toggle Image Info & Options Popover |
| `T` | Toggle Pin Window Always-on-Top |
| `Space` | Play / Pause Slideshow (3s interval) |
| `⌘C` | Copy image to Clipboard |
| `⇧⌘R` | Reveal current file in Finder |
| `Delete` / `⌘⌫` | Move current image to Trash |
| `⌘O` | Open Image or Folder… |
| `Esc` | Exit Fullscreen / Reset Zoom / Stop Slideshow |
