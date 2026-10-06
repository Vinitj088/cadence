# Cadence

Free, private, on-device dictation for macOS. Hold a key, speak, let go, and the text appears wherever your cursor is.

Everything runs locally on your Mac's Neural Engine. No accounts, no cloud, no subscription.

## Features

- **Hold to talk, tap for hands-free.** Hold your dictation key (Right/Left/Either ⌥, Right ⌘, Right ⌃, Right ⇧ or Fn) and release to insert. A quick tap keeps it listening until the next tap. Esc cancels.
- **A morphing overlay.** A thin dash rests on screen. While you speak it stretches into a black pill with a live 120 Hz waveform, races once while transcribing, then folds back. You can drag it to any of eight snap points, and it works over full-screen apps.
- **Every major local model.**

  | Model | Notes |
  |---|---|
  | NVIDIA Parakeet v2 / v3 / Ultra / Unified | Near-instant; v2 is the English default |
  | Cohere Transcribe | Most accurate in published benchmarks |
  | OpenAI Whisper Large v3 Turbo (full and compact) | Uses your vocabulary and preceding text as a prompt |
  | NVIDIA Canary 1B v2 | |
  | Apple's built-in dictation model | Nothing to download from Cadence |

- **Accuracy helpers.**
  - Custom vocabulary, used while decoding by Parakeet (CTC keyword boosting), Whisper (prompting) and Apple (contextual strings).
  - Silence trimming with Silero VAD.
  - Spoken numbers written as digits.
  - Filler and stutter removal.
  - Spacing and capitalization matched to the text around the cursor.
- **Optional AI polish** with Apple's on-device language model, which fixes punctuation and self-corrections and is checked so it never rewrites your meaning.
- **Test on your voice.** Read a passage once, and every installed model transcribes it, ranked by word error rate.
- **Quality-of-life touches.**
  - Restores your clipboard after pasting.
  - Prefers the built-in mic over Bluetooth, which avoids AirPods' low-quality call mode.
  - Searchable history.
  - Re-transcribe any past take with a different model.
  - Replacements and voice commands ("new line", "new paragraph").

## Requirements

- macOS 26 or later on Apple Silicon.
- Xcode's Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

## Build

```sh
./scripts/build-app.sh
open build/Cadence.app
```

The script compiles a release build, assembles `build/Cadence.app` and signs it. The first run creates a self-signed signing identity in its own keychain file, `~/Library/Keychains/murmur-signing.keychain-db`, which never touches your login keychain. A stable signature means macOS keeps the Microphone and Accessibility permissions across rebuilds.

On first launch Cadence asks for:

- **Microphone**, to hear you.
- **Accessibility**, to notice the dictation key and paste into other apps.

## Development notes

- **Engines** live in `Sources/Cadence/Engines`. Each one is an actor conforming to `TranscriptionEngine`. They build on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet, Cohere, Canary, VAD, text normalization), [WhisperKit](https://github.com/argmaxinc/WhisperKit) and Apple's `SpeechAnalyzer`.
- **Benchmarking:** `swift build -c release && .build/release/CadenceBench <parakeet-v2|parakeet-v3|parakeet-ultra|cohere|whisper> take.wav …` re-transcribes recordings for accuracy work. Your own takes are saved in `~/Library/Application Support/Cadence/Audio` for 14 days.
- **Logs:** `/usr/bin/log show --last 10m --predicate 'subsystem == "com.vinit.cadence"'`
- **`@ViewState` instead of `@State`:** in the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin ships only with full Xcode. The code uses a `@ViewState` typealias for the underlying property wrapper so it builds with the Command Line Tools alone.

## License

MIT. See [LICENSE](LICENSE). Model weights are downloaded from their publishers and are covered by their own licenses.
