# Security

## Security model

Oatmeal is **local-first by design**:

- **Audio capture** happens on your machine, driven by the local `mr-capture` helper.
- **Transcription** runs locally with [mlx-whisper]; the CLI transcribes from the local Hugging Face cache only (`HF_HUB_OFFLINE=1`).
- **Transcript storage** stays on your machine.

No part of the pipeline sends audio or transcripts to a cloud server or a remote LLM API. The only network use is the one-time download of the Whisper model (`mr doctor --fetch-model`).

## Where your data lives

Everything you record and transcribe is stored under `~/Meetings` (configurable via `out_root`) on your own machine:

```
~/Meetings/
├── recordings/<stamp>/mic.wav, system.wav, meta.json
└── transcripts/<stamp>.md
```

The repository does not contain — and should never commit — any recordings, transcripts, or personal data. Do not attach them to issues or pull requests.

## Code signing & permissions

- Release builds of `Oatmeal.app` and its embedded `mr-capture` helper are **Developer ID–signed, hardened-runtime, and notarized by Apple** (`packaging/sign_app.sh`, `packaging/notarize_app.sh`). `mr-capture` embeds usage descriptions for the two macOS TCC permissions it requires: **Microphone** and **System Audio Recording** (macOS 14.2+). You grant both the first time a capture starts.
- A local build from source (`packaging/make_dmg.sh` without `MR_SIGN=1`) is **adhoc-signed and not notarized** — that path exists for development only and is not what releases ship.
- If you run captures from the `Oatmeal` menu-bar app, the app is the responsible process for the TCC prompts.

You do not have to trust the binary: verify the signature and notarization yourself, and note that the source is in this repo (`capture/`) and can be rebuilt with `cd capture && ./build.sh`.

```sh
codesign -dv --verbose=4 /Applications/Oatmeal.app   # expect Authority=Developer ID Application … (HL2336X7UD)
spctl -a -vvv -t exec /Applications/Oatmeal.app      # expect accepted, source=Notarization Data
xcrun stapler validate /Applications/Oatmeal.app     # expect "The validate action worked!"
```

## Reporting a vulnerability

If you believe you have found a security vulnerability, please **do not open a public issue**. Instead:

- If this repository has GitHub's private vulnerability reporting enabled, use it (Security → "Report a vulnerability" on the repository page).
- Otherwise, email the maintainers directly with a description of the issue and, if possible, a reproduction.

We will acknowledge receipt and work with you on a fix before any public disclosure.

[mlx-whisper]: https://github.com/ml-explore/mlx-whisper
