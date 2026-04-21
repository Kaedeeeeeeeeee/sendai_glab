# plateau-pipeline - Install Guide (Phase 0)

> **Scope**: this file tells you how to install the three command-line
> tools that `convert.sh` orchestrates, on **macOS Apple Silicon**
> (the project's primary development platform). Intel Mac and Linux
> users should still find most steps usable; deviations are called out
> in line.

The Phase 0 pipeline converts Japan PLATEAU 3D city-model CityGML into a
Xcode-compatible `.usdz`:

```
input/*.gml                               (PLATEAU CityGML 2.0)
  -> nusamai  (plateau-gis-converter)     [Rust CLI,   REQUIRED]
  -> *.glb    (glTF binary)
  -> blender  --background --python       [Blender 4.x REQUIRED]
  -> *.glb    (simplified)
  -> usdzconvert                          [Apple CLI,  optional]
  -> Resources/Environment/*.usdz
```

If `usdzconvert` is not installed, `convert.sh` still produces an
intermediate `.glb` next to the target path and asks you to drop it
into **Reality Converter.app** manually. That fallback is fine for
Phase 0; automating it is a Phase 1 task.

---

## 0. Prerequisites

- macOS 14 or later (Sonoma+). macOS 15 (Sequoia) recommended for
  smoother Metal perf when reviewing `.usdz` in Reality Converter.
- Xcode Command Line Tools:
  ```bash
  xcode-select --install
  ```
- Homebrew (optional but recommended):
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```
- Python 3.9+ on `PATH` (macOS 14 ships Python 3.9; `brew install python`
  to get a newer interpreter).
- About **2-4 GB** free disk for the tools themselves plus **tens of
  GB** per Sendai PLATEAU tile you download.

Verify:

```bash
clang --version
python3 --version
which brew    # optional
```

---

## 1. nusamai (plateau-gis-converter CLI)

The Rust CLI is the core of the pipeline. It is the same binary that
powers the PLATEAU GIS Converter GUI app.

### 1a. Download a pre-built binary (recommended)

1. Go to the MIERUNE release page (this is the active upstream; the
   Project-PLATEAU mirror lags slightly):
   - <https://github.com/MIERUNE/plateau-gis-converter/releases>
   - Fallback: <https://github.com/Project-PLATEAU/PLATEAU-GIS-Converter/releases>
2. Pick the asset matching your OS/arch:

   | OS / CPU                     | Asset pattern                                         |
   | ---------------------------- | ----------------------------------------------------- |
   | macOS Apple Silicon (M1/M2+) | `nusamai-<VER>-aarch64-apple-darwin.tar.gz`           |
   | macOS Intel                  | `nusamai-<VER>-x86_64-apple-darwin.tar.gz` (if built) |
   | Linux x86_64                 | `nusamai-<VER>-x86_64-unknown-linux-gnu.tar.gz`       |

3. Unpack, clear macOS quarantine, install to `/usr/local/bin`:

   ```bash
   cd ~/Downloads
   tar -xzf nusamai-*-aarch64-apple-darwin.tar.gz
   cd nusamai-*-aarch64-apple-darwin/
   xattr -d com.apple.quarantine nusamai || true   # Gatekeeper release
   sudo install -m 755 nusamai /usr/local/bin/nusamai
   ```

   If you prefer a user-local install that does not need `sudo`:

   ```bash
   install -m 755 nusamai "$HOME/.local/bin/nusamai"
   # make sure $HOME/.local/bin is on PATH in your shell rc
   ```

4. Sanity-check:

   ```bash
   nusamai --help
   ```

   You should see a clap-based help banner listing `--sink`, `--output`,
   `-t`, etc.

### 1b. Build from source (only if no prebuilt fits)

```bash
brew install rust
git clone https://github.com/MIERUNE/plateau-gis-converter.git
cd plateau-gis-converter/nusamai
cargo build --release
sudo install -m 755 target/release/nusamai /usr/local/bin/nusamai
```

### 1c. Environment override

If you need to keep several versions around, point the pipeline at a
specific copy:

```bash
export NUSAMAI_PATH="$HOME/tools/nusamai-0.1.12/nusamai"
```

---

## 2. Blender 4.0+

Blender runs our Python batch step (`blender_toon.py`). Any 4.x release
with the default `io_scene_gltf2` addon enabled works. Blender 4.2 LTS
is the recommended target because it is the LTS line active through
2026.

### 2a. Homebrew cask (easiest)

```bash
brew install --cask blender
```

The app ends up at `/Applications/Blender.app`. The pipeline script
auto-detects `/Applications/Blender.app/Contents/MacOS/Blender` if
`blender` is not in `PATH`.

### 2b. Manual download

1. <https://www.blender.org/download/>
2. Download the macOS Apple Silicon `.dmg` (4.2 LTS or newer).
3. Drag **Blender.app** into `/Applications`.
4. First-launch dialog: click through the "downloaded from internet"
   warning. To pre-clear it:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Blender.app
   ```

### 2c. Expose the CLI

Homebrew casks typically add a `blender` shim to `PATH`. If yours does
not, either:

```bash
# Option A: symlink
sudo ln -s /Applications/Blender.app/Contents/MacOS/Blender /usr/local/bin/blender

# Option B: environment variable (preferred for CI)
export BLENDER_PATH="/Applications/Blender.app/Contents/MacOS/Blender"
```

Persist the variable by adding it to `~/.zshrc` (or `~/.bashrc`):

```bash
echo 'export BLENDER_PATH="/Applications/Blender.app/Contents/MacOS/Blender"' >> ~/.zshrc
```

### 2d. Verify

```bash
"$BLENDER_PATH" --version
# Blender 4.2.x
"$BLENDER_PATH" --background --python-expr "import bpy; print(bpy.app.version_string)"
```

---

## 3. usdzconvert (optional but strongly recommended)

Apple's `usdzconvert` is a Python-based CLI that wraps USD's `usdcat`
and related tools. It is distributed as part of Apple's **USDPython**
tools bundle alongside **Reality Converter.app**.

### 3a. Install

1. <https://developer.apple.com/augmented-reality/tools/> - sign in and
   grab **Reality Converter** (macOS App) plus the **USDPython** DMG.
   Apple gates this page behind a free developer account.
2. Mount the USDPython DMG. Inside you will find a `usdzconvert`
   directory with a shell wrapper plus `Python` and `USD` runtimes.
3. Recommended install:

   ```bash
   sudo cp -R /Volumes/USDPython/usdpython /usr/local/
   echo 'export PATH="/usr/local/usdpython:$PATH"' >> ~/.zshrc
   echo 'export PYTHONPATH="/usr/local/usdpython/USD/lib/python:$PYTHONPATH"' >> ~/.zshrc
   exec zsh
   ```

4. Gatekeeper may flag the bundled binaries. Release them with:

   ```bash
   sudo xattr -dr com.apple.quarantine /usr/local/usdpython
   ```

5. Sanity-check:

   ```bash
   usdzconvert --help
   ```

### 3b. If you skip it

`convert.sh` degrades gracefully. The script drops a `.glb` next to the
intended USDZ path and prints instructions:

> Open Reality Converter -> drag the `.glb` in -> File -> Export as
> `.usdz` -> overwrite the target path.

### 3c. Environment override

```bash
export USDZCONVERT_PATH="/usr/local/usdpython/usdzconvert/usdzconvert"
```

---

## 4. macOS Gatekeeper recap

Any third-party binary downloaded outside the App Store gets the
`com.apple.quarantine` xattr. Running it without releasing triggers a
"cannot verify developer" dialog that breaks headless invocation from
`convert.sh`. To release:

```bash
# One file
xattr -d com.apple.quarantine /path/to/binary

# Whole app bundle (recursive)
sudo xattr -dr com.apple.quarantine /Applications/Blender.app
sudo xattr -dr com.apple.quarantine /usr/local/usdpython
```

Re-run `xattr -p com.apple.quarantine /path/to/binary` afterwards - it
should print nothing (the attribute is gone).

---

## 5. Environment variables recap

The pipeline respects these overrides. None are required if the
corresponding tools live in `PATH`.

| Variable                        | Meaning                                               |
| ------------------------------- | ----------------------------------------------------- |
| `NUSAMAI_PATH`                  | Absolute path to `nusamai` binary.                    |
| `BLENDER_PATH`                  | Absolute path to `blender` executable.                |
| `USDZCONVERT_PATH`              | Absolute path to the `usdzconvert` script.            |
| `PLATEAU_PIPELINE_KEEP_TMP=1`   | Keep the per-run `mktemp -d` workspace for debugging. |

Drop them into `~/.zshrc` or a project-local `.envrc` (if you use
[direnv](https://direnv.net/)):

```bash
# ~/.zshrc - one-time
export BLENDER_PATH="/Applications/Blender.app/Contents/MacOS/Blender"
export NUSAMAI_PATH="/usr/local/bin/nusamai"
export USDZCONVERT_PATH="/usr/local/usdpython/usdzconvert/usdzconvert"
```

---

## 6. End-to-end example

Assumptions:

- You are in `Tools/plateau-pipeline/` inside the SDG-Lab repo.
- You downloaded the Sendai 2024 PLATEAU dataset from
  <https://www.geospatial.jp/ckan/dataset/plateau-04100-sendai-shi-2024>
  and copied `Sendai_Tsuchitoi.gml` (a representative tile around
  東北学院大学 土樋キャンパス) into `input/`.
- All three tools above are installed.

Run:

```bash
cd /path/to/sendai_glab/Tools/plateau-pipeline
./convert.sh \
    --input  input/Sendai_Tsuchitoi.gml \
    --output ../../Resources/Environment/Tsuchitoi.usdz \
    --lod    2
```

Expected result:

1. `[info] stage 1/3: nusamai -> /tmp/sdglab-plateau.XXXX/stage1_raw.glb`
   - nusamai streams CityGML, converts to glTF; typical wall time for
     one LOD2 tile: 10-60 s.
2. `[info] stage 2/3: blender --background blender_toon.py`
   - Blender boots headless, imports the `.glb`, applies a 0.5 decimate
     to every mesh, exports a new `.glb`. Typical wall time: 20-120 s.
3. `[info] stage 3/3: glb -> usdz`
   - If `usdzconvert` is installed: direct conversion, 5-30 s.
   - Otherwise: the intermediate `.glb` is copied next to the target
     path and you get a manual-step warning.
4. Final output: `Resources/Environment/Tsuchitoi.usdz`
   - Git LFS-tracked; commit it separately from code changes.

Open it in **Xcode** (Project Navigator) or **Reality Composer Pro**:
you should see the Tsuchitoi buildings, untextured Toon materials
pending (Phase 1 P1-T10 will fill those in).

---

## 7. Troubleshooting

- **`nusamai: command not found`** - either install to `/usr/local/bin`
  or set `NUSAMAI_PATH`. `convert.sh` points you at the release page.
- **`blender: command not found`** - set `BLENDER_PATH` explicitly or
  `ln -s` the binary into `/usr/local/bin`.
- **"cannot be opened because the developer cannot be verified"** -
  see section 4 above (clear quarantine xattr).
- **`nusamai` exits immediately with "no features"** - you likely
  passed a non-CityGML XML or the wrong `bldg`/`dem` file; PLATEAU
  archives ship multiple feature types, try `udx/bldg/*.gml`.
- **Blender import fails on a huge tile** - try lowering `--lod` to
  `1`, or split the dataset into smaller geographic tiles before
  running.
- **Reality Converter says "couldn't import glb"** - usually a
  malformed texture path. Re-run the pipeline with
  `PLATEAU_PIPELINE_KEEP_TMP=1` and inspect the `.glb` in Blender
  GUI first.

---

## 8. Next steps

- Phase 0: one-tile smoke test documented here.
- Phase 1 (P1-T10 - Toon pipeline): `blender_toon.py` grows a real
  shader swap (cel-shaded ramp + outline), materials stop being
  pass-through, `lod_config.json` gains ramp / outline parameters.
- Phase 2 (P2-T??): batch multiple tiles in a single invocation, wire
  into CI so the `.usdz` artefacts are regenerated when source data
  updates (though this runs off-CI because the CityGML source is too
  large to fetch on every build).
