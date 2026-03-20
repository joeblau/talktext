# TalkText

TalkText is a macOS menu bar app for recording speech, transcribing it with `whisper-cli`, and inserting the transcription into the focused text field.

## Requirements

- macOS 14+
- `whisper-cpp`
- Accessibility access for auto-insert and synthetic paste fallback
- Microphone access

## Local Development

```sh
./setup.sh
./bundle.sh
open TalkText.app
```

## Homebrew Tap

Once the tap is published, install with:

```sh
brew tap joeblau/tap
brew install --cask talktext
```
