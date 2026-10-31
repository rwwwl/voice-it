# Addendum: product changes since the brief (31 October 2026)

This file updates `docs/brief.md` and sits beside `docs/stage-8-shareable-build.md`. Where it conflicts with the brief, this file wins. Read the brief and the Stage 8 file first, then this one.

**Revision 2 (31 October 2026)** replaces the separate Cleanup and Tone settings with one **Style** setting and a separate **Cleanup model** setting (sections 4 and 5), and makes the cleanup model an optional download in shared builds. Where sections 3.1, 4, 5, 6 and 10 conflict with earlier text, Revision 2 wins. It is a design only; nothing in it is built until approved.

The app is now called **Voice It** (repository `voice-it`). The folder, the code and some notes may still say "Dictate". Rename as part of the Stage 8 identity step, not before.

## 1. Summary

| Area | Change | Status |
| --- | --- | --- |
| Hotkey | Hold to talk stays the default. No buttons on the pill while holding | Decided |
| Hotkey | New hands-free mode: hold the hotkey plus Shift, release, and it keeps recording | Decided |
| Hotkey | New copy-only combination: text goes to the clipboard and is not pasted | Decided (key to choose) |
| Pill | The X button appears only in hands-free mode. A Done button is added there | Decided |
| Style | One Style setting replaces Cleanup and Tone: Exact, Natural (default), Polished, Automatic by app (beta) | Revision 2, awaiting approval |
| Cleanup model | A separate setting: Free memory when idle, or Keep ready. Optional download in shared builds | Revision 2, awaiting approval |
| Menu | Redesigned around clear actions. Developer details move under Advanced | Decided |
| Sound cues | Removed completely | Decided |
| Paste last dictation again | Not built | Decided |
| Settings file | Must be safe against mistakes | Decided |
| Vocabulary | A small Vocabulary window replaces hand-editing the dictionary | Decided |
| History window | Deferred | Deferred |
| Prompt tester | Deferred | Deferred |
| Hybrid cleanup (model only when needed) | Investigate and report, do not build | Proposed |
| Identity, licence, release | See section 2 | Decided |

## 2. Identity, licence and release decisions (already sent, for the record)

- **Name:** Voice It. **Repository:** `voice-it`, under the owner's personal GitHub account. **Bundle ID:** `io.github.[HANDLE].voice-it`. The owner's own permissions reset once when the bundle ID changes. That is accepted.
- **Licence for the app's own code:** GPL-3.0. Put the full text in `LICENSE`, set the copyright holder as the owner chooses, and check every dependency and model licence for compatibility with GPL-3.0. Flag anything incompatible.
- **Hosting:** GitHub Releases, starting private. The source stays private until the owner says otherwise.
- **Memory:** state a 16 GB minimum for the cleanup model. The speech model alone (443 MB download, Exact style) works on smaller Macs, and the cleanup model is an optional second download (Revision 2, section 4.4).
- **History:** off by default in shared builds.
- **Password fields:** no clipboard copy, no history entry and no log entry. Show a short message that dictation into a password field is not possible.
- **Git history:** publish a fresh single-commit history, keep the old history as a private local backup, and use a neutral author name and the GitHub noreply email for future commits.

## 3. Hotkey modes

The base hotkey is Right Option, configurable in the settings file. Avoid Left Control (Mission Control) and fn (Application windows) on the owner's Mac.

**3.1 Hold to talk (default)**
- Hold to record, release to finish, then transcribe, clean up and paste. This is unchanged, including the adaptive tail and discarding taps under 300 ms.
- While holding, the pill shows the spectrum and, only when Automatic by app has picked a style other than Natural for this app, the style chip. It has **no buttons**. The owner cannot click while holding the key. Escape and pressing another key still cancel.

**3.2 Hands-free**
- **Start:** hold the hotkey and add Shift, then release both. Recording continues without holding anything. Shift is an exception to the rule that pressing another key cancels the recording.
- **The pill** shows the spectrum, a **Done** button (a check mark) and an **X** button.
- **Finish:** click Done, or press the hotkey again. It then transcribes, cleans up and pastes as usual.
- **Cancel:** click X or press Escape. Nothing is pasted.
- **Limits (proposals, tell the owner what you chose):** a maximum recording length of about 5 minutes with a visible warning shortly before it ends, and an automatic stop after a long silence.
- **Long text:** the cleanup model gets slower with length and the 3-second timeout may trigger often. Decide what happens with long dictations (for example skip the model, or split the text into pieces) and tell the owner. Never lose the text: fall back to the raw transcript.

**3.3 Copy only**
- A second combination (the hotkey plus another modifier) records as usual but puts the text on the clipboard and does not paste.
- **Proposal for the modifier:** Right Command. Check for conflicts and tell the owner.
- **Pill:** a success state (green check) saying "Copied". This is different from the amber "Copied to clipboard" shown when the app changed and the paste was withheld.
- It uses the same path as the existing copy-without-paste case. Do not duplicate the logic.
- Combining hands-free and copy-only in one gesture is out of scope. Say what happens if both modifiers are held.

**3.4 Everything configurable** in the settings file, with sensible defaults, and validated by the safe-settings work in section 7.

## 4. Style and the cleanup model (Revision 2)

This replaces the earlier "two cleanup modes" and the separate tone setting.

**4.1 Style** (what the text goes through)
- **Exact:** never uses the model. The rules only: remove um, uh, er, erm and ah, apply the vocabulary, expand snippets, and turn spoken commands ("new line", "new paragraph", "question mark") into formatting. The cleanup model is not needed and is not loaded.
- **Natural (the default):** the same rules, then the model, but **only when the text is likely to need it** (4.2). Short, clean text is pasted with the rules only. The wording the model uses is the current casual style: fix, never rewrite.
- **Polished:** the same rules, then the model **always**, with formal wording (the current Formal style).
- **Automatic by app (beta):** each app has its own style (Exact, Natural or Polished) from the settings file, for example Terminal Exact and Mail Polished. Apps not listed use Natural. It is labelled beta because the per-app list is edited in the settings file.
- The old Literal style is gone; Exact replaces it. The model prompt exists in two versions (Natural, Polished), not three.

**4.2 When Natural uses the model.** The rules run first; the model is used if the resulting text has any of:
1. **A correction cue:** "actually", "I mean", "I meant", "sorry", "wait", "scratch that", "make that", "never mind", "or rather", "let me rephrase", and "no" when it starts a clause ("no," or "no wait").
2. **A repeated word or phrase** right next to itself ("the the", "can you can you").
3. **A filler phrase** the rules deliberately leave alone: "you know", "I mean", "kind of", "sort of", "or something", "or whatever", "basically".
4. **Length:** more than **30 words** (about 12 seconds of speech). Chosen because the longest of the 24 real dictations in the log was 29 words and the median 8, so everyday messages stay below it, while a longer dictation has more room for unmarked restarts. It is a setting (`cleanup.naturalLongTextWords`) and the shadow log below is how it gets tuned.

It does not run for short clean text. **Parakeet's confidence is not used as a trigger.** (FluidAudio does expose confidence: a score for the whole transcription and one per token. The app does not read either today.)

A wrong skip costs a missed tidy-up; a wrong call costs about 270 ms. When unsure the policy calls the model. The pill and the "Pasted without cleanup" notice are unchanged: a deliberate skip pastes normally with "Pasted", and the amber notice is only for a model that failed or timed out. Every dictation logs one line saying whether the model was used and why (cue, repeat, filler, length, polished) or skipped. No text is logged, so the evidence for tuning the cue list and threshold builds up without recording anything said.

**4.3 Cleanup model** (when the model is in memory; only matters for styles that can use it)
- **Keep ready (the default; the app is aimed at Macs with plenty of memory):** the model loads at launch and stays loaded. No waits. About 2.7 GB in use at all times.
- **Free memory when idle:** the model loads when first needed and is freed after 10 minutes without use (`cleanup.idleMinutes`). Footprint is about 2.7 GB while loaded and about 0.1 GB freed. Loading takes about 2.3 s. For Polished, and for an app that Automatic maps to Polished, loading starts when the key goes down, so it is ready by the time the key is released. In Natural, a dictation that needs the model after it was freed waits once (the pill shows Loading the model); if the load takes more than 5 s that dictation is pasted with the rules only and the amber notice is shown.
- Under Exact the model is not loaded whichever is chosen. With Keep ready the model is loaded at launch unless the style is Exact, and is loaded or freed when the style changes. Under Automatic it can load whenever an app maps to Natural or Polished.

**4.4 Shared builds.** The cleanup model (2.1 GB) is an optional download, separate from the speech model. Until it is installed only **Exact** is available: the other styles and the Cleanup model setting are greyed out with an "Install cleanup model…" row. Installing uses the Stage 8 downloader and checksum rules, and is offered only on Macs that meet the stated memory minimum. After installing, the default is Natural with Keep ready; the stated minimum is 16 GB. The owner's own build has the model already and shows none of this. If the settings file asks for Natural but the model is not installed, the app behaves as Exact and says so in Advanced; it is not a settings error.

**4.5 Investigate, do not build (unchanged):** the shadow log above is the way to find out how often the model changes the words beyond what the rules do.

## 5. Menu

The menu is the app's main control panel, since the settings window is deferred. Keep the main level to about a dozen rows, focused on actions a user can take. Use short labels.

```
Ready                                   (status: Ready, Loading the model…, Microphone access is off, Settings error)
-----------------------------------------
Style                                   > Exact                  Never uses the model
                                          Natural        (tick) Uses it only when needed
                                          Polished               Always uses it, formal wording
                                          Automatic by app (beta)
                                          -----
                                          Edit app styles…
Cleanup model                           > Keep ready             (tick)
                                          Free memory when idle
-----------------------------------------
Copy last dictation                     > Cleaned text / Original words
-----------------------------------------
Permissions: all allowed                (or Fix permissions…, which opens the right settings pane)
Launch at login
-----------------------------------------
Vocabulary…
Set up again…
Advanced                                >
Help and report a problem…
About
Quit
```

- **Pause is not built** (decided earlier), so it is not in the menu.
- **Style** replaces both Cleanup and Tone (beta). Each choice has a one-line description under it. "Edit app styles…" opens the settings file at the `appStyles` section.
- **Cleanup model** replaces nothing; it is a second row. In the owner's build it is always shown. In a shared build without the model it is greyed and an **Install cleanup model…** row appears under Style, and Natural, Polished and Automatic are greyed.
- **Advanced** also shows the cleanup model state (Loaded, Freed to save memory, Not installed) and, for the last dictation, whether the model was used or skipped and why.
- **Automatic by app is labelled beta** because the per-app styles are changed by editing the settings file.
- **Advanced** holds the developer details, shown greyed out when they are information: version and build, speech model and load time, cleanup model, timings of the last dictation (tail, transcribe, cleanup), and memory in use. It also holds the actions: Open settings file…, Open log…, Open models folder…, and two switches that are off by default, **Save audio from dictations** and **Log dictated text**.
- **Not in the menu:** sound cues (removed everywhere, including the Stage 7 plan) and any "paste last dictation again" item.
- The "Vocabulary…" row is new. Open settings file… now lives under Advanced (31 October 2026), which keeps the main level shorter; while the settings file has an error, the status line still offers it at the top. If that feels crowded, move Set up again… into Advanced and tell the owner.

## 6. Overlay pill changes (delta to the overlay spec)

- **Hold mode:** spectrum and the style chip (only when Automatic by app picked something other than Natural for the app in front). No X, no Done.
- **Hands-free mode:** spectrum, a Done button (check mark) and an X button, both round glass buttons in the same style as the old X (26 pt, even padding from the pill's edges).
- **New success state:** "Copied" with a green check, for the deliberate copy-only combination.
- **Unchanged:** processing, done, no speech, loading model, and the amber and red states. Edge-state pills fade after about 5 seconds, except loading.
- Remove any sound cue behaviour from the spec.

## 7. Settings safety and the Vocabulary window

**Part 1: safe settings**
- If the settings file has a mistake, keep using the last good settings, show a clear message naming the problem and where it is (line and column if available), and never lose the owner's settings.
- Show a "Settings error" state in the menu status line with an item that opens the file.
- Never overwrite the file with defaults.
- Write atomically, so a crash cannot leave a half-written file.

**Part 2: Vocabulary window**
Opened from **Vocabulary…** in the menu. Small, native, and in the same visual style as the rest of the app. Layout (approved as a prototype):
- **A header area** with two inputs, "Heard as (optional)" and "Correct spelling", an Add button, and an "Add many…" button. A hint says to leave Heard as empty to add a plain term.
- **Two kinds of entry:** a correction (heard as, correct) such as "fluid audio" becoming "FluidAudio", and a plain term (a word to spell correctly, no heard as).
- **A toolbar:** a search box, All, Corrections and Terms filter buttons, and a Copy list button that copies the list as text.
- **A list** where each row shows heard as, an arrow, and the correct spelling (or "Plain term" in muted italics). A pencil edits in place (Enter saves, Escape cancels) and a trash icon deletes, with an Undo link for about five seconds.
- **Add many…** opens a paste box, one entry per line, using `=` or an arrow for corrections. It reports how many were added and how many were skipped.
- **Validation:** no empty correct spelling, no duplicates (case insensitive), and a clear message for each problem.
- **Footer:** "N of LIMIT entries" with a thin meter that turns amber near the limit and warns that a long list slows the cleanup, plus a "Saved" flash after each change. The limit of 200 in the prototype is a placeholder: measure where the cleanup really slows down and state the limit.
- **Settings error state:** a red banner names the problem and offers Open settings file. Edits are paused, with a message, so nothing is overwritten.
- **Storage:** changes save straight to the same settings file, which stays the single source of truth. Preserve all other settings and any comments or formatting. Edits apply to the next dictation without a restart.
- **Privacy:** vocabulary stays on the Mac, is never logged, and is empty by default in shared builds. Example text appears only as placeholder text.
- **Accessibility:** keyboard friendly, with VoiceOver labels on the buttons and rows.
- **Optional, only if cheap:** an "Add from last dictation" button that shows the last original text so a word can be picked. Say whether you recommend it.

## 7a. Settings file keys (Revision 2)

Plain JSON, no comments, validated like the rest (a wrong value is a named settings error with line and column).

```json
{
  "style": "natural",
  "appStyles": { "com.apple.mail": "polished", "com.apple.Terminal": "exact" },
  "cleanup": {
    "memory": "keepReady",
    "idleMinutes": 10,
    "naturalLongTextWords": 30,
    "timeoutSeconds": 3,
    "model": "Qwen3-4B-Instruct-2507-4bit"
  }
}
```

- `style`: `exact`, `natural` (default), `polished` or `automatic`.
- `appStyles`: app identifier to `exact`, `natural` or `polished`. Used only when `style` is `automatic`; unlisted apps use `natural`.
- `cleanup.memory`: `keepReady` (default) or `freeWhenIdle`. `idleMinutes`: 1 to 240. `naturalLongTextWords`: 10 to 200.
- Removed with no migration (new app): `cleanup.mode`, `defaultTone` and `tones`. Old keys left in a file are ignored, not read.

## 8. Deferred and removed

- **Deferred:** the history window and the cleanup prompt tester (Stage 6 as originally written). Keep the small, off-by-default option that saves real audio and the raw transcript as files, with no window.
- **Removed:** sound cues, the paste-again menu item, the Off cleanup mode, and (Revision 2) the separate Cleanup and Tone settings and the Literal tone.
- **Unchanged:** Stage 8 (the shareable build) and its decisions.

## 9. Suggested order of work

1. Safe settings (section 7, part 1).
2. Cleanup modes (section 4).
3. The menu (section 5), including the status line and Pause.
4. Pill changes and hands-free mode (sections 3.2 and 6).
5. Copy-only combination (section 3.3).
6. The Vocabulary window (section 7, part 2).
7. The remaining lean edge-state pills and launch at login from the original plan.
8. Style and cleanup model (Revision 2; see `docs/addendum-plan.md`).
9. Stage 8.

Propose your own order if you see a better one, with a reason.

## 10. Questions to settle in your plan

Tell the owner what you recommend and why for each:
1. Silence timeout and maximum length for hands-free mode.
2. Which modifier to use for copy-only, and what happens if both modifiers are held.
3. How long dictations are handled by the cleanup model.
4. Whether the Copy last dictation submenu should become one item.
5. The default style for shared builds: **Exact until the cleanup model is installed, then Natural** (Revision 2).
6. Whether to include the "Add from last dictation" button.

## 11. How to work

- Read the brief, the Stage 8 file and this addendum. Write one combined plan with the order, the risks, how you will test each change, and the questions above. Stop for approval before any code.
- Then build in small steps with one commit each, and stop after each step for the owner to try it.
- Add tests for the hotkey state logic, the settings loading and saving, and the vocabulary validation. Report latency and memory after each step that could affect them.
- Keep the privacy rules unchanged: no network at runtime apart from the one-time model download, no sudo, no dictated text in logs unless the debug switch is on.
- Update the README, the notes, the licences file and the Stage 8 plan as you go, and record what changed in the notes.
