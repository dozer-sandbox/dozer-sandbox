# Measurements

What each lifecycle step, image bake and disk operation actually costs, measured.

## Overview

> Every number below was measured on Apple silicon Macs (M1/M3, macOS 27), features 580–587.
> Numbers move with the chip, OS and how busy the Mac already is — see each source result for the
> exact machine and load.

### The lifecycle, one small guest vs two agents

Like for like: the same pinned images, median of 5 runs (feature 580).

| | small guest (Alpine) | Claude Code | pi |
|---|---:|---:|---:|
| cold start → working (agents: first screen) | 0.74 s | 1.46 s | 2.52 s* |
| pause / resume | ~1 ms / ~1 ms | ~2 ms / ~1 ms | ~2 ms / ~1 ms |
| sleep (snapshot, RAM kept) / wake | 0.40 s / 3 ms | 1.25 s / 6 ms | 1.14 s / 5 ms |
| hibernate (RAM returned) | 0.41 s | 1.16 s | 1.18 s |
| **back after hibernation, same process** | **0.29 s** | **0.57 s** | **0.56 s** |
| reattached terminal redrawn | 8–56 ms | ~25 ms | 11–36 ms |
| restore after the host app crashed | 0.3–0.7 s | 0.8–1.3 s | ~0.7 s |
| snapshot size, idle | 66 MiB | 150–236 MiB | 148–190 MiB |
| host memory per running sandbox, idle | — | ~660 MiB | ~490 MiB |
| host memory after a turn (simulated) | — | ~1,050–1,080 MiB | — |
| restore point | 2–3 ms stopped, ~54 ms running | same | same |

\* pi downloaded `fd` and `ripgrep` on its first launch, on every runtime, when these were measured.
Since 594 both are in the agent images (`fd-find`, linked as `fd`, and `ripgrep`), so pi finds them
and downloads nothing.

### Cold, baked, warm and hot starts (feature 584)

The same image spec measured four ways: **cold** (nothing cached — pull, flatten, bake), **baked**
(today's normal `start()` — the image is already cached), **warm** (a baked image whose bake also
ran the agent once, so its first launch has no first-run setup screens) and **hot** (a template
sandbox woken from hibernation — a **cloned**, not fresh, identity):

| kind | cold | baked | warm | hot (wake) |
|---|---:|---:|---:|---:|
| lab | 36.9 s | 0.44 s | — | 0.46 s |
| claude-code | 120.0 s | 1.08 s | 1.14 s | 0.92 s |
| pi | 119.5 s | 1.25 s | 1.22 s | 0.74 s |

Where a cold claude-code start's ~2 minutes goes: vminit pull + init disk 14.0 s, the pinned `node`
base pull 55.5 s, flatten to ext4 33.5 s, `npm install` 15.2 s, boot + clone + launch ~1 s. Once
baked, every later sandbox is an **APFS clone** of that one disk: 20 ms, not minutes.

### Scale: how many sandboxes fit (feature 582)

Measured on an M3 MacBook Air (24 GB, fanless) while its owner's other apps already held
~17 GB — so these are conservative:

| tier | how many on this Air | limited by |
|---|---:|---|
| **cold** (hibernated) | **~14,000** | disk — 100 built in 8.5 minutes, 0 errors, 10.66 GiB total |
| **hot, cold-booted** | 8–12 | RAM (215 MiB lab / 647 MiB claude-code each) |
| **hot, woken from hibernation** | 6 | RAM (1,273 MiB lab / ~2,340 MiB claude-code — mostly zero pages, which compress) |

Wake stays fast under load (redrawn screen ~0.5 s lab / ~0.95 s claude-code, flat from 1 to 12
running); 200 wake → work → hibernate cycles ran with 0 errors, no slowdown, and memory back to
baseline every time. A memory balloon (583) narrows the "hot, woken" line: a woken sandbox now
gives back what it does not use, roughly halving its held RAM (see the library guide's Sandbox
maintenance calls).

### Image lineage and disk maintenance (features 586–587)

With a shared base flattened once (33 s), further images bake in 15–16 s and share most of their
blocks with the base and each other:

| | before 587 (journal-less) | with the 587 journal (default, 16 MiB) |
|---|---|---|
| cold boot after a discarded hibernation | `e2fsck` helper VM, ~1,030 ms | journal replay, **~380 ms**, 15/15 `e2fsck -fn` clean |
| fsync-heavy work | baseline | ~1.7× slower (0.16 vs 0.09 ms/fsync) |
| metadata-heavy work (many small files + sync) | baseline | ~3× faster |

`fstrim` at the end of every bake shrank the claude-code image 14% and pi's 16%. Disk maintenance
on a stopped sandbox: `reclaim()` (punch out ext4's free blocks) ran 800 MiB → 0 in ~25 ms;
`rederive()` (re-share blocks rewritten with the image's own bytes) re-shared 147 MiB and dropped
200 MiB of garbage in 0.8 s, verified by `e2fsck -fn` before an atomic rename.

### Against the alternatives

Park to free RAM, then come back to Claude Code — the same image on each runtime, the same Mac,
median of 5 runs (feature 580's wake matrix; "same process" checked by PID, start time and kernel
boot ID):

| | cold start → first screen | park (RAM freed) | back → first screen | what survived |
|---|---:|---:|---:|---|
| **DozerKit** | 1.46 s | hibernate 1.16 s | **0.57 s** | **the same process, session and screen** (15/15) |
| Docker containers | 0.78 s | `docker stop` 0.12 s | 0.71 s | a restart; files only |
| Docker Sandboxes (`sbx`) | 5.12 s | `sbx stop` 5.31 s | 1.28 s | a restart; files only |
| Apple `container` CLI | 2.24 s | `container stop` 0.18 s | 2.01 s | a restart; files only |
| Fly.io Sprites (cloud) | create ~1 s | cold park | 3–20 s | TTY sessions don't survive a cold park |

Plain Docker cold-starts in about half the time and parks faster — the difference is what
survives, not raw speed: none of the alternatives came back to a live agent process in 36 runs
across three of them.

### Sources

The numbers come from the project's measurement runs (the wake matrix, the scaling probe, warm starts and
migration, the image-lineage probe) on an M3 with macOS 27. Their raw data stays with the development notes,
which are not part of this repository; `make test-vm`, `make test-vm-hardening` and `make test-vm-lineage`
re-measure the core numbers on your Mac.
