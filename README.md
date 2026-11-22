# Nibblez

<p align="center">
  <img width="32%" alt="nibblez0" src="https://github.com/user-attachments/assets/7a15a6aa-1f40-46a3-9a24-56e914861bae" />
  <img width="32%" alt="nibblez1" src="https://github.com/user-attachments/assets/012e746f-0f5a-4bbb-afb6-eb38bc215606" />
  <img width="32%" alt="nibblez2" src="https://github.com/user-attachments/assets/55761900-ed4e-4603-be21-582305375c3c" />
</p>

A tweak for the YouTube Music iOS app. It scrobbles, blocks artists, and adds like/dislike controls to the lock screen and Control Center

## Features

- Scrobbling to Last.fm, ListenBrainz, Maloja, or a webhook. Failed scrobbles are queued and retried
- Artist blocking
  - There is a Block button in the player's action row
  - Blocks match on YouTube channel ID (stable across renames) or on name
  - There are built-in lists of AI artists from [Soul Over AI](https://github.com/xoundbyte/soul-over-ai) and [Zoundhub](https://zoundhub.com)
  - A thumbs down can be configured to block the artist, either everywhere or only from the lock screen button
  - Import and export of your list
  - AI list blocks can be overridden from the toast notification and will be visible under Account > Nibblez > Blocked Artists
- Lock screen / Control Center star
  - iOS only draws one feedback button, so it can act as like, dislike, or like on single press and dislike on double press
  - The cover art briefly shows what was done

Settings are under Account > Nibblez

## Requirements

- Jailbroken device, iOS 15.0 or later, rootless (`iphoneos-arm64`) [or the tweak can be injected into the app]
- YouTube Music
- ElleKit or Substrate

Developed and tested on iPadOS 17.7 with YouTube Music build 9.47.2 as of November 2026

## Install

Build the package (below) and install the `.deb` with your package manager or `dpkg -i`

## Build

Needs [Theos](https://theos.dev)

```
export THEOS=~/theos
make package ROOTLESS=1 FINALPACKAGE=1
```

The package ends up in `packages/`

## AI disclosure

This project is mostly AI generated with human direction, testing and review. Ironic, since it blocks "AI artists" but those are slop and this is not 🤷

## License

[GPL-3.0](LICENSE)

## Thanks

- [Soul Over AI](https://github.com/xoundbyte/soul-over-ai) and [Zoundhub](https://zoundhub.com), for the AI artist lists
- [YTM-AI-Artist-Song-Blocker](https://github.com/firemountainpeak-lang/YTM-AI-Artist-Song-Blocker), which the blocking idea comes from
- [YTMusicUltimate](https://github.com/dayanch96/YTMusicUltimate) and [YTMEnhanced](https://github.com/py233/YTMEnhanced), used as references for hooking the app
- [Theos](https://theos.dev)
- [Web Scrobbler](https://github.com/web-scrobbler/web-scrobbler) for the webhook format and inspiration for the scrobbling code