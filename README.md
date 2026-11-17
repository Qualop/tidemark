<p align="center">
  <img src="docs/hero-en.png" width="780" alt="Tidemark in the Codex composer, with the hover card open">
</p>

<h1 align="center">Tidemark</h1>

<p align="center">
  Your remaining Codex quota, right in the composer.<br>
  <a href="README.ko.md">한국어</a>
</p>

---

Tidemark puts two small bars, **5h** and **7d**, in the empty space of the Codex desktop app's composer. They show how much of your rate limit is left for the model you have selected. Hover over them and a card pours out of the bars with the macOS Genie effect, showing every provider's quota and when each window resets.

If you route Claude or other providers into Codex through OpenCodex, Tidemark follows the model picker. Choose `anthropic/claude-…` and the bars switch to your Claude limits; choose a GPT model and they switch back.

## Features

- **Follows the model picker.** Reads the selected model from the composer and shows the matching quota within about 0.1 s of a change.
- **Hover card.** All providers at once, each in its own colour, with reset countdowns. A filled dot marks the provider you are using. Blurred background, the macOS Genie effect in and out, light and dark mode.
- **Stays out of the way.** Clicks pass straight through. No Dock icon, no menu bar icon, no windows.
- **Light.** One process using about 11 MB of memory and under 1% of one CPU core while Codex is in front, and close to nothing otherwise. While Codex is closed, Tidemark only waits for it to launch.
- **Two languages.** English and Korean are separate builds, so each stays as small as possible.

## Requirements

| | |
|---|---|
| macOS | 14 Sonoma or later (Apple silicon and Intel) |
| Codex | The Codex / ChatGPT desktop app (bundle ID `com.openai.codex`), signed in |
| Optional | OpenCodex, for Claude and other provider quotas |

## Install

1. Download `Tidemark-<version>-en.zip` (or `-ko.zip` for Korean) from [Releases](../../releases).
2. Unzip it and move **Tidemark.app** to **Applications**.
3. Open it. Tidemark is not notarized, so macOS blocks the first launch. Go to **System Settings → Privacy & Security** and click **Open Anyway**, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Tidemark.app
   ```
4. Allow **Accessibility** access when asked (**System Settings → Privacy & Security → Accessibility**). Tidemark uses it to find the composer and read the model picker.

Tidemark adds itself to Login Items on first launch. You can turn that off in **System Settings → General → Login Items**.

> The app is ad-hoc signed, so after an update macOS may ask for Accessibility permission again. Remove the old entry and allow the new one.

## Where the numbers come from

| Quota | Source |
|---|---|
| GPT models | `https://chatgpt.com/backend-api/wham/usage`, the endpoint Codex itself uses. The access token is read from `~/.codex/auth.json` into memory and sent only to chatgpt.com. When OpenCodex is running, the hover card uses its cached quota for the active ChatGPT account. |
| Claude and other providers | `~/.opencodex/provider-account-quota-cache.json`, which OpenCodex keeps up to date. Read only. |
| Selected model | The composer's model picker, read through the Accessibility API. |

Tidemark never writes to Codex or OpenCodex files and sends nothing anywhere else. Its own files live in `~/Library/Application Support/Tidemark`.

## Configuration

Optional. Create `~/Library/Application Support/Tidemark/config.json` with any of these keys, then restart Tidemark.

| Key | Default | Meaning |
|---|---|---|
| `VisualScale` | `0.95` | Size of the bars |
| `HorizontalOffset` | `0` | Nudge left or right, in points |
| `BottomOffset` | `32` | Vertical position when the footer row can't be found |
| `TrackingIntervalMs` | `8` | Follow rate while the window moves or resizes |
| `UsageRefreshIntervalMs` | `60000` | How often GPT usage is fetched |

```json
{ "VisualScale": 1.0, "HorizontalOffset": -4 }
```

## Build from source

Requires Xcode or the Command Line Tools (Swift 5.9+).

```sh
git clone https://github.com/Qualop/tidemark.git
cd tidemark
Scripts/install.sh        # English, installs to ~/Applications
Scripts/install.sh ko     # Korean
```

`Scripts/build-release.sh` builds the universal release archives into `dist/`. `swift run TidemarkChecks` runs the quota parsing checks.

## Uninstall

```sh
Scripts/uninstall.sh
```

Or quit Tidemark (`pkill -x Tidemark`), delete the app, and remove `~/Library/Application Support/Tidemark`.

## How it stays light

- The composer is found with one Accessibility tree walk that stops as soon as it reaches it. After that, only a few attributes are read, batched into one request per element.
- Position is checked every 100 ms. The fast follow rate runs only while the window moves or the composer resizes.
- The pointer is watched only while Codex is frontmost. The hover card is built on first use, drawn as one bitmap plus a few Core Animation layers, and its memory is released when it disappears.
- The Genie effect warps the card's window in the WindowServer; each animation costs about 10 ms of CPU in Tidemark.

## Credits

The Genie animation comes from [GenieWarpMesh](https://github.com/usagimaru/GenieWarpMesh) by usagimaru (MIT), which uses the private `CGSSetWindowWarp` API.

## License

[MIT](LICENSE). Tidemark is not affiliated with OpenAI or Anthropic.
