# How it works

A plain explanation of what actually runs on the Mac, and why each piece is there.

## Overview

```
Mac (host)                                   One sandbox = one small Linux VM
───────────                                  ───────────────────────────────────────────────
your app / the doz CLI                    kernel   vmlinux-6.18.15-186   ← one pinned file, shared by every sandbox
  └ DozerKit                       init fs  vminitd (Apple's guest agent, runs as PID 1)
      └ Containerization (Apple)             root     your image, as ONE ext4 disk  ← per image
          └ Virtualization.framework (VZ)    state    small ext4 for ~/.claude etc.  ← per sandbox
                                             share    a Mac folder over virtio-fs
                                             deckhold holds each terminal session inside the VM
```

The Mac talks to the guest over **vsock**. vminitd answers "run this command", "mount this", "set
the clock"; deckhold holds the terminals.

### Why there is a separate kernel

A container image has no kernel in it — it is only the user-space half of a Linux system, and
containers normally share the kernel of the machine they run on. A Mac has no Linux kernel to
share, so something must boot one. Apple's Containerization (what this library uses) gives **each
container its own tiny VM**, so each VM needs a kernel handed to it separately; the image only
supplies the disk that kernel boots into.

The kernel is the **Kata Containers** project's guest kernel (Linux 6.18.15, Kata build 186), the
same one Apple's own `container` CLI installs — `container system kernel set --recommended`
downloads the same release archive from GitHub, so "the Apple kernel" and this library's pin are
the same file. ``KernelProvider`` fetches it once, verifies the archive's and the kernel's own
sha256, and caches it (~10 ms to re-verify on every later start). A byte-identical copy already on
the Mac is copied instead of downloaded.

**Pinning is a correctness requirement, not tidiness:** a sleeping sandbox's snapshot contains the
running kernel's memory, so it must wake under exactly the same kernel. A kernel change is a
deliberate library release, and sandboxes asleep under the old kernel must be woken (or
cold-booted) first.

### We build disks, not layered images

Containerization reads OCI images only as **input**: it pulls the layers once and **flattens**
them into a single ext4 disk file, so there is no Dockerfile, no BuildKit and no `container build`
here — the library builds and caches **disks** (``ImageSpec``, ``ImageBaker``):

1. **Base:** pull the digest-pinned OCI image and flatten it to ext4, once (``BaseManifest``,
   ``BaseDisk``).
2. **Bake:** boot that disk, run the install steps inside the VM (``BakeStep``), run a
   credential-free check (``VerifyCheck``), shut down cleanly, and keep the result as a read-only
   baked disk (``BakedImage``, ``ImageManifest``) — keyed by base digest + steps + kernel +
   deckhold, so any change produces a new disk rather than editing the old one.
3. **Run:** each sandbox boots an **APFS clone** of the baked disk: instant, and it costs no space
   until the guest writes.

Credentials are never baked: a key is passed to one session when it starts, and is never written
to any disk.

### Pause, sleep, hibernate, wake

See the lifecycle table in <doc:Concepts>. The rules learned the hard way:

- **The snapshot is deleted on wake.** It holds memory, not the disk; once the guest runs again
  the disk moves on, and restoring old memory onto a newer disk would corrupt the guest's view of
  its files.
- **The VM must be rebuilt identically** to restore: same kernel, disks, machine identifier, CPUs
  and memory.
- **virtio-fs does not survive a stop:** after a wake the guest re-mounts every share, listing the
  fresh root first (a bind that skips the listing can pick up a stale dentry).
- **Stop resumes (or restores) a sleeping VM first**, then stops it normally — stopping it at the
  VZ level directly crashed the process (it leaves the package's vminitd clients unclosed).
- **A memory balloon returns what a woken guest does not use** (restoring a snapshot otherwise
  touches every page the Mac ever charged the VM for).

### Terminal sessions: deckhold

A command's terminal normally lives on the vsock connection from the Mac. vminitd holds the
terminal and drops it when that connection dies, and a stop kills every connection — so a program
attached that way would die on the first hibernate.

**deckhold** fixes that: a small static binary inside the guest that owns each session's terminal,
keeps a copy of the screen with headless **libghostty-vt**, and survives any disconnect. The Mac
side (``SessionConnection``) is a disposable client: it connects, says its window size, and gets a
rendered **snapshot** of the screen (scrollback, colours, cursor, modes) followed by live output
with no gap and no duplicates. Sessions are started **without** `sh -c` and with every signal reset
to default — BusyBox `sh -c` leaks an ignored SIGQUIT, which a program cannot trap.

### Lineage: base → image → sandbox, as APFS clones

```
<store>/images/bases/<key>/root.ext4 + manifest.json   an OCI base, flattened ONCE
<store>/images/<name>/<key>/root.ext4 + manifest.json  an image: a clone of its base + the bake
<store>/sandboxes/<name>/rootfs.ext4                    a sandbox: a clone of its image
```

Children never depend on their parent's file: deleting or re-baking a base or an image leaves
every image and sandbox cloned from it exactly as it was. ``DiskAccounting`` reads APFS's extent
map to report what each disk actually costs (allocated, unique, shared with its parent, garbage);
``MaintenanceAdvice`` (``ReclaimResult``, ``RederiveResult``) says whether it is worth punching out
ext4's free blocks or rebuilding a disk to re-share more with its image. See <doc:Measurements> for
the numbers this produced.

### Where things live (per store)

```
<store>/
  kernels/vmlinux-6.18.15-186        the pinned kernel (verified, cached)
  initfs.ext4                        vminitd's init filesystem (Apple's vminit image)
  images/bases/<key>/root.ext4       a flattened OCI base
  images/<name>/<key>/root.ext4      a baked agent disk + manifest.json
  sandboxes/<name>/rootfs.ext4       this sandbox's APFS clone
  sandboxes/<name>/bootlog.log       the guest serial console (kernel + vminitd)
  sandboxes/<name>/vm.state          the snapshot, only while asleep
```

### See also

- <doc:Concepts> for the vocabulary these mechanisms are named with.
- <doc:Measurements> for what all of this costs, measured.
