# Concepts

The vocabulary the CLI, the Swift API and the docs all use — same words everywhere, on purpose.

## Overview

### Sandbox

One Linux VM with its own kernel and its own disk. A sandbox is named (`a-z 0-9 -`, 1–40
characters in the CLI), and lives in a **store**: ``StoreLayout`` describes what is on disk for
it, ``SandboxSpec`` describes how to make one, and ``Sandbox`` is the live actor that owns its VM.

### The lifecycle (owner ruling, 2026-09-25)

| action | what happens | RAM | time | back with |
|---|---|---|---|---|
| **Pause** (also **Suspend**) | VZ freezes the guest's CPUs | kept | ~1 ms | **Resume** (~1 ms) |
| **Sleep** | pause + save the VM's memory and device state to a snapshot file: crash-safe | kept | ~0.3–1.2 s | **Wake**: resume in place, delete the snapshot |
| **Hibernate** | sleep + stop the VM | **freed** | ~0.35–1.2 s | **Wake**: rebuild the identical VM, restore the snapshot, resume, re-sync the guest clock, re-mount the shares, delete the snapshot |
| **restore after a crash** | a Wake from a new process, when the app died without hibernating | — | ~0.3–1.3 s | — |
| **Shut Down** | a cold stop: running programs end, the disk is kept | freed | — | **Start** (also **Cold Boot**) |

Two more operations act on the disk rather than the running VM:

- **Reset to image** (CLI `reset`) discards the root disk: the next Start clones the prepared or
  baked disk fresh. Restore points and the agent's state disk survive it.
- **Delete** (CLI `rm`) removes everything the sandbox has on disk.

These are the exact names the CLI, the README and `CLAUDE.md` use; old API names
(`wakeFromDisk`/`stop`) are kept as deprecated forwarders and old persisted phases
still decode, but every new call site should use the table above. See ``Phase`` for the state
machine and ``LifecyclePlanner`` for how an operation becomes ordered steps.

### Image, base and lineage

No layered images and no Dockerfile: a digest-pinned OCI base is flattened to one ext4 file once
(a **base disk**), every image is an APFS clone of a base plus its bake steps (``ImageSpec``,
``BakeStep``, ``ImageBaker``), and every sandbox's root disk is an APFS clone of an image —
instant, and free of cost until the guest writes to it:

```
<store>/images/bases/<key>/root.ext4     an OCI base, flattened ONCE
<store>/images/<name>/<key>/root.ext4    an image: a clone of its base + the bake
<store>/sandboxes/<name>/rootfs.ext4     a sandbox: a clone of its image
```

Deleting or re-baking a base or an image never changes anything already cloned from it. The
built-in images are `lab` (Alpine + bash), `claude-code` and `pi` (``AgentImages``); a **custom
image** (``CustomImage``) is saved from a restore point.

### Session

A terminal program living in the sandbox — a shell, `claude`, `pi` — held by **deckhold** inside
the guest so it survives a sleep, a hibernation and a crash of the host app. You *attach*
(``SessionConnection``) to a session and *detach* from it (``DetachReason``); it keeps running
either way. See <doc:HowItWorks> for why this needs a guest-side holder at all.

### The host

One background `doz` process per user and store. It owns every running VM, each proxied
sandbox's egress proxy, and the metrics writer. It starts when needed and exits when idle: looking
(`ls`, `inspect`, …) never starts one.

### Network, keys and accounts

A sandbox has **no network card** by default: its only way out is a host-side proxy
(``EgressProxy``) that checks every connection against a ``NetworkPolicy`` (default deny, rules by
hostname / wildcard / CIDR / port, and for HTTP by method and path) and logs it. A credential
(``CredentialBinding``) is bound to hosts, held in a ``CredentialVault`` in the host process, and
never written to disk; the guest sees a placeholder and the proxy swaps in the real value only on
the way to a bound host. A credential the guest brings itself (a `/login`, a pasted key) is a
``ForeignCredential`` — allowed and flagged, or refused, by policy.

An **account** is a durable Anthropic credential a store holds on the sandbox's behalf: the Mac's
own Claude Code login (read-only), a `setup-token`, or an API key. See <doc:CLIReference> for the
`account` and `key policy` commands.

### Store and disk maintenance

``DiskAccounting`` measures what a stopped sandbox's disks actually cost (allocated, unique,
shared with the parent, garbage); ``MaintenanceAdvice`` says whether `reclaim` (punch out ext4's
free blocks) or `rederive` (rebuild the root disk sharing more with its image) is worth running.

### See also

- <doc:HowItWorks> — why each piece above is shaped the way it is.
- <doc:LibraryGuide> — the same concepts, from the Swift API.
- <doc:CLIReference> — the same concepts, from the command line.
