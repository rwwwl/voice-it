# Plan: addendum work

Covers `docs/addendum-changes.md` only. Stage 8 is deferred; anything the addendum changes there is listed at the end and not acted on until this plan is approved and built. Nothing below is built yet.

## Decisions taken (owner, 31 October 2026)

- New app, no migration: the `off` cleanup mode and the legacy `enabled` setting are removed outright, with no mapping or notice. A stale value is an ordinary settings error.
- No Pause function: no menu row, no "Paused" status, no paused icon.
- Sound cues are already removed (`2557207`). No work.
- Settings file stays plain JSON, no comments. The Vocabulary window may rewrite the file in a consistent format; all other settings and their values are kept.
- Network wording unchanged.
- Copy last dictation has two storage modes: history on (kept on disk) or memory only (cleared on quit). No third mode.
- Smaller points are left to my judgement (below).

## What the code already does

- `ConfigStore` already keeps the last good settings in memory, writes atomically, and keeps a `config.json.bak` once per launch. It does not yet surface errors, report line and column, keep a last-good copy on disk, or reject unknown values (an unknown hotkey or mode silently falls back to the default).
- The hotkey is a single modifier chosen from `Hotkey`. `HotkeyMonitor` cancels on any other key or modifier, so Shift cannot be used yet.
- `DictationPipeline.Outcome` already has copy-without-paste cases that go through `Paster.copyOnly`. Copy-only reuses that path.
- The menu is built by hand in `AppDelegate` (Tone, Cleanup, a Preview Overlay developer item, Launch at Login). Launch at login already exists.
- There is no history code yet. The only thing stored is the optional audio copy (`debug.keepAudio`).
- The dictionary is `{term, heardAs: [..]}`, one term with several mishearings, not one row per mishearing.

## Order of work

One commit per step. After each step I stop for you to try it and report latency and memory where the step could affect them. I'm keeping the addendum's order, with one change: the last-dictation store moves into step 3, because the menu needs it.

1. **Safe settings.** Replace silent fallbacks with validation: unknown hotkey, tone or mode, and wrong types, become named errors with line and column (a small position-reporting parse on failure). Keep using the last good settings, and save a last-good copy to disk so a restart with a broken file still works. Add a "Settings error" status and an "Open settings file…" item. Never write defaults over an existing file, and only create defaults when the file truly does not exist. Re-read just before any in-app write.
2. **Cleanup modes.** `CleanupMode` becomes `rulesOnly` and `full`. Remove `off`, the legacy `enabled` decode and their tests. Rules only removes um, uh, er, erm, ah (not "you know" or "like"), applies the vocabulary, snippets and spoken commands, and never loads the model.
3. **Menu and last dictation.** Rebuild the menu to the addendum layout without Pause. Status line: Ready, Loading the model…, Microphone access is off, Settings error. Add Advanced (version, models, last timings, memory, Open log…, Open models folder…, Save audio, Log dictated text, Preview Overlay). Add the last-dictation store: memory only by default, or on disk when history is on. Password-field dictations are never stored in either mode. "Copy last dictation" is one item that copies the cleaned text; the original words sit under Advanced.
4. **Hands-free and pill.** Pure hotkey state machine in `VoiceItLogic` (below), with `HotkeyMonitor` reduced to raw key and modifier events. Hold mode shows the spectrum and the tone chip only (when the tone is not Casual) and no X. Hands-free shows Done and X. Limits: 5 minutes with a warning at 4:30, and an automatic stop after 30 seconds of silence.
5. **Copy-only.** Right Command held with the hotkey. New `.copied` outcome and a green "Copied" pill, separate from the amber app-changed copy. Reuses `Paster.copyOnly`.
6. **Vocabulary window.** As specified in section 7 part 2. The window is native SwiftUI and edits through the same `ConfigStore`.
7. **Edge-state pills.** Check what is still missing against the addendum (5-second fade for edge states). Launch at login is already done.

## Hotkey state machine

Base key Right Option (H), Shift (S), copy modifier Right Command (C). States: idle, holding, hands-free, processing.

- H down in idle starts recording. S and C are read as flags during the hold, in any order, and decided at release.
- Any other key, or Escape, cancels during a hold.
- H up: under 300 ms with no flags is a tap and is discarded. Otherwise, if S is set, enter hands-free (exempt from the tap rule). If C is set, copy instead of paste. If both are set, copy wins and hands-free is ignored.
- Hands-free: H pressed again, or Done, finishes; its release is ignored. X or Escape cancels. Sleep, wake or a mic change stops and processes what was captured. If no speech was heard it shows "No speech detected".
- Validation in settings: the copy modifier must differ from the base key, and a base key of Shift is rejected.

## Judgement calls on the open questions

1. Hands-free limits: 5 minutes, warning at 4:30, 30 seconds of silence.
2. Copy-only modifier: Right Command, copy wins when both are held. I will check for conflicts and report.
3. Long dictations: under about 60 seconds of speech, as now. Above that, split at sentence boundaries and clean each chunk with the normal timeout. A chunk that fails falls back to its raw text. I will measure before fixing the numbers.
4. Copy last dictation is one item (cleaned text); the original is in Advanced.
5. Shared-build default: Rules only. Your own default stays With cleanup.
6. "Add from last dictation": build it after the basic window works, if it is cheap.
7. Vocabulary limit: set from a measurement of where cleanup slows, not the placeholder 200.

## Risks

- **Hotkey rework** is the highest risk (event tap behaviour, modifier ordering). Mitigated by the pure state machine and its tests; the feel still needs your hands.
- **Vocabulary shape.** The addendum shows one heard-as per row; the config has several per term. I propose keeping the config shape and showing one row per heard-as, so no data changes. Needs your OK.
- **Rewriting the file** drops any keys the app does not know. The `.bak` stays, and this matches the plain JSON decision.
- **Long text chunking** can change meaning at chunk boundaries; the existing cleanup guard applies per chunk.

## Tests

- Hotkey state machine: tap, hold, Shift first, Shift after, both modifiers, quick Option+Shift, second press, Escape in every state, auto-stop.
- Settings: load, save, each kind of error with line and column, last-good restart, atomic write, no overwrite of an existing file.
- Vocabulary validation: empty spelling, case-insensitive duplicates, bulk add counts.
- Cleanup modes: rules only never touches the model; filler list.
- Last-dictation store: memory only, history on, password-field exclusion.
- Existing no-network sandbox tests stay green.

## Questions answered

1. **"History on"** saves the text of each dictation (raw and cleaned) to a local file, separate from the audio option.
2. **Vocabulary rows:** keep the config shape (one term, several heard-as) and show one row per heard-as. Agreed.

## Stage 8 effects (noted only, not acted on)

- The README, About and privacy note will need the two storage modes and the new hotkey modes.
- "Speech only" and the optional second download interact with the Rules-only shared default.
- The Stage 8 mention of "Setup…" in the menu is not in the addendum menu; decide later where it goes.

---

# Revision 2: Style and Cleanup model (31 October 2026)

Design only. Nothing here is built until approved. Steps 1 to 7 above are built, committed and tested; this is step 8 and replaces parts of steps 2, 3 and 4 (cleanup modes, the Cleanup and Tone menu rows, the tone chip). The addendum (`docs/addendum-changes.md`, sections 4, 5, 6, 7a, 10) now holds the user-facing design; this section holds the engineering plan.

## Decisions taken (owner)

- One **Style** setting replaces Cleanup and Tone: **Exact** (never uses the model), **Natural** (default; uses the model only when needed), **Polished** (always uses it, formal wording), **Automatic by app (beta)**.
- A separate **Cleanup model** setting: **Keep ready** (default; the app is aimed at large-memory Macs) or **Free memory when idle**.
- Natural uses the model for a correction cue, a repeated word, a filler phrase, or text over a word threshold. Not for short clean text. Parakeet confidence is not a trigger.
- Shared builds: the cleanup model is an optional download; only Exact is available until it is installed.

## My choices, to confirm or change

| Choice | Value | Why |
| --- | --- | --- |
| Long-text threshold | **30 words** (setting `cleanup.naturalLongTextWords`) | Longest of 24 real dictations was 29 words, median 8; about 12 s of speech. Tuned later from the shadow log. |
| Default Cleanup model setting | **Keep ready** (decided). Idle setting, if chosen: 10 minutes (`cleanup.idleMinutes`) | Owner's decision: the app targets large-memory Macs. Free memory when idle stays as an option. |
| Load timing | Keep ready: loaded at launch, no waits. Only with Free memory when idle: Polished (and Automatic apps mapped to Polished) start loading at key-down. Natural loads after a trigger is found; wait up to 5 s, else paste the rules-only text with the amber notice | The load takes about 2.3 s; speech hides it for Polished but not for a trigger found after transcription. |
| Style chip | Shown only under Automatic by app, when the app's style is not Natural | Replaces "tone chip when not Casual" and avoids a chip on every dictation. |
| Literal | Removed; Exact replaces it. Only two prompts (Natural, Polished) | Fewer prompt caches (less memory, less warm-up). |
| Automatic mapping | casual to natural, formal to polished, literal to exact | Keeps your current per-app behaviour. |
| Your own settings file | **Approved:** I rewrite `config.json` once when the work lands (backup kept): `style: "automatic"`, `appStyles` converted from your `tones`. No migration code; the app will be rebuilt and freshly installed | Otherwise your per-app tones are silently ignored. |
| Old keys | **Decided:** no migration or compatibility. `cleanup.mode`, `defaultTone`, `tones` are simply not read (unknown keys are already ignored) | Fresh install. |

## FluidAudio and confidence

Yes. `ASRResult.confidence` is one score for the whole transcription, and `TokenTiming.confidence` is one per token (both public in the pinned revision). The app reads only the text today. Not used as a trigger, as instructed. I have not checked how well calibrated either score is.

## What changes in the code

**VoiceItLogic (pure, tested)**
- `Requirements.swift`: `CleanupMode` (rulesOnly, full) is replaced by `Style` (exact, natural, polished) and `StyleChoice` (those three plus automatic). `needsCleanupModel` becomes a question of style plus the model being installed. `Requirements.check` takes the style choice and whether the model is installed.
- `Config.swift`: new keys `style`, `appStyles`, `cleanup.memory`, `cleanup.idleMinutes`, `cleanup.naturalLongTextWords`; remove `cleanup.mode`, `defaultTone`, `tones` and the `Tone` type; strict decoding and named errors for the new values, ranges (idle 1 to 240, words 10 to 200); `style(forApp:)` replaces `tone(forApp:)`.
- New `NaturalPolicy.swift`: `reason(for text, longTextWords:) -> Reason?` (correction cue, repeat, filler, length). Pure, with the cue and filler lists as data.
- New `ModelPlan.swift`: pure decision from (style, memory setting, model installed, loaded, text) to: skip, use now, load then use, wait budget. Keeps the pipeline simple and testable.
- `CleanupPrompt.swift` and `CleanupGuard.swift`: casual becomes Natural, formal becomes Polished, literal removed (guard's formal tolerance applies to Polished).
- `LastDictationStore`, `TextProcessing`, `Vocabulary`, `HotkeyMachine`: unchanged.

**VoiceItCore**
- `DictationPipeline.swift`: resolves the style per dictation, applies `ModelPlan`, loads on demand with the 5 s wait budget, idle-unload timer (reset on each use), `prepareForDictation(style)` called at key-down, prompt refresh for two prompts instead of three; `Report` gains `style` and `modelUse` (used or skipped and why); the log line gains them (no text). `syncCleanupModel()` is rewritten around the memory setting.
- `Cleaner.swift`: prefix caches keyed by Natural and Polished; MLX cache limit stays.
- `Defaults.swift`: `modelLoadWait = 5`, idle and word-threshold defaults.
- A model-installed check (`Paths`) that does not load anything, for the menu and Requirements.

**VoiceIt (app)**
- `AppDelegate.swift`: Style and Cleanup model submenus replace Cleanup and Tone; Install row for shared builds; the tone override (remembered last choice) becomes a style choice; style chip text; key-down hook; `applySettings` handles style and memory changes; Advanced shows model state and the last dictation's model use.
- Overlay: chip text and Preview names ("style chip"); the existing Loading pill is reused for an on-demand load.

**Harness, fixtures, scripts, docs**
- `voice-it-harness`: `--pipeline-text <dir> <style>`; `--cleanup` and `scripts/check_cleanup.py` read fixtures by style (`.natural`, `.polished`); the literal fixtures move to an Exact check (rules only, no model). A new `--natural-policy` mode reproduces the skip/call analysis on the fixtures and a log, so thresholds can be re-checked.
- `fixtures/cleanup` renamed for styles; `baseline.json` regenerated (the baseline will change only where the prompt names change nothing else).
- README, NOTES, `Config` documentation; Stage 8 file untouched (effects below).

## Tests

- `NaturalPolicy`: each cue, "no" only at a clause start, repeats, each filler phrase, length at 29, 30 and 31 words, clean short text gives nil, a long text with no cues.
- `ModelPlan`: every style times memory setting times installed and loaded state; Exact never loads; Polished loads at key-down; Natural waits then falls back after 5 s.
- Config: each new key valid and invalid with line and column, ranges, old keys ignored, a stale `style` value is an error, `appStyles` with a bad style is an error.
- Pipeline logic that can be tested without the models (the idle timer with an injected clock).
- Existing no-network sandbox runs and `check_cleanup.py` stay green (Natural and Polished prompts unchanged in wording).

## Risks

- **Skipping the model can leave text uncleaned** (a self-correction without a cue). Mitigation: the policy errs towards calling the model; Polished and a "always on" choice exist; the shadow log measures misses.
- **Only if Free memory when idle is chosen:** the first model-needing dictation after idle waits about 2.3 s. Not the default. Mitigation: Keep ready, and the Polished preload.
- **Fixtures and the log are small** (20 synthetic, 24 real). The threshold and cue list are starting points, not proven.
- **Removing Literal** changes how Terminal and Xcode text is handled (Exact instead of the model at literal tone).
- **A larger change to the pipeline's model state** (the part I called fragile in the review). Mitigation: the pure `ModelPlan` and an injected clock for the timer.

## Order of work (after approval)

1. Pure logic with tests: `Style`, `StyleChoice`, config keys, `NaturalPolicy`, `ModelPlan`. Stop for review.
2. Pipeline: decisions, on-demand load, idle unload, log line. Measure latency and memory (Natural skipped, Natural used, Polished, cold load after idle).
3. Menu, chip and Advanced; rewrite of your settings file with your OK. Stop for you to test.
4. Harness, fixtures, scripts, README and NOTES.

## Stage 8 effects (noted only)

- The cleanup model download, its checksum and its 16 GB minimum become a separate optional step, after the speech-model setup.
- "Speech only" in the Stage 8 and addendum text is now simply Exact.
- Default style in a shared build: Exact until installed, then Natural.
- The README and privacy note describe the optional model, the 16 GB minimum, and (if chosen) the model being freed when idle.

## Status (31 October 2026)

Revision 2 is built: steps 1 to 4 are committed (`7395ae2`, `c05a0ed`, `da6d876` and the commit that follows them). Added beyond the plan: a speech-model warm-up at key-down (a 330 ms first-use penalty after a pause, measured in the owner's log), and a harness check of the Natural policy against the samples and the log. The "no" cue was widened after that check found a miss ("tuesday no wednesday" without commas). Stage 8 is still deferred.

