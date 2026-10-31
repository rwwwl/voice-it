# Plan

Follows the eight stages in `docs/brief.md`. Each stage ends with a commit, a `NOTES.md` update, measured numbers (key-release-to-paste latency, memory, model load time) and a stop for you to test.

## Before Stage 0 (you)

1. Finish installing Xcode 26.3, open it once, accept the licence, and sign in with your Apple ID (Settings > Accounts) so a signing certificate exists. I'll build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` so nothing needs `sudo xcode-select`.
2. Tell me when that's done. I won't start Stage 0 until you do.

## Stage 0: Spike (no app code)

- Record versions, free disk and RAM in `NOTES.md` (macOS 15.8.1, Swift 6.2.4 and 32 GB already checked).
- Install `uv` with Homebrew and run `parakeet-mlx` on a clip in an isolated environment.
- Write a throwaway Swift command-line tool (in `spike/`, deleted or kept as the harness seed) that transcribes the same clip with FluidAudio, with models kept in a local `models/` folder.
- Report a transcript, cold load time, warm load time and transcription time for both, plus disk used by the models.
- Test audio is synthetic (`scripts/make-say-fixtures.sh`), so Stage 0 measures speed, load time and pipeline correctness only, not accuracy. Real-voice accuracy waits for clips captured through the developer option in Stage 6.

## Stage 1: Skeleton

- SwiftPM package with targets `DictateCore` (library) and `Dictate` (menu-bar app), built and wrapped into a signed `.app` by `scripts/build.sh`. The `dictate-harness` CLI target arrives in Stage 2, when there is something to run on the fixtures.
- `LSUIElement` menu-bar app, CGEventTap for right Option hold-to-talk (taps under 300 ms ignored), `AVAudioEngine` capture converted to 16 kHz mono at capture, written to a temp WAV.
- **You:** grant Microphone and Input Monitoring; check that a hold records, a tap doesn't, and whether the first word is clipped.

## Stage 2: Dictate

- `Transcriber` protocol with a FluidAudio Parakeet v2 implementation, preloaded at launch.
- Paste: only if the app frontmost at key release is still frontmost; otherwise copy to the clipboard and say so in the pill. A dictation made while the model is loading is queued. Snapshot every pasteboard item and type, write the text, post Cmd-V, wait, restore. Detect secure input. Silence (VAD) pastes nothing.
- `dictate-harness` runs fixtures through the transcriber with no microphone and prints timings next to the expected text.
- **You:** grant Accessibility; test in Notes, Slack and Terminal; check the clipboard survives.

## Stage 3: Overlay

- Non-activating `NSPanel` (all Spaces, full-screen auxiliary) hosting a SwiftUI pill. The material lives in one `PillBackground` view so it can switch to Liquid Glass later.
- States: listening (real 16-band log-spaced spectrum from an FFT on the capture tap), processing scramble, done, no speech. Reduce Motion supported.
- **You:** judge the look over dark, white and full-screen windows.

## Stage 4: Cleanup

- Benchmark 2 or 3 current 1 to 4B instruction models on the fixture transcripts (latency, memory, and "fixes without rewording" by eye) and record a table.
- Spoken formatting, snippets and dictionary replacements in code; tone by frontmost bundle ID from the config file; 3 s timeout falls back to raw text with the amber state.

## Stage 6 (deferred)

The history window, dictionary editor window and prompt tester are deferred (NOTES.md, Decision 64); groundwork is on branch `stage-6-groundwork`. Only the optional audio copy was built (Decision 65).

## Stages 5 and 7 (done)

As in the brief: edge states with settings deep links; a small window with history, dictionary editor and prompt tester, plus a developer option to keep real dictation audio and transcripts as future fixtures; launch at login, active-display placement, sleep and wake recovery.

## Latency budget (target under 1 s for a 10 s clip)

| Step | Rough budget |
| --- | --- |
| Stop capture and finish the WAV | 20 ms |
| Parakeet v2 on the Neural Engine | 100 to 250 ms |
| Cleanup (about 300 prompt tokens, about 40 output tokens) | 400 to 700 ms |
| Paste | 50 ms |

These are guesses to measure against, not claims. Cleanup is the risky part; if it blows the budget, the levers are a smaller model, a shorter prompt, prompt caching of the fixed prefix, or skipping cleanup for very short clips.
