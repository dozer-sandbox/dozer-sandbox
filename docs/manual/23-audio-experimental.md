# Audio sandboxes (EXPERIMENTAL)

> **Not in public releases.** The releases on Homebrew and GitHub do not include audio sandboxes: `--audio`
> says so. This page describes a build from source with the experimental sound kernel (`make release PUBLIC=0`).
>
> **Experimental, and temporary in parts.** This lets a sandbox use your Mac's microphone and speakers. It is
> here to be tried, not relied on: the flag, the kernel and the `doz-sound` command may change or go away.

## Make one

```sh
doz create a1 --image lab --audio
doz start a1
doz exec a1 -- doz-sound test
```

`--audio` gives the sandbox a sound device: its microphone is the Mac's default input, its speakers the Mac's
default output. It works with any image — the lab, or the Debian- and Ubuntu-based agent images. Only a new
sandbox can have audio, and a sandbox keeps what it was created with. A sandbox made without `--audio` is
exactly as before.

An audio sandbox boots its own Linux kernel: the same one every sandbox uses, with sound support added. It ships
with doz (never downloaded), and `doz doctor` says whether this doz carries it. It is kata-containers' kernel
6.18.15-186 (kata 3.28.0: its config and patch, unchanged) with four options added — `CONFIG_SOUND`,
`CONFIG_SND`, `CONFIG_SND_VIRTIO`, `CONFIG_SND_PROC_FS` — and nothing else; its source is kata 3.28.0's kernel
build plus that list, kept with Dozer's source.

## Inside the sandbox

The tools layer ([The tools layer](19-the-tools-layer.md)) sets an audio sandbox up at every start and wake:
ALSA's tools (`aplay`, `arecord`), an `/etc/asound.conf` that makes the sound card ALSA's default (one program
at a time can play, and one can record — a second gets "Device or resource busy"), and a temporary `doz-sound`
command:

| command | does |
|---|---|
| `doz-sound info` | the sound card, its devices, the default, and which Mac app macOS asks about the microphone |
| `doz-sound test` | plays a quiet tone (under a second), records 3 seconds, says the level, plays it back |
| `doz-sound rec FILE [SECONDS]` | records a WAV file (5 seconds unless you say) |
| `doz-sound play FILE` | plays a WAV file |
| `doz-sound tone FILE` | writes a quiet test tone (a WAV, under a second) to play |

Any program that uses ALSA's default device works the same way.

## The microphone and macOS

macOS asks about the microphone for the **app that started doz** — Terminal, iTerm, your editor — not for doz
itself. The first recording shows macOS's question ("Terminal would like to access the microphone"); allow it
and record again. `doz doctor` names the app. To change your answer: System Settings › Privacy & Security ›
Microphone.

If a recording gets no sound, `doz-sound` stops within a few seconds and says so, rather than hang.

## Known limitations

- **Until macOS's microphone question is answered, Shut Down the sandbox — don't pause, sleep or hibernate it.**
  A recording that is waiting for that answer can make the virtual machine stop. Once the app is allowed (or
  denied), this no longer applies.
- **A sound that is playing or recording while the sandbox hibernates does not continue after the wake.** Start
  it again — `doz-sound` starts fresh every time, so it is not affected. Pausing and sleeping keep sound going.
- A recording starts with a quarter of a second of silence, and it can contain a few single-sample ticks.
- Sound takes a moment to reach the speakers: with the standard tools, three quarters of a second from playing
  a sound to hearing it back through the microphone.
- An audio sandbox wakes from hibernation a little more slowly (about 0.07 s).
