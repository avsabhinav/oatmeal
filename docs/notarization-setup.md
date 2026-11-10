# Oatmeal — Apple Developer ID Credentials Setup (Notarization)

This page is a **start-to-finish walkthrough** for the human who prepares the
credentials that `packaging/make_dmg.sh` (with `MR_SIGN=1`) needs to produce a
**Developer ID–signed and notarized** `Oatmeal` DMG.

After finishing, your machine will have:

1. A **Developer ID Application certificate** (private key + certificate) in
   your **login keychain** on **this** machine, and
2. A working **`notarytool` keychain profile** that the packaging scripts use
   to submit the DMG to Apple's notary service.

Every major step ends with a **verification command** so you always know
whether the step worked before moving on.

> **Placeholders:** everywhere you see `ABCDE12345` (a 10-character Team ID)
> or `you@example.com`, substitute **your real values**. They are
> placeholders, not credentials.

> **This machine is the signing machine.** The private key of a Developer ID
> certificate never leaves the keychain of the machine that created it — so
> all signing and notarization in this repo must happen **on the machine you
> set up here**. The packaging scripts never ask for passwords: they read
> `DEVELOPER_ID_APP` and `NOTARY_PROFILE` from the environment and let the
> keychain do the rest.

---

## 1. Prerequisites

You need all of the following before starting:

- **An active Apple Developer Program membership** (paid, per year).
  **A free Apple ID cannot create Developer ID certificates, full stop** —
  the Xcode and developer.apple.com flows below will not offer the option to
  you if you are not in the paid program.
- **An Apple ID that is a member of that team**, with permission to manage
  certificates.
- **Xcode installed** (e.g. `/Applications/Xcode.app`). The certificate
  creation UI lives in Xcode, and `xcrun` shims (`notarytool`, `stapler`,
  `spctl`) are part of the Xcode toolchain.

**Verify you are on a workable machine:**

```sh
sw_vers                      # macOS 14+ — 27.0.1 (build 26A434) on this machine
xcodebuild -version          # Xcode is installed, e.g. Xcode 27.2
xcrun notarytool --version   # notarytool 1.1.3 — present via xcrun
```

**Verify your membership:** open
[developer.apple.com](https://developer.apple.com) → sign in with the Apple ID
→ **Membership / Account** should show an **active** paid membership and list
your **Team** (its 10-character Team ID, e.g. `ABCDE12345`, is visible in the
team details). The same team must appear under **Xcode → Settings → Accounts**
once the Apple ID is added (step 2).

> Note: on this machine `xcode-select -p` currently reports
> `/Library/Developer/CommandLineTools` rather than the full Xcode app. That
> is fine — `xcrun notarytool`, `xcrun stapler`, and `xcrun spctl` are shims
> that work either way, and Xcode's certificate UI works regardless.

---

## 2. Create the Developer ID Application certificate

### Recommended path: Xcode's UI (fewest steps)

1. Open **Xcode** → **Settings** (⌘,) → **Accounts**.
2. Add your Apple ID (bottom-left **+** → **Add Account…** → sign in with
   `you@example.com`).
3. Select the account, and under **Teams** make sure your team
   (e.g. `ABCDE12345`) is listed.
4. Click **Manage Certificates…** → bottom-left **+** → choose
   **"Developer ID Application"** → **Continue**.

Xcode generates the key pair on this machine and installs the certificate
into your **login keychain**. The **private key stays on this machine** —
that is why signing must happen here.

### Alternative: the developer.apple.com portal

Useful if you must create the certificate from another machine or from the
portal UI:

1. Go to **developer.apple.com** → **Certificates, Identifiers & Profiles** →
   **Certificates** → **+** → **Developer ID Application**.
2. On the machine where the key should live, open **Keychain Access** →
   **Certificate Assistant** → **Create a Certificate…** → name it (e.g.
   `oatmeal-dev-id`) → **Type: "Code Signing"** → **Identity: "Keychain
   Identity"** → **Create**. This generates the private key locally and
   exports a **certificate signing request** — a
   `oatmeal-dev-id.certSigningRequest` file in `~/Certificates/`. (Do not
   confuse it with a downloaded `.cer`: that is the *certificate* Apple issues
   later, which you double-click to import.)
3. Upload the **`.certSigningRequest`** on the portal's download screen.
4. Download the resulting **`.cer`** file and **double-click it** — it is
   installed into the login keychain alongside the private key.

### Verify the certificate is installed

```sh
security find-identity -v -p codesigning
```

You should now see a line like:

```
1) 3A2B1C... "Developer ID Application: Your Name (ABCDE12345)"
```

(On this machine the command currently prints `0 valid identities found` —
after step 2 it must not.) If the identity does **not** appear, the
certificate and its **private key must be in the SAME keychain**: open
**Keychain Access → My Certificates** and confirm the certificate **expands**
to show a private key underneath it. A certificate without its private key
cannot sign anything.

---

## 3. Read the identity string and Team ID

The packaging scripts consume two facts from step 2: the **full identity
string** (`DEVELOPER_ID_APP`) and the **Team ID** (`APPLE_TEAM_ID`).

The identity string is exactly what `security find-identity` printed, quotes
included:

```
Developer ID Application: Your Name (ABCDE12345)
```

The **Team ID** is the 10-character string inside the parentheses
(`ABCDE12345` above). It is the same Team ID shown in your Apple Developer
account (step 1) and in **Xcode → Settings → Accounts → your team**.

**Verify both are in hand:**

```sh
# Full identity string (copy it exactly, including the inner parentheses)
security find-identity -v -p codesigning

# Team ID: the 10 characters inside the parentheses of that line, e.g. ABCDE12345
```

---

## 4. Create an app-specific password

Why: `notarytool` must authenticate to Apple to submit your DMG, and it must
**not** be given your real Apple ID password. Accounts protected by two-factor
authentication (the norm) **require an app-specific password** for
non-interactive sign-in.

1. Go to **account.apple.com** → sign in → **Sign-In and Security** →
   **App-Specific Passwords**.
2. Create a new one with a name like `oatmeal-notary` → you get a
   one-time code like `xxxx-xxxx-xxxx-xxxx`.

**Verify:** you have the code written down and the account accepts it (the
next step proves it). App-specific passwords can be **revoked** from this same
page at any time — that is the escape hatch if one leaks (see step 6).

---

## 5. Store the notarytool keychain profile

Create the profile **on this machine**. `notarytool` stores the Apple ID and
app-specific password in your **login keychain** under the profile name —
the scripts only ever reference the **name**, never the secret:

```sh
xcrun notarytool store-credentials "oatmeal-notary" \
  --team-id "ABCDE12345" \
  --apple-id "you@example.com" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

- `oatmeal-notary` — the profile name. **It must match `NOTARY_PROFILE` in
  `packaging/signing.env`** (step 6). Rename both if you prefer another name.
- `ABCDE12345` — your Team ID (step 3).
- `xxxx-xxxx-xxxx-xxxx` — the app-specific password from step 4.

`store-credentials` authenticates to Apple immediately, so a success message
already proves the credentials work. Verify explicitly:

```sh
xcrun notarytool history --keychain-profile "oatmeal-notary"
```

**An empty history is a SUCCESS** — it only means you have not submitted
anything with this profile yet, but the credentials authenticated. An error
here means the password or Team ID was rejected; redo step 4/5.

---

## 6. Fill in `packaging/signing.env`

The repo ships a safe-to-commit template, [signing.env.example](../packaging/signing.env.example).
Copy it to the real file and fill in your values:

```sh
cp packaging/signing.env.example packaging/signing.env
```

`packaging/signing.env` (shell-sourceable, gitignored) then looks like:

```sh
# The full Developer ID signing identity string, exactly as printed by
# `security find-identity -v -p codesigning`:
export DEVELOPER_ID_APP="Developer ID Application: Your Name (ABCDE12345)"

# The 10-character Apple Developer Team ID:
export APPLE_TEAM_ID="ABCDE12345"

# The notarytool keychain profile name from step 5:
export NOTARY_PROFILE="oatmeal-notary"

# Opt-in toggle for the signing/notarization flow:
export MR_SIGN=1
```

What each variable is:

| Variable | Value | Consumed by |
| --- | --- | --- |
| `DEVELOPER_ID_APP` | The full identity string from step 3. | `packaging/sign_app.sh` (it reads `$DEVELOPER_ID_APP` and signs with it). |
| `APPLE_TEAM_ID` | Your 10-character Team ID. | Human reference / `store-credentials --team`. |
| `NOTARY_PROFILE` | The profile name from step 5 (`oatmeal-notary`). | `packaging/notarize_dmg.sh` (it reads `$NOTARY_PROFILE` and submits with it). |
| `MR_SIGN` | `1` = sign + notarize the build. | `packaging/make_dmg.sh`. |

> **Security:** `packaging/signing.env` is **gitignored and must never be
> committed**, and must **never be pasted into a ticket, chat, or screenshot**.
> The identity string and profile name are not secret, but the file is the one
> place all the pieces live together — treat the whole file as sensitive.
> The app-specific password it *references* (stored in the keychain, not the
> file) can be **revoked** from account.apple.com if you believe it leaked.

**Verify the file is sourced correctly:**

```sh
source packaging/signing.env
echo "$DEVELOPER_ID_APP $APPLE_TEAM_ID $NOTARY_PROFILE $MR_SIGN"
# expect: Developer ID Application: Your Name (ABCDE12345)  ABCDE12345  oatmeal-notary  1
```

---

## 7. Run the signed build

From the repo root, one command builds, signs, and notarizes:

```sh
MR_SIGN=1 ./packaging/make_dmg.sh
```

What you should see, in order:

1. **Build stage** — `capture/build.sh`, `packaging/freeze_cli.sh`, and
   `menu-bar/install.sh` run, producing `Oatmeal.app` with the embedded
   frozen CLI and `mr-capture` helper.
2. **Signing stage** — `==> Signing Oatmeal.app with Developer ID
   (packaging/sign_app.sh)`; the app is re-signed inside-out (leaf binaries →
   the `mr-cli` tree → the `.app` bundle, last) with the hardened runtime and
   Apple's `--timestamp`. Expect the identity from `DEVELOPER_ID_APP` to be
   used and a `codesign --verify --deep --strict` pass at the end.
3. **DMG stage** — `hdiutil` writes `dist/Oatmeal-0.1.1.dmg` (version comes
   from `pyproject.toml`) and opens a Finder drag window.
4. **Notarization stage** — `==> Notarizing ... (packaging/notarize_dmg.sh)`;
   `notarytool` submits the DMG with the `oatmeal-notary` profile, waits for
   Apple's verdict (up to 30 minutes), staples the ticket
   (`xcrun stapler staple`), validates it, and proves Gatekeeper accepts the
   image. On success it prints `NOTARIZE_OK:`.

   Note the **order**: the `.app` is notarized and stapled *before* the DMG is
   built, so the ticket lives inside the bundle and survives being dragged to
   `/Applications`. The DMG is then notarized and stapled as well.
5. **Final line** — `==> Mode: Developer ID signed; .app notarized + stapled
   BEFORE the DMG; DMG also notarized + stapled (MR_SIGN=1)`.

   Expect **three** Apple round trips in the log, not one: the `.app`
   submission (`notarize_app.sh`), the DMG submission
   (`notarize_dmg.sh`), and the app's staple+Gatekeeper check in between.

**How long does this take?** The app is **~1.4 GB across ~3000 files**, so
signing every Mach-O individually and letting Apple scan the image is **slow**:
expect signing to take a few minutes and **notarization to take several
minutes — and sometimes longer** (Apple's service queue). A failure at any
point aborts the build with a clear error; a notarization failure prints
Apple's detailed log. **Do not distribute a DMG whose build ended in an
error** — it may be signed but not notarized.

---

## 8. Verify the result

Run these from the repo root (the DMG path is `dist/Oatmeal-0.1.1.dmg` at the
current version):

```sh
# 1. The notarization ticket is stapled onto the image:
xcrun stapler validate dist/Oatmeal-0.1.1.dmg
# expect: valid staple on 'dist/Oatmeal-0.1.1.dmg'

# 2. Gatekeeper accepts the image (primary-signature context):
xcrun spctl -a -t open --context context:primary-signature -v dist/Oatmeal-0.1.1.dmg
# expect: dist/Oatmeal-0.1.1.dmg = accepted

# 3. The app INSIDE the image is Developer ID signed. Mount read-only,
#    inspect, detach (in that order — always detach afterwards):
MOUNT="$(hdiutil attach dist/Oatmeal-0.1.1.dmg -readonly -nobrowse | tail -1 | awk -F'-> ' '{print $2}')"
codesign -dv --verbose=4 "$MOUNT/Oatmeal.app" 2>&1 | grep -E 'Authority|TeamIdentifier|flags'
hdiutil detach "$MOUNT"
# expect: Authority=Developer ID Application: Your Name (ABCDE12345)
#         TeamIdentifier=ABCDE12345
#         flags=0x10000(runtime)      ← the hardened runtime is set
```

**Optional — publish:** `packaging/publish_release.sh` re-runs the staple /
Gatekeeper / Developer-ID checks above and, if all pass, **replaces the DMG
asset on the existing GitHub release** (tag `v0.1.1` by default). It refuses
to run if any check fails and never creates a new tag or release.

---

## 9. Troubleshooting

### `0 valid identities found`

```
$ security find-identity -v -p codesigning
0 valid identities found
```

The certificate (or its private key) is not in the **login** keychain. Redo
step 2, then in **Keychain Access → My Certificates** confirm the
"Developer ID Application …" certificate **expands to a private key**. If it
does not expand, the certificate was imported without its key — delete it and
recreate it (the key cannot be imported later; it only exists on the machine
that generated the pair).

### Identity appears but signing fails with "no identity found"

The identity is in a *different* keychain than the one `codesign` searches
(e.g. the System keychain, or a login keychain that is not the active one).
Move the certificate (with its key) into the **login** keychain, or re-run
with the keychain unlocked:

```sh
security find-identity -v -p codesigning          # must list the identity
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

Also make sure the certificate is **not expired**: `security
find-identity -v -p codesigning` only lists valid ones — if it was valid at
creation time and is now absent, it has likely expired (Developer ID
certificates are valid for **two years**; create a new one and re-run
step 5's profile if you switched teams).

### Notarization status `Invalid`

`notarize_dmg.sh` prints the full JSON result and then the detailed Apple log.
Fetch and read it yourself if you need it:

```sh
xcrun notarytool log <id> --keychain-profile "oatmeal-notary"
# <id> is the submission id from the `xcrun notarytool submit ...` output
```

The log lists each rejected file and the **reason** (e.g. missing signature on
a nested binary, unapproved entitlement, library-validation failure). Fix the
named file / entitlement and **re-run the whole build** — partial re-signs of a
half-built app are not a thing here; `MR_SIGN=1 ./packaging/make_dmg.sh` is
idempotent.

### Hardened runtime breaks the bundled Python/JIT payload

The frozen `mr-cli` tree is CPython running MLX code; it needs JIT and
writable+executable memory. Those two entitlements are **already `true`** in
[app.entitlements](../packaging/entitlements/app.entitlements)
(`com.apple.security.cs.allow-jit`,
`com.apple.security.cs.allow-unsigned-executable-memory`). The third key,
`com.apple.security.cs.disable-library-validation`, is an **escalation slot
deliberately set to `<false/>`**. If notarization (or runtime loading of the
bundled `.so`/`.dylib` payloads) is rejected by **library validation** — the
log will say the library was rejected because it is not signed by an approved
authority — the fix is to flip that key to `<true/>` in
[app.entitlements](../packaging/entitlements/app.entitlements) and re-run
`MR_SIGN=1 ./packaging/make_dmg.sh`. Prefer fixing the dylib signatures
instead of leaving it `true`, per the file's own comment.

### `xcrun stapler version` exits 64

**Do not use `xcrun stapler version` as a health check** — stapler has **no
`version` subcommand**; it prints usage and exits **64**, which looks like a
broken install but is a perfectly healthy machine. The correct probe is
`xcrun -f stapler`, which locates the tool without running it (this is exactly
what `packaging/notarize_dmg.sh` does).

### Clock / certificate-expiry issues

Signing uses Apple's time-stamping service (`--timestamp`); a machine clock
far off from real time can make the signature's timestamp suspicious. Sync the
clock first (`systemsetup` or Network Time Protocol), then re-run. And
remember: a Developer ID certificate that has **expired** is simply absent
from `security find-identity -v -p codesigning` — you will see `0 valid
identities found` even though the (expired) certificate is still in
Keychain Access. Create a fresh certificate (step 2); the keychain profile
from step 5 does **not** need to change unless the Team ID changed.

---

## Checklist

Tick each as you go; all boxes checked = a notarized DMG is one command away.

- [ ] Active (paid) Apple Developer Program membership, and your Apple ID is a
      member of the team (step 1).
- [ ] Xcode installed; `xcrun notarytool --version` prints a version (step 1).
- [ ] Developer ID Application certificate created (Xcode or portal, step 2);
      private key visible under the certificate in Keychain Access → My
      Certificates.
- [ ] `security find-identity -v -p codesigning` lists
      `"Developer ID Application: Your Name (ABCDE12345)"` (steps 2–3).
- [ ] Team ID (the 10 characters in the parentheses) noted (step 3).
- [ ] App-specific password created at account.apple.com (step 4).
- [ ] `xcrun notarytool store-credentials "oatmeal-notary" --team
      "ABCDE12345" --apple-id ... --password ...` succeeded (step 5).
- [ ] `xcrun notarytool history --keychain-profile "oatmeal-notary"` ran
      without an auth error (empty history is fine) (step 5).
- [ ] `packaging/signing.env` created from the example; `DEVELOPER_ID_APP`,
      `APPLE_TEAM_ID`, `NOTARY_PROFILE`, `MR_SIGN=1` filled in; file is
      **not** committed and not pasted anywhere (step 6).
- [ ] `MR_SIGN=1 ./packaging/make_dmg.sh` finished with
      `Mode: Developer ID signed + notarized + stapled` (step 7).
- [ ] `xcrun stapler validate dist/Oatmeal-0.1.1.dmg` says **valid staple**
      (step 8).
- [ ] `xcrun spctl -a -t open --context context:primary-signature -v
      dist/Oatmeal-0.1.1.dmg` says **accepted** (step 8).
- [ ] Mounted app shows `Authority=Developer ID Application` and
      `flags=0x10000(runtime)` (step 8).
