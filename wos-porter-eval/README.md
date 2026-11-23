# WoS Porter vs our ARM64 port: Tier 1-2 evaluation

23 Nov 2026 · Aswin Kalies

Online version: https://claude.ai/artifact/6yYezYDNj6NB6iUETGiWGH

## Summary

WoS Porter writes good code when there is a real bug to fix, but its output cannot be shipped as a Git for Windows package, and most of what it commits is noise.

- **Real bugs found:** in 3 of 8 packages, fixes our port did not have:
  - libffi: an upstream ARM64 assembly bug, plus a variadic-call ABI fix;
  - xz: hardware CRC32 silently disabled on MSYS;
  - util-linux: a root-cause libintl link fix where we used a recipe workaround.

  The fixes are small and in each project's own style. They could go upstream.
- **Output is not a package:** it edits upstream source and never touches the MSYS2 recipe (`PKGBUILD`). Every useful fix has to be carried into our recipes by hand.
- **Wrong target 3 times in 8:** zstd, pcre2 and libffi were built as native MSVC programs, which Git for Windows does not use. The 5 runs that chose MSYS2 could see this session's notes about our toolchain, so they probably overstate what the plugin does on its own.
- **Noise:** core code changes total 1–281 lines per package, but commits total 113–845 lines. Almost every run commits benchmarks and a ~180-line `ARM64-PORT.md`, and some edit README, CI or `config.guess` to no purpose.
- **Cost:** 17–62 minutes and 88,000–174,000 tokens of context per package. Four runs at once exhausted the 5-hour usage limit twice, so the run was stopped at 8 of 27 packages.

**Verdict:** use it as a bug-finding reviewer on single packages, with a human carrying the fixes into our recipes. It is not a substitute for our porting flow.

## Setup

WoS Porter v1.0.3 ran unmodified on 8 of the 27 Tier 1–2 packages, on the Snapdragon X Elite build machine, between 22 and 23 November.

- **Input:** for each package, a git repo holding exactly the source our port started from: upstream plus MSYS2 patches, at the same version, extracted by the MSYS2 recipe (`prep-sources.sh`).
- **Prompt:** "Port this project to Windows ARM64. It is the <package> package as shipped in the MSYS2 (usr/bin) layer of Git for Windows." No other hints.
- **Settings:**
  - `WOS_SKIP_OPTIMIZE=1`, so the NEON phase was skipped; our port did no NEON work either.
  - Opus 5.5. Six runs used the session's default effort; pcre2 and libffi used medium.
- **How it ran:** WoS Porter's own `wos-porter` agent, one per package, inside a Claude Code session.
  - Headless sessions with all permission prompts off were blocked by the safety check.
  - Because the agents ran in-session, they could see the session's memory notes. Those notes describe our aarch64 toolchain and the no-AI-trailer rule.
- **Coverage:** 8 packages finished: dash, less, zstd, xz, tar, pcre2, util-linux and libffi.
  - vim, mintty, winpty and git-flow were stopped partway when the account usage limit hit and are excluded.
  - The other 15 never started. The run was stopped on request once the pattern was clear.

**Caveat that matters most:** the MSYS2-vs-MSVC target choice, the commit identity and the absence of AI trailers were influenced by the session's memory notes. A user running the plugin cold would likely see more MSVC targeting and AI co-author trailers. The earlier evaluation saw the trailers.

## Results per package

WoS Porter beat our port on 3 packages, matched it on 1, and added nothing useful for Git for Windows on the other 4. "Core" counts lines changed in source and build files, leaving out its benchmarks, `ARM64-PORT.md`, README, CI and Visual Studio project files.

| Package | Target chosen | Core change (lines) | All committed (lines) | What it changed | Our port | Better |
| --- | --- | --- | --- | --- | --- | --- |
| libffi | MSVC, also cross-checked on MSYS | +281 / −65 | +845 / −206, 12 commits | Fixed Q3/Q4 vector loads in `win64_armasm.S` (offset 16 → 32); variadic float-struct (HFA) ABI fix shared with the MSYS path; 2 new tests; reported a GCC variadic-HFA miscompile in our toolchain | recipe cross arm + ABI patch; neither bug found | WoS |
| xz | MSYS | +10 / −2 | +211 / −2, 3 commits | `__CYGWIN__` added to the ARM64 CRC32 runtime-detection guards; `IsProcessorFeaturePresent` used; CRC32 3.7x faster | recipe only; hardware CRC32 silently off | WoS |
| util-linux | MSYS | +5 / −2 | +201 / −2, 4 commits | `LIBS="$LTLIBINTL"` fixes the libintl link at the cause; plus a `config.guess` case that does nothing for MSYS | recipe `pass_all` workaround, with a commit message that names the wrong cause | WoS |
| dash | MSYS | +2 / −2 | +338 / −2, 3 commits | `CC_FOR_BUILD=${CC_FOR_BUILD-$CC}` in `configure.ac` | recipe only, no source change | tie |
| less | MSYS (+ an MSVC build) | +29 / −4 | +415 / −6, 4 commits | real `make check` cross fix in `Makefile.in`; PATH fix in the test harness labelled "ARM64" although x64 needs it too; unneeded `Makefile.wng` change; CI rewritten, which renames existing checks | recipe only, +11 / −3 | ours |
| tar | MSYS | +3 | +204, 3 commits | only a `config.guess` case, which the run itself found is a no-op for MSYS; it could not revert the commit | recipe only | ours |
| zstd | MSVC | +10 / −6 | +835 / −6, 4 commits | MSVC ARM64 prefetch via `__prefetch()`, endian and 64-bit guards; 6 Visual Studio projects gain ARM64 configs; 2 CI jobs that never ran | recipe only, +34 | ours (wrong target) |
| pcre2 | MSVC | +1 / −1 | +113 / −1, 2 commits | `_M_ARM64` added to the JIT SIMD gate; MSYS2 builds pcre2 with the JIT off, as the run itself noted | recipe only | ours (wrong target) |

Test results were sound on every package. Where it ran a suite, it compared ARM64 with an x64 build and reported identical failures, for example tar 198/10/36 and util-linux 84/10/2/217.

## Code quality findings

The code it writes is small, idiomatic and usually correct. The problems are what it writes around that code, and where it targets it.

### What it did well

- **Minimal and in upstream style.** It added `_M_ARM64` next to `__aarch64__`, used `${CC_FOR_BUILD-$CC}` and `$LTLIBINTL`, and matched xz's tab-indented preprocessor style. None of its source fixes use an `#ifdef ARM64` workaround where a general fix exists.
- **Real root causes.** The libffi assembly fix is a clear upstream bug. `ldp q16, q17, [x1]` already loads bytes 0–31, so the third vector must come from `#32`, not `#16`:

  ```
  -	ldp	q18, q19, [x1, #16]
  +	ldp	q18, q19, [x1, #32]
  ```
- **Fixes come with tests.** libffi gained `va_hfa.c` and `hva_neon.c`, which fail before the fix.
- **Clear commit messages, one change per commit.** Each explains the cause, the fix and who is affected; dash's `CC_FOR_BUILD` commit could go upstream as is.
- **It checks against x64.** It ran the same suites on an x64 build and reported identical failures, rather than calling failures ARM64 bugs.
- **It is candid about its own dead ends.** tar and pcre2 both reported that their change does not help the MSYS2 package.

### What it did badly

- **Never produces the deliverable.** No `PKGBUILD` changes in any package, so nothing it does can be built by MSYS2 tooling or put in Git for Windows.
- **Inconsistent target.** 3 of 8 were MSVC builds; zstd's 835-line diff is mostly copied Visual Studio project boilerplate.
- **Noise commits in almost every repo.** Benchmarks (7 of 8) and a ~180-line `ARM64-PORT.md` (8 of 8), plus README edits (libffi) and CI rewrites (less, zstd) that would block an upstream review.
- **No-op changes.** A `config.guess` aarch64 Cygwin case in tar and util-linux does nothing for MSYS, and `autoreconf` overwrites the file anyway. tar's run found this but could not revert it.
- **Mislabelled commits.** less's test-harness PATH fix is tagged "ARM64:" although x64 needs it too. One less commit has no message body.
- **Robustness gaps in new code.** less's `with_path()` calls `malloc` without a NULL check. That is harmless here, because it runs just before `exec`, but upstream would ask for it.
- **Factual errors in reports.** The less run claimed plain `char` is unsigned on our target; `aarch64-pc-cygwin-gcc` does not define `__CHAR_UNSIGNED__`, so it is signed.
- **Inconsistent commit hygiene.** Signed-off-by appears in 5 of 8 packages, only where the session memory reminded it; zstd, pcre2 and libffi have none.

## Cost and reliability

Each package cost 17–62 minutes and roughly 2–4 million processed tokens, for core changes of 1–281 lines; the usage limit stopped the run twice.

| Package | Effort | Agent time (min) | Context at end (tokens) | Tool calls |
| --- | --- | --- | --- | --- |
| pcre2 | medium | 17 | 88,000 | 20 |
| dash | default | 32 | 104,000 | 26 |
| less | default | 39 | 116,000 | 36 |
| libffi | medium | 45 | 174,000 | 69 |
| zstd | default | 52 | 127,000 | 34 |
| xz | default | 22+ (interrupted once) | 136,000 | 32 |
| tar | default | 26+ (interrupted once) | 107,000 | 14 |
| util-linux | default | 62+ (interrupted once) | 118,000 | 7 |

Processed tokens are an estimate: each tool call re-sends the whole conversation so far. For the interrupted runs, only the time after resuming was recorded.

- **Usage limit:** four runs in parallel used up the account's 5-hour allowance in about 75 minutes on 22 November and again on 23 November. Each time, every run stopped until the reset.
- **Medium effort** gave the fastest run (pcre2) and the best one (libffi), so it did not cost quality here.
- **Safety:**
  - The zstd run's test step ran `rmdir /s /q` on a scratch folder it had not created, holding the xz run's baseline files.
  - The tar run tried `git reset --hard` to undo its own commit and was blocked by the permission check.
  - The runs left extra build folders beside the repos (`less-msvc-build`, `less-x64-build`, `less-bench-data`).
  - gettext artifacts stayed in xz's source tree, hidden through `.git/info/exclude` instead of deleted.
- **Unattended use:** the plugin needs a top-level session to run its sub-agents. Running that headless with all permission prompts off was blocked by the safety check, so an overnight batch needs supervision anyway.

## Fixes worth taking into our port

Five findings are worth acting on. Only the libffi assembly fix and the util-linux cause are verified so far; check the rest before acting.

- [ ] **libffi:** carry the variadic float-struct (HFA) fix (`c7b5f6e`) into `libffi/0001-aarch64-Cygwin-follow-the-Windows-ARM64-ABI.patch`, since that code is shared with our build. Send the `win64_armasm.S` Q3/Q4 fix (`32d1d61`) and both tests to libffi upstream.
- [ ] **GCC (PR 6661):** check the reported `aarch64-pc-cygwin-gcc` variadic HFA miscompile: structs over 16 bytes passed by value in x4–x6, and the x7/stack split. Repro in `C:\wos-eval\work\libffi-scratch\vahfa`.
- [ ] **xz:** add the CRC32 detection fix (`e18e5ff`) as a recipe patch and offer it upstream. Check whether xz upstream would rather avoid `<windows.h>` in liblzma.
- [ ] **util-linux:** replace our `pass_all` recipe workaround with `03a6252` (`LIBS="$LTLIBINTL"`). Our commit `71e110f31` names the wrong cause: the bundled libtool does recognise ARM64 import libraries.
- [ ] **Build flags:** the xz and dash runs showed `-O2` works for those packages with the current GCC, and xz roughly doubles in speed against our `-O0` build. This supports moving the userland to `-O2`.

The dash `CC_FOR_BUILD` fix is correct but our build does not need it; it could still go to dash upstream.

## Recommendations

Use WoS Porter as a reviewer that hunts for ARM64 bugs in one package at a time, not as the porting tool for MSYS2 packages.

### For us

1. Point it at packages with assembly, intrinsics, CPU-feature detection or ABI code (libffi, xz, zlib, openssl, gmp), where it found real bugs. Skip plain C tools; it adds only noise there.
2. Run one package at a time on medium effort, so a single run never exhausts the usage limit.
3. Treat its branch as a source of patches: keep the core commits, drop benchmarks, `ARM64-PORT.md`, README, CI and `config.guess` commits, then move the fix into our `PKGBUILD`.
4. Verify every claim before acting on it; one in eight reports had a factual error.

### For the plugin authors

1. Support GCC-based Windows targets (MinGW-w64, Cygwin/MSYS2) and package recipes (`PKGBUILD`), and ask which target is meant instead of guessing.
2. Make benchmarks, `ARM64-PORT.md`, README and CI changes opt-in.
3. Add a mode that only diagnoses and fixes, skipping the 8-phase pipeline for small changes.
4. Never delete files the run did not create; keep scratch state inside its own work folder.
5. Use the repo's git identity and add no AI trailers by default.

## Where everything is

| What | Where |
| --- | --- |
| WoS Porter's patch series per package (`<package>/*.patch`), run log, source-prep script | this folder, `wos-porter-eval/` on branch `wos-porter-tier1-2` of aswin-mcw/MSYS2-packages |
| Full work repos (branch `arm64-port` vs `main`) with build trees | `C:\wos-eval\work\<package>` on the build machine |
| Scratch: test logs, benchmark scripts, the libffi GCC repro | `C:\wos-eval\work\<package>-scratch` |
| Run log and evaluation notes | `C:\wos-eval\logs\status.txt`, `C:\wos-eval\logs\notes.md` |
| Our port of the same packages | https://github.com/Multicorewareinc/MSYS2-packages/tree/gfw-arm64-dllentry |
| Earlier WoS Porter evaluation (argv bug) | `C:\FileTransfer\WoS-Porter-Writeup-Aswin.docx` |

The patches are exactly what WoS Porter committed. It added no AI trailers in this run; the incomplete vim, mintty, winpty and git-flow runs are left out.
