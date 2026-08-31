<h1 align="center">artNotch</h1>

<p align="center">A focused, lightweight MacBook notch companion for macOS.</p>

<p align="center">
  <a href="https://github.com/Aditya-Raj-Tiwari/artNotch/stargazers">
    <img src="https://img.shields.io/github/stars/Aditya-Raj-Tiwari/artNotch?style=social" alt="GitHub stars"/>
  </a>
  <a href="https://github.com/Aditya-Raj-Tiwari/artNotch/releases">
    <img src="https://img.shields.io/github/v/release/Aditya-Raj-Tiwari/artNotch?label=Release" alt="Latest release"/>
  </a>
  <img src="https://img.shields.io/badge/platform-macOS-black" alt="Platform macOS"/>
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="License GPLv3"/>
</p>

artNotch turns the MacBook notch into a quiet, native command surface for media, system HUDs, and a few focused utilities. It stays out of the way until you need it, then expands with smooth SwiftUI animations.

## Features

- **Media** — Now Playing controls, album art, and a real-time audio spectrum for Apple Music, Spotify, Cider, Tidal, Amazon Music, and YouTube Music, with synced lyrics.
- **Calendar** — Upcoming events at a glance, with quick access to your calendar app.
- **Reminders** — Live reminder activities in the notch and on the lock screen.
- **Focus / Do Not Disturb** — Focus-mode indicator that reflects your current status.
- **Timers** — Notch timers with presets, an optional control window, and a lock-screen timer widget.
- **Battery & Bluetooth** — Battery/charging HUD plus an AirPods / Bluetooth device battery HUD.
- **Privacy indicators** — Camera and microphone in-use indicators.
- **System HUDs** — Native-style volume and brightness HUDs (with optional BetterDisplay / Lunar integration for external displays).
- **Lock screen widgets** — Media, timer, reminders, and weather panels on the lock screen.

## Requirements

- Apple silicon Mac with a notch
- macOS 14 or later

## Building

Open `DynamicIsland.xcodeproj` in Xcode and build the `DynamicIsland` scheme (product name: **artNotch**).

```
xcodebuild -scheme DynamicIsland -configuration Release \
  -destination 'platform=macOS,arch=arm64' build
```

## Credits & License

artNotch is a fork of **Atoll (DynamicIsland)**, which is itself derived from the **boring.notch** project. It is released under the **GNU General Public License v3.0**. See [`LICENSE`](LICENSE) for the full text and [`NOTICE`](NOTICE) for attribution of upstream work and third-party assets.
