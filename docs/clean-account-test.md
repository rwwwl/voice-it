# Clean-account test

This is the test that cannot be done from inside the project: a stranger's first experience of the release, on a second standard user account. It takes about 45 minutes. Write down **every point of friction**, however small, in the notes column. Nothing here needs `sudo`.

## What has already been tested (so you know what to look for)

- 245 unit tests, including the downloader (resume, a flipped byte, low disk, bad hosts, cancelling), the settings, the hotkey logic, the password-field rule and copying the app.
- The release itself (`scripts/verify-release.sh`): valid ad hoc signature, arm64 only, no model or personal path inside, no developer switches, and it ran **with the network blocked** and became ready.
- Real downloads of both models (every file matched its checksum), a download killed at 435 MB and resumed, a full fresh install run unattended (the models downloaded, loaded without a restart), a real mouse drag from the app icon onto the folder, and a real paste into the setup window.
- **Not** tested by anyone yet: everything below. The unknowns are marked **(unknown)**.

## A. Prepare

1. **Make the test account.** System Settings → Users & Groups → **Add Account…** (it asks for your admin password). Account type **Standard**, name `Tester`. Log in to it (menu bar → fast user switching, or log out).
2. **Get the zip in as a stranger would**, through a browser, so macOS marks it as downloaded (quarantined). In *your own* account, in Terminal:
   ```
   cd <project folder>/releases/<version>-<commit> && python3 -m http.server 8000
   ```
   In the Tester account open Safari at `http://localhost:8000` and click `Voice-It-0.1.0-arm64.zip`. (Once the release is on GitHub, download it from there instead. Copying the file in Finder, AirDrop to yourself or a USB stick may *not* set the quarantine mark, which would skip the thing being tested.)
3. **Check the checksum** in Terminal: `shasum -a 256 ~/Downloads/Voice-It-0.1.0-arm64.zip`. It must equal the line in `SHA256SUMS.txt`.

## B. First run

| # | Do this | You should see | Notes / friction |
| --- | --- | --- | --- |
| 1 | Open the unzipped **Voice It** in Downloads. | macOS refuses to open it (not notarised). |  |
| 2 | System Settings → Privacy & Security → Security → **Open Anyway**, enter the password. | The button exists; Voice It opens. Note how long after step 1 it was still there. |  |
| 3 | The setup window opens by itself. | Welcome page, then the **Applications** step (it is running from Downloads). |  |
| 4 | Drag the Voice It icon onto the Applications folder icon. | It copies, then reopens from the copy. A standard account cannot write `/Applications`: expect the copy in `~/Applications` and a message saying so. **(unknown)** Does macOS block the *copy* again? If so, repeat Open Anyway and write it down. |  |
| 5 | Continue to **This Mac**. | Four green ticks (Apple silicon, macOS, memory, disk). |  |
| 6 | **Models:** leave the cleanup model ticked (16 GB or more) and click Download. | A progress bar with file names; about a minute on a fast connection. No system prompt of any kind. |  |
| 7 | **Permissions:** click each in turn. | A system prompt appears **only when you click**. Each status turns green as you allow it. Note any "quit and reopen" request (Input Monitoring). |  |
| 8 | **Try it:** click in the box, hold the hotkey, say a sentence, let go. | Your words appear in the box (the first one may wait while the speech model prepares: a note at the bottom says so). |  |
| 9 | **Menu bar:** read the page, click Done. Find the icon at the top right. | The icon matches the picture. Open its menu: Style, Cleanup model, Vocabulary, Set up again, Advanced, About, Quit. |  |
| 10 | Dictate into TextEdit, Notes and Mail. Add a word in Vocabulary and dictate it. | Text pasted each time. In Mail (Automatic by app) the pill shows a Polished chip. |  |
| 11 | Click a password field (for example a website's login box) and hold the hotkey. | The pill says it cannot dictate into a password field. Nothing recorded, pasted or copied. |  |

## C. The other tests

1. **Offline proof.** After setup, switch Wi-Fi off, quit Voice It from its menu and open it again. Dictate. It must work exactly as before.
2. **Interrupted download.** Quit Voice It and delete `~/Library/Application Support/Voice It/models`. Open it (setup reopens at Models), click Download, and at about 30% switch Wi-Fi off. *Expect:* a clear message and a **Retry** button. Switch Wi-Fi on and click Retry: *expect* the progress to carry on from where it stopped, not from 0 (a `*.part` file exists in the models folder meanwhile).
3. **Corrupt file.** Repeat 2, but while Wi-Fi is off change one byte inside the partial file, for example: `printf '\x01' | dd of="<path of the .part file>" bs=1 seek=1000000 count=1 conv=notrunc`. Switch Wi-Fi on and Retry. *Expect:* when that file finishes, a message that it did not match its checksum and was thrown away; Retry then fetches it again and succeeds.
4. **Low disk.** Make a small volume: `hdiutil create -size 1g -fs APFS -volname Small ~/small.dmg && hdiutil attach ~/small.dmg`. From Terminal run `VOICEIT_SUPPORT_DIR=/Volumes/Small/vi "/Applications/Voice It.app/Contents/MacOS/VoiceIt"` (use the `~/Applications` path if that is where it is). At **This Mac** and **Models** *expect* a red message that there is not enough free disk space, with the numbers, and the Download button not starting. Eject the volume afterwards (`hdiutil detach /Volumes/Small`).
5. **Update.** In the project: change `VERSION` to `0.1.1`, commit, run `scripts/make-release.sh`, download the new zip as in A2, and replace the app. Open it. *Record exactly which permissions are asked for again* (Microphone, Input Monitoring, Accessibility), whether stale entries appear switched on but do not work, whether the settings, vocabulary and models were kept, and whether the setup window opens. **(unknown)**
6. **Permissions flow.** For each of the three, compare the status in the setup window with System Settings (not asked, allowed, refused, removed). They must agree within a couple of seconds.
7. **Uninstall.** Follow the README's Uninstall section and check nothing is left running or in the places it lists.

## D. Send back

The notes columns, the answers to every **(unknown)**, and the last lines of `~/Library/Logs/Voice It/voice-it.log` (timings only; delete any words before sharing).
