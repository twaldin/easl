# Releasing easl

A release is `easl-<version>.zip` holding `easl.app`, plus `gettext-0.24.tar.gz` (the source of GNU libintl, which easl links statically inside libghostty; the LGPL requires it) and `THIRD_PARTY_NOTICES.md`. Signed with a Developer ID Application certificate and notarized, it opens with a double-click; without the certificate it's ad-hoc signed and users clear the quarantine flag (README, Install).

- `scripts/bundle.sh release` builds and assembles the app, signed ad hoc.
- `scripts/notarize.sh <zip>` makes the distribution zip from it: builds the bundle into `.build/dist/easl.app`, signs it inside out with the Developer ID identity, the hardened runtime (`--options runtime`), `scripts/easl.entitlements` and a secure timestamp, checks it (`codesign --verify --deep --strict`, the runtime flag, no `get-task-allow`, the Developer ID authority and timestamp, a Python SDK import leaving the signature intact, `spctl`'s verdict before notarization), zips it with `ditto`, submits it with `notarytool submit --wait`, prints the notary log, staples the ticket, zips the stapled app, and checks that zip's copy with `codesign`, `stapler validate` and `spctl` (`source=Notarized Developer ID`). Credentials it checks before building (`notarytool history`). `scripts/notarize.sh --dry-run <zip>` does all of it that needs neither the certificate nor Apple: it signs ad hoc with the hardened runtime and stops before submitting.
- `.github/workflows/release.yml` runs `notarize.sh` on a `v*` tag when the signing secrets exist; without them it makes the ad-hoc zip and runs `notarize.sh --dry-run`, so the signing path stays tested. It fetches `gettext-0.24.tar.gz` from GNU (or Ghostty's identical copy) and fails unless its SHA-256 matches. It fails when the tag isn't `v` + `VERSION`. When the tag's release already exists (one made from a Mac), it publishes nothing but the libintl source and the notices. Run by hand (`gh workflow run release.yml`), it builds the same zip from `VERSION`, signed when the secrets exist, and keeps it as the run's artifact instead of publishing.

The version lives in `VERSION`, and its notes in `CHANGELOG.md`: a release's notes are its version's section (`scripts/release-notes.sh`), above GitHub's list of merged changes when an earlier release is published, so drop `(unreleased)` from the heading when you tag it. `scripts/bundle.sh` stamps it into Info.plist (`EASL_VERSION` overrides it), and `bun scripts/gen-clients.ts` writes it into the Python and TypeScript clients' manifests and the Claude Code plugin. To bump: edit `VERSION`, run `bun scripts/gen-clients.ts`, commit.

`bundle.sh` copies `LICENSE` and `THIRD_PARTY_NOTICES.md` into `Contents/Resources`. It also copies the app icon, `scripts/AppIcon.icns` (Info.plist `CFBundleIconFile`). The icon is drawn from the brand mark and rebuilt with the site's `bun scripts/app-icon.ts <out.icns>`, which renders each size of an `.iconset` and packs it with `iconutil`. When a package, `resources/` asset or the libghostty-spm xcframework changes, update the notices: the libghostty table follows the Ghostty commit the xcframework was built from (`ar -t` on its `libghostty.a` lists the C libraries; the fonts are the ones `src/font/embedded.zig` embeds), and the GNU libintl section's source links, checksum and relinking steps follow its gettext version, as do the tarball name and `GETTEXT_SHA256` in `release.yml`. The libintl section includes a written offer of its source, valid three years from each release.

## One-time setup

Once, by the Account Holder, after enrolling in the Apple Developer Program:

1. Note the Team ID (developer.apple.com › Account › Membership details).
2. Create the **Developer ID Application** certificate. Either:
   - Xcode › Settings › Accounts › + (your Apple ID) › your team › Manage Certificates… › + › Developer ID Application; or
   - Keychain Access › Certificate Assistant › Request a Certificate From a Certificate Authority… (your email, Saved to disk), then developer.apple.com › Certificates › + › Developer ID Application (G2 Sub-CA), upload the request, download the `.cer` and double-click it.

   Check: `security find-identity -v -p codesigning` lists `"Developer ID Application: <Name> (<TEAMID>)"`.
3. Create notary credentials: an app-specific password (account.apple.com › Sign-In and Security › App-Specific Passwords › +, named `easl-notary`). An App Store Connect API key works too (App Store Connect › Users and Access › Integrations › Team Keys › +, access Developer; the `.p8` downloads once).
4. Store them in the keychain as the profile `easl-notary`, which `notarize.sh` uses by default. It asks for the password:
   ```sh
   xcrun notarytool store-credentials easl-notary --apple-id <apple id email> --team-id <TEAMID>
   # or, the API key:
   xcrun notarytool store-credentials easl-notary --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <issuer id>
   ```
5. Export the certificate for CI: Keychain Access › login › My Certificates › "Developer ID Application: <Name> (<TEAMID>)" (its private key under it) › Export… › `Developer ID.p12`, with an export password.
6. Set the repository's secrets from the checkout. `gh secret set NAME` with no `--body` asks for the value without echoing it:
   ```sh
   base64 -i "Developer ID.p12" | gh secret set EASL_CERT_P12
   gh secret set EASL_CERT_PASSWORD            # the .p12 export password
   gh secret set EASL_NOTARY_APPLE_ID --body <apple id email>
   gh secret set EASL_NOTARY_PASSWORD          # the app-specific password
   gh secret set EASL_NOTARY_TEAM_ID --body <TEAMID>
   rm "Developer ID.p12"
   ```
   With an API key instead of the password, set `EASL_NOTARY_KEY` (`base64 -i AuthKey_<KEYID>.p8 | gh secret set EASL_NOTARY_KEY`), `EASL_NOTARY_KEY_ID` and `EASL_NOTARY_ISSUER` (the issuer id above the keys in App Store Connect). CI signs when `EASL_CERT_P12` and either `EASL_NOTARY_KEY` or `EASL_NOTARY_PASSWORD` exist, preferring the key; until then a tag publishes an ad-hoc zip.
7. Check it all without releasing: `scripts/notarize.sh /tmp/easl-test.zip` notarizes a build from this Mac (the first `codesign` asks for the key: Always Allow), and `gh workflow run release.yml` does the same in CI, its zip kept as the run's artifact.

## Release from this Mac

Bump `VERSION` first (above). `notarize.sh` builds into `.build/dist`, never `.build/easl.app` (a running dev instance's); `gh release create` makes the tag, and the Release workflow it starts leaves the release alone except for re-uploading the same libintl source and notices:

```sh
scripts/notarize.sh easl-0.1.0.zip
curl -fLO https://ftp.gnu.org/gnu/gettext/gettext-0.24.tar.gz
echo "c918503d593d70daf4844d175a13d816afacb667c06fba1ec9dcd5002c1518b7  gettext-0.24.tar.gz" | shasum -a 256 -c -
gh release create v0.1.0 easl-0.1.0.zip gettext-0.24.tar.gz THIRD_PARTY_NOTICES.md --title "easl 0.1.0" --notes-file <(scripts/release-notes.sh 0.1.0) --generate-notes
```

Drop `--generate-notes` while no earlier release is published (`gh release list --exclude-drafts --limit 1` lists none), as the Release workflow does.

`notarize.sh` signs with the keychain's only Developer ID Application identity (`EASL_SIGN_IDENTITY` picks one) and notarizes with the `easl-notary` profile (`EASL_NOTARY_PROFILE` names another; `EASL_NOTARY_KEY`, `_KEY_ID`, `_ISSUER` or `EASL_NOTARY_APPLE_ID`, `_PASSWORD`, `_TEAM_ID` pass credentials directly, as CI does). Notarization usually takes a few minutes. An Invalid submission fails with the notary log that says why. It ends with `spctl` saying `accepted` and `source=Notarized Developer ID`.

## Release from CI

With the secrets set (One-time setup, step 6), bump `VERSION`, then push a `v*` tag.

## After every release

- **Homebrew.** The Release workflow's last step updates the cask `easl` in [twaldin/homebrew-tap](https://github.com/twaldin/homebrew-tap) (`brew install --cask twaldin/tap/easl`). It downloads the release's zip (whoever published it), checks with `spctl` that it's notarized, writes `Casks/easl.rb` from `scripts/homebrew-cask.sh <version> <sha256>` and pushes it with the tap's write deploy key (the `HOMEBREW_TAP_DEPLOY_KEY` secret). A zip that isn't notarized leaves the tap alone with a warning: Homebrew quarantines what a cask downloads and doesn't support casks that fail Gatekeeper. To redo it by hand, from this checkout with the tap cloned at `<tap>`: `mkdir -p <tap>/Casks && scripts/homebrew-cask.sh 0.2.2 <sha256> > <tap>/Casks/easl.rb`, then commit and push in `<tap>`.
- **The installer's pins.** Every release, and every replaced zip (a notarized rebuild of the same version), also updates `curl -fsSL https://easl.sh/install | sh`: `RELEASE` in canvas-site `src/brand/brand.ts`, `sha256` included (`curl -fsSL <zip url> | shasum -a 256`), then republish easl.sh. The installer downloads the pinned version's zip and refuses one whose SHA-256 doesn't match, so until then it installs nothing.

## Hardened runtime

Notarization requires the hardened runtime on every executable. easl's bundle has one, `Contents/MacOS/Easl`: libghostty (with libintl), tree-sitter and its grammars, swift-markdown and the rest are linked in statically, and `otool -L` lists only system libraries. zmx, bun, git, Python and language servers are the user's own, run as subprocesses; `bin/`, `cli/` and `extensions/` in `Contents/Resources` are scripts (sealed as resources, run by sh or bun). `notarize.sh` still signs any other Mach-O file it finds before the app, and stops on a nested framework, XPC service or app, which would need signing as a bundle.

easl needs no runtime exception (`allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`, `allow-dyld-environment-variables`): it loads no code at runtime, WebKit's JIT runs in its own WebContent process, and the JavaScriptCore context behind `browser.eval` only parses. Subprocesses inherit no entitlements and aren't restricted by easl's runtime.

They do inherit TCC responsibility: macOS attributes a privacy request from anything in a terminal tile, or from a browser tile's page, to easl, and under the hardened runtime `tccd` won't ask the user unless easl has the matching entitlement. So `scripts/easl.entitlements` carries exactly three, each only letting macOS ask (the user still decides; `bundle.sh` writes the matching `NS…UsageDescription` into Info.plist):

| Entitlement | Why |
| --- | --- |
| `com.apple.security.automation.apple-events` | `osascript` and other AppleScript automation run by agents or users in a terminal tile |
| `com.apple.security.device.audio-input` | voice input in terminal programs (agent dictation, sox, whisper) and `getUserMedia` audio in browser tiles |
| `com.apple.security.device.camera` | the camera in terminal programs (imagesnap, ffmpeg) and `getUserMedia` video in browser tiles |

Contacts, calendars, photos and location are left out: a terminal program asking for them is refused without a prompt. Adding one is a key in the entitlements and a usage string in `bundle.sh`.

Try the hardened runtime without a certificate: `notarize.sh --dry-run` signs ad hoc the same way. Run that bundle as a separate instance (docs/testing.md):

```sh
EASL_BUNDLE_APP=/tmp/hr/easl.app scripts/notarize.sh --dry-run /tmp/hr/easl.zip
EASL_DEV_HOME=/tmp/hr/home EASL_DEV_APP=/tmp/hr/easl.app scripts/dev.sh start <root>
```

`codesign -dvv <pid>` shows `flags=0x10002(adhoc,runtime)` for the running instance. `log show --last 5m --predicate 'process == "tccd" AND eventMessage CONTAINS "hardened runtime"'` shows any privacy request refused for a missing entitlement. Expect two that need nothing: when a browser tile's website data store opens, Spotlight (`mds`) checks whether easl may see contacts and calendars (`kTCCServiceAddressBook`, `kTCCServiceCalendar`) and is refused without a prompt; pages load and work regardless.
