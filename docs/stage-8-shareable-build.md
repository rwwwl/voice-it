# Stage 8: shareable build (add-on to the brief)

This is an add-on to `docs/brief.md`. Don't start it until Stages 5 to 7 are finished and the owner says go. Everything in the main brief still applies unless this file says otherwise.

## Goal

Let a technically comfortable person download Dictate, open it, and have it set itself up, without the owner paying for an Apple Developer Program membership. After a one-time model download, the app runs fully offline, as it does today.

## What changes from the personal-use rules

| Topic | Personal brief | Stage 8 (shared build) |
| --- | --- | --- |
| Model files | Placed by a setup script on the owner's Mac | The app downloads them on first run, with the user's consent |
| Network | None at runtime | One explicit downloader is the only network code. When it finishes, offline mode is switched on for good |
| Signing | Owner's free Apple Development certificate | Ad hoc signature (no paid certificate). Users must approve the app in Gatekeeper |
| History | On by default | Off by default in shared builds, subject to the owner's decision |
| Permissions | Survive the owner's rebuilds | Reset for recipients on every update, because the signature changes. Document this |
| Hardware | The owner's Mac | Apple Silicon and a recent macOS, with a stated minimum memory |

## Constraints

- No paid membership: no Developer ID certificate and no notarisation. Never describe the app as notarised or "verified by Apple".
- Be honest with users. The README must say the app is unsigned by a trusted developer, why, and how to check the download.
- No `sudo`. No analytics, telemetry, crash reporting or auto-updater.
- Keep it small. Reuse the existing pill and menu for status. Add one setup window and nothing else new.

## Deliverables

1. A first-run setup window, including a move-to-Applications prompt.
2. A model downloader with verification.
3. A release script that builds, ad hoc signs and packages the app.
4. A README and install guide.
5. An up-to-date licences file and an About screen.
6. A requirements check at launch.
7. A test on a clean macOS user account.
8. A repository set up for both download and build-from-source visitors (see "GitHub readiness").

## First-run setup flow

Show the setup window on the first launch, and make it reopenable from the menu ("Setup…").

1. **Welcome:** one paragraph on what the app does, and a plain privacy statement: after setup, nothing leaves the Mac.
2. **Move to Applications:** if the app is not running from an Applications folder, offer to move it there and relaunch. Skip this step if it is already there. See the notes below.
3. **Requirements check:** Apple Silicon, macOS 15 or later, enough free disk space, and enough memory. If something fails, say exactly what and stop.
4. **Model download:** list each model with its size and total. A Download button starts it. Show progress with no pause button. If the connection drops, show a clear message and a Retry button, and resume where the download stopped.
5. **First-load compile:** the speech model is compiled for the Neural Engine on its first load (37 seconds on the owner's Mac). Show a message saying this will take a minute, once.
6. **Permissions:** Microphone, Input Monitoring and Accessibility, each with its current status and a button that opens the right System Settings pane. Detect the real status; don't assume.
7. **Try it:** show the hotkey and a practice text field, then finish.

**Move to Applications notes**

- Detect the app's own location at launch. If it is not in `/Applications` or `~/Applications`, offer "Move to Applications" and "Not now". Skip the step when it is already in place.
- Do this before asking for permissions. Permissions are tied to the app's identity and location, so granting them to a temporary copy can mean granting them again later.
- Apps downloaded from the internet can run from a temporary, read-only location until they are moved (macOS calls this app translocation). Check how this behaves in Xcode 26.3 on macOS 15 before relying on it, and copy the app instead of trying to rename it.
- `/Applications` may need the user's password on a standard account. Fall back to `~/Applications` if that is declined.
- After copying, relaunch from the new location, quit the old copy, and carry on at the next step. Leave the original download in place and say so, or remove it only with the user's agreement.
- Don't try to bypass Gatekeeper from inside the app.
- Also package the release as a `.dmg` with a drag-to-Applications arrangement if it is simple, so many people move it themselves before the first launch.

## Model downloader

- **Manifest:** a JSON file inside the app listing each model: name, source URL at a pinned revision, SHA-256 checksum, size, licence, and destination folder.
- **Verify before use:** check the SHA-256 of every file. A mismatch means delete the partial file and fail with a clear message.
- **Safe to interrupt:** downloads resume where they stopped, and a finished file is moved into place only when complete.
- **Disk check:** confirm there is enough free space, with some margin, before starting.
- **Network rule:** the downloader is the only code allowed to use the network. After a successful download, switch on the offline setting for the speech library and make the cleanup runtime load from the local folder only. Keep the existing no-network sandbox tests passing.
- **No identifiers:** send nothing about the user or machine.
- **Hosts:** use the models' original hosts at pinned revisions. Confirm which hosts and redirects are involved before writing any allow-list, and check that each model's licence allows downloading it this way.
- **Manual option:** document a folder where a user can place the model files by hand, for people who prefer to download them themselves.

## Packaging

- A script (for example `scripts/make-release.sh`) builds a Release build for Apple Silicon, signs it ad hoc, verifies the signature, and creates a `.zip` (and a `.dmg` if it's simple). It also writes the SHA-256 of each artefact to a text file.
- Don't put the models inside the app.
- Show the version number in the menu and the About window.
- Verify the exact `codesign` and packaging commands against current Apple documentation for Xcode 26.3. Don't assume.

## README and install guide

Write it for someone who has never seen the project. Include:

- What it is, and what it isn't.
- Requirements.
- Install: download, move to Applications, the first launch fails, then the Gatekeeper approval steps for macOS Sequoia (System Settings, Privacy & Security, "Open Anyway"). Verify these steps against current Apple documentation before writing them. An advanced alternative can be offered, clearly marked.
- First run: what the setup window does and why it needs to download several GB.
- Permissions: what each one is for.
- Privacy: after setup nothing leaves the Mac, and how a user can check that for themselves (for example by running it with the network off).
- How to check the download's SHA-256.
- Updating: permissions reset, and how to re-grant them.
- Uninstall: delete the app and its Application Support folder.
- Warning: not approved for regulated or confidential data. The user must make their own checks.

## GitHub readiness

The project will be published on GitHub, so it must work for two kinds of visitor: people who download a finished app, and people who build it themselves. Start with a private repository. Make it public only when the owner says so.

**Before anything is pushed**

- Scan the working files and the full git history for audio recordings, model files, files over 50 MB, personal details (username, home folder paths, machine details) and secrets. Report what you find and wait for approval. Don't rewrite history or push without the owner's say-so.
- The build output, release folder, models and recordings stay out of the repository. Check the `.gitignore` covers them.

**Download visitors**

- Publish each version as a GitHub release with a version tag. Attach the `.zip` (and the `.dmg` if it exists) and put the SHA-256 of each file in the release notes. Mark early versions as pre-releases.
- Release notes list what's new, the requirements (Apple Silicon, macOS 15 or later), known issues, and that permissions reset after an update.
- The README opens with a "Download" section: where to get the file, the Gatekeeper approval steps, screenshots of the setup window, and the privacy statement.
- Never commit built apps or installers to the repository itself.

**Build-from-source visitors**

- The README has a "Build" section with exact requirements (Xcode 26.3, macOS 15, Apple Silicon), the one-line build command, and the time to expect.
- Commit the file that records exact package versions, so a builder gets the same revisions that were tested.
- Put the bundle ID and signing team in one place, with instructions for building under a free Apple ID. A builder can't use the owner's.
- Explain how the models arrive: the app downloads them on first run, and the README says where they are stored.
- Provide a script that generates the synthetic test clips with `say`, and keep the sample cleanup transcripts, so the tests run without anyone's recordings.

**For both**

- The release script builds exactly what the README tells people to build. The About window shows the commit and version, so a download can be traced to its source.
- Include `LICENSE` (the owner chooses it), `THIRD_PARTY_LICENSES.md`, and a short privacy and security note saying what the app accesses, that nothing leaves the Mac after setup, and where to report a problem.
- Add a simple issue template that asks for the macOS version, the app version, and the timing lines from the log. The log must never include dictated text unless the owner has turned that debug option on.
- Optional later: a GitHub Actions workflow that builds on a macOS runner. Don't add it in this stage.

## Licences and attribution

- Update `THIRD_PARTY_LICENSES.md` for every library and model in the shared build.
- Show attributions in an About window, including the credit that Parakeet's licence requires and the licence for the cleanup model.
- Confirm the models are downloaded from their original sources and not redistributed by this project. If that changes, re-check each licence.
- The owner chooses a licence for the app's own code. Don't invent one.

## Privacy defaults for shared builds

- History off by default. Audio saving off. Text logging off. Timing logs on, without any text.
- Keep the password-field rule: no paste, no clipboard copy, no history or log entry.
- No analytics of any kind.

## Testing

Test as a stranger would.

1. **Clean account:** create a new standard macOS user account on the owner's Mac. Download the `.zip` through a browser so it is quarantined. Follow the README exactly. Write down every point of friction.
2. **Offline proof:** after setup, run the app with network access denied and confirm it still works.
3. **Interrupted download:** cut the connection mid-download and confirm it resumes.
4. **Corrupt file:** change one byte of a downloaded model and confirm it is rejected.
5. **Low disk:** confirm the check stops the download with a clear message.
6. **Update test:** install a newer build over an older one and document exactly what permissions reset.
7. **Permissions flow:** confirm the status shown in the setup window matches System Settings.

## Acceptance checks

- A stranger can go from the downloaded file to a working dictation by following only the README.
- A builder can clone the repository and build a working app by following only the README.
- No network access is possible after setup, proved by the sandbox tests.
- Every downloaded file is checked against a pinned checksum.
- No model or personal data is bundled in the app.
- The licences file and About window are complete.
- Nothing claims the app is notarised or Apple-verified.

## Out of scope

Notarisation, the Mac App Store, an auto-updater, an installer package, Intel Macs, older macOS versions, other platforms, telemetry, and any cloud feature.

## Decisions needed from the owner before starting

1. **Name and bundle ID for sharing.** The current ID contains a personal name. Changing it later makes permissions reset.
2. **Licence for the app's own code,** and whether to publish the source.
3. **Where to host releases** (for example GitHub Releases).
4. **A smaller cleanup model option** for Macs with little memory, or a stated minimum instead.
5. **History default for shared builds.** Recommended: off.

## Risks

- Gatekeeper friction will put some people off, and the approval steps may change in future macOS versions.
- Permissions reset on every update.
- A model host could change its files, URLs or terms. The pinned revisions and checksums limit this but don't remove it.
- Ad hoc signing behaviour can differ between macOS versions.
- Sharing creates a support burden that a personal tool doesn't have.

## How Claude Code should work on this stage

- Plan first, write the plan to `NOTES.md`, and stop for the owner's approval before building.
- Verify Apple's current Gatekeeper and signing behaviour from Apple's own documentation. Don't rely on memory.
- Build in small steps, commit after each, and stop at the end for the owner to run the clean-account test.
- Report what you couldn't test yourself, including anything that needs a second Mac.
