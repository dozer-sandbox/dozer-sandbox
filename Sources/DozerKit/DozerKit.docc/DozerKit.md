# ``DozerKit``

Instant, persistent and resumable Linux sandboxes for your agents, on your own Mac.

## Overview

Each *Dozer sandbox* is a full Linux computer with its own VM, its own kernel and a real disk. It
pauses in about a millisecond. It sleeps, or hibernates and gives your RAM back, then wakes, with
Claude Code back in well under a second: the same process, the same conversation, the same screen,
even after your app crashes. It has no network card, only a proxy you control, and your API keys
never enter it. Keep it as long as you like, throw it away in a click, or fork it into as many
copies as you need.

| | |
|---|---|
| **Instant** | pauses in ~1 ms; every sandbox is an instant copy-on-write clone of its image |
| **Persistent** | a real disk: install once and it is there after every sleep, shut-down and start |
| **Resumable** | an agent back from hibernation in under a second, same process, same conversation |
| **Crash-proof** | restores after the host app dies, every process at the same PID |
| **Attachable** | terminal sessions live inside it; attach from anywhere, at any size |
| **Forkable** | restore points in milliseconds; revert, fork, or save one as an image |
| **Private** | no network card; deny by default; keys never enter the sandbox; every connection logged |
| **Yours** | local, embeddable, no daemon, no account, free |

`DozerKit` is the Swift library, built on Apple's [Containerization][containerization]
framework. The `doz` command-line tool (see <doc:CLIReference>) is built on the library and
does not need to be — the library never depends on it.

[containerization]: https://github.com/apple/containerization

Requirements: **Apple silicon, macOS 26 or later.** It is built on Virtualization.framework and
vmnet, which have no Linux equivalent, so there is no Linux build.

### The lifecycle

The vocabulary is the same whether you drive a sandbox through the Swift API or the CLI:

| action | what happens | RAM | back with |
|---|---|---|---|
| **Pause** (also **Suspend**) | the VM's CPUs freeze | kept | **Resume** |
| **Sleep** | pause + a snapshot on disk: crash-safe | kept | **Wake** |
| **Hibernate** | snapshot, then the VM stops | **freed** | **Wake**, in under a second |
| **Shut Down** | a cold stop: programs end, the disk is kept | freed | **Start** (also **Cold Boot**) |

See <doc:Concepts> for the full vocabulary (images, sessions, network, keys and accounts) and
<doc:HowItWorks> for why each of these steps takes the shape it does.

### Where to start

- New to the CLI? <doc:DozerWalkthrough> is a first run, end to end.
- Building on the Swift API? <doc:LibraryGuide> has the ``Sandbox`` actor and its lifecycle.
- Driving it from a terminal? <doc:CLIReference> is every `doz` command.
- Curious what is actually running? <doc:HowItWorks>.
- Want the numbers? <doc:Measurements>.

## Topics

### Guides

- <doc:DozerWalkthrough>
- <doc:Concepts>
- <doc:CLIReference>
- <doc:LibraryGuide>
- <doc:HowItWorks>
- <doc:Measurements>

### The sandbox

- ``Sandbox``
- ``SandboxSpec``
- ``SandboxStatus``
- ``SandboxError``
- ``SandboxEvent``
- ``Phase``

### Sessions

- ``SessionConnection``
- ``SessionOutput``
- ``DetachReason``
- ``ExecResult``

### Images and disks

- ``ImageSpec``
- ``ImageBaker``
- ``AgentImages``
- ``AgentRelease``
- ``AgentPackage``
- ``StoreLayout``
- ``RestorePoint``
- ``CustomImage``
- ``DiskAccounting``
- ``MaintenanceAdvice``

### Network and credentials

- ``NetworkPolicy``
- ``EgressRule``
- ``EgressProxy``
- ``CredentialVault``
- ``CredentialBinding``
- ``ForeignCredential``
