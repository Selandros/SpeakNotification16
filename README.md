<img width="1536" height="1024" alt="appmarketingbanner" src="https://github.com/user-attachments/assets/8ca6725d-5c82-420f-a8c7-8ea54814c891" />


# SpeakNotification16

SpeakNotification16 is a rootless iOS 16 rebuild of the original SpeakNotification tweak created by Merdok.
It reads incoming notifications aloud using system TTS and keeps the focus on stable routing, predictable queue handling, and local-only logging.

## Highlights

- Rootless support for iOS 16
- Notification text-to-speech for incoming bulletins
- CarPlay, Bluetooth, and audio-route handling tuned for real-world use
- Stable English voice selection on iOS 16
- Event-driven queue drain so queued notifications keep moving after the current speak finishes
- Local-only logs for debugging and tuning

## Tested

- iPhone 14
- iOS 16.1
- Dopamine rootless jailbreak

## Install

Install the `.deb` with your package manager or over SSH:

```sh
dpkg -i com.selandros.speaknotification16_2.0.0_iphoneos-arm64.deb
```

Then respring SpringBoard.

If the original SpeakNotification package is installed, remove it first.

## Privacy and Logging

Logs stay on device only.
They are written to:

`/var/mobile/Library/Logs/log_speaknotification16.txt`

They may include notification text, bundle identifiers, audio route state, and other values useful for debugging.
Nothing is uploaded anywhere.

## Known Quirks

- Private SpringBoard and audio-session behavior can vary a little across iOS 16 point releases.
- CarPlay and Bluetooth routes can still depend on the current audio session state of other apps.
- The tweak is intentionally conservative about wakeups and audio cleanup to avoid clipped speech.

## Build

This is a Theos rootless project.

```sh
make clean
make package
```

## Conflicts

This package conflicts with the original SpeakNotification:

`com.merdok.speaknotification`

## Credits

- Original tweak: Merdok
- Rootless iOS 16 adaptation and current maintainer: Selandros
- Continued with permission from the original author

## License

Licensed under the MIT License.

SpeakNotification16 is based on the original MIT-licensed SpeakNotification project created by Merdok.

See [LICENSE](LICENSE) for details.
