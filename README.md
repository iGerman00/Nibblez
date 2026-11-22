# Nibblez

A tweak for the YouTube Music iOS app. It scrobbles, blocks artists, and adds like/dislike controls to the lock screen and Control Center

## Features

- Scrobbling to Last.fm, ListenBrainz, Maloja, or a webhook. Failed scrobbles are queued and retried
- Artist blocking
  - A Block button in the player's action row, next to like and dislike
  - Blocks match on YouTube channel ID (stable across renames) or on name
  - Optional built-in list of AI artists from [Soul Over AI](https://github.com/xoundbyte/soul-over-ai), refreshable from settings. Any artist on it can be allowed
  - Optionally, a thumbs down also blocks the artist, either everywhere or only from the lock screen button
  - Import and export of your list (JSON, or plain text with one name, channel ID or URL per line)
- Lock screen / Control Center star
  - iOS only draws one feedback button, so it can act as like, dislike, or like on single press and dislike on double press
  - The cover art briefly shows what was done

Settings are under Account > Nibblez

## Requirements

- Jailbroken device, iOS 15.0 or later, rootless (`iphoneos-arm64`)
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

This project is mostly AI generated with human direction, testing and review. Ironic, since it blocks "AI artists" but those are slop

## License

[GPL-3.0](LICENSE)

## Thanks

- [Soul Over AI](https://github.com/xoundbyte/soul-over-ai) for the artist list
- [YTM-AI-Artist-Song-Blocker](https://github.com/firemountainpeak-lang/YTM-AI-Artist-Song-Blocker), which the blocking idea comes from
- [YTMusicUltimate](https://github.com/dayanch96/YTMusicUltimate) and [YTMEnhanced](https://github.com/py233/YTMEnhanced), used as references for hooking the app
- [Theos](https://theos.dev)
