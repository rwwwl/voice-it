# Privacy and security

Voice It is built so that what you say and write stays on your Mac. This note says exactly what it touches, what it stores, what it sends, and how you can check each claim yourself. It describes version 0.1.0.

## The short version

- **After setup, nothing leaves your Mac.** There is no account, no analytics, no telemetry, no crash reporting and no automatic update check.
- **The only network code is the model downloader.** It runs during setup (or when you choose to install the cleanup model later), talks only to Hugging Face, and sends nothing about you or your Mac beyond what any web request carries.
- **Your words are not stored** unless you switch that on. Audio is never saved unless you switch that on.
- **A password field is left alone:** nothing is recorded, pasted, copied, remembered or logged there.

## What it accesses, and why

| What | Why | What it does with it |
| --- | --- | --- |
| **Microphone** | To hear you while you hold the hotkey. | The audio is held in memory, turned into text on this Mac, and discarded. It is written to a file only if you turn on `debug.keepAudio` in the settings file (off by default; the files are yours to delete). |
| **Keyboard events** (Input Monitoring) | To notice the hotkey. | A listen-only tap receives key events. The code looks at modifier-key changes (the hotkey, Shift, the copy key) and at whether *any* key went down while you hold the hotkey (to cancel the recording) or was Escape. It never stores or logs which keys you press, and it cannot change or block what you type. |
| **Pasting** (Accessibility) | To send the paste (Cmd-V) into the app you are using. | It also reads the identifier of the frontmost app (for example `com.apple.mail`) to pick a style for that app and to notice if you switched apps. It does not read the contents of any window or field. |
| **The clipboard** | To paste the text. | Your clipboard is saved, replaced by the text, pasted, and then restored; the temporary copy is marked so clipboard managers skip it. A copy you ask for with the copy key is left on the clipboard for you. |
| **Secure input** (password fields) | To know when a password field has focus. | Then Voice It does not record, transcribe, paste, copy, remember, log or save anything. |

## What it stores, and where

Everything is under your own account.

| File | Contents | When |
| --- | --- | --- |
| `~/Library/Application Support/Voice It/config.json` (and `.bak`, `.lastgood.json`) | Your settings, vocabulary and snippets. | Always. |
| `~/Library/Application Support/Voice It/models/` | The speech model and, if you chose it, the cleanup model. | After setup. |
| `~/Library/Logs/Voice It/voice-it.log` | Timings and outcomes of each dictation, and whether the cleanup model was used and why. **No words**, unless you set `debug.logTranscripts` to true. Rotated at 1 MB. | Always (words off by default). |
| `~/Library/Application Support/Voice It/history.jsonl` | The text of each dictation. | Only if you set `history.enabled` to true. Readable only by you. Never from a password field. |
| `~/Library/Application Support/Voice It/audio/` | Recordings. | Only if you set `debug.keepAudio` to true. |
| In memory only | The last dictation, for the menu's "Copy last dictation". | Gone when you quit (unless history is on). |

Settings for the optional files are in the settings file (menu: Advanced → Open settings file…). All are off by default.

## What it sends, and to whom

Only the model downloader uses the network. It requests the model files, at fixed versions, from `huggingface.co` and the content hosts that site redirects to (`*.hf.co`); it refuses any other host and any address that is not `https`. Each request carries a fixed generic user agent (`VoiceIt-ModelDownloader`) and nothing else: no cookies, no account, no identifiers, no language or location. **Hugging Face, like any website, can see your IP address and which files you downloaded.** Every file is checked against a checksum that ships inside the app before it is used.

After the download, Voice It never contacts any server. If you prefer, you can fetch the models yourself and put them in the models folder; then Voice It never touches the network at all.

## How to check this yourself

- **Run it offline.** Turn off Wi-Fi and Ethernet, or use a firewall such as Little Snitch or LuLu, and use Voice It: it works the same. The project's own test does this: it starts the finished app inside a macOS sandbox profile that denies every network connection (`(version 1) (allow default) (deny network*)`, in `scripts/no-network.sb`) and requires it to load both models and be ready.
- **Read the code.** The project's tests fail if any code outside the downloader (`Sources/VoiceItDownloader`) uses the network, or if the speech, cleanup, hotkey or paste code depends on it.
- **Look at the log.** `~/Library/Logs/Voice It/voice-it.log` records what the app did, with no words in it by default.
- **Check the download.** Release files carry SHA-256 checksums; see the README.

## What it does not protect against

- Someone who can use your Mac while you are logged in can read what you dictate into any app, as they could anything else.
- If you switch on `history.enabled` or `debug.logTranscripts`, your words are written to files in your account: keep those files as private as you would any document.
- Voice It is signed without a certificate and is not notarised, so macOS cannot vouch for who built it. That is why the checksum and the source are there.
- It is a small free project, not an audited product. Do not rely on it for regulated or confidential material without your own checks.

## Reporting a problem

Open an issue on the project's GitHub page and use the template (it asks for your macOS version, the app version and the timing lines from the log; **never paste what you dictated**). For a security problem, please use GitHub's private vulnerability reporting on the repository's Security tab instead of a public issue.
