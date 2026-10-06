import CryptoKit
import Foundation
import Virtualization

// EXPERIMENTAL (604) — audio sandboxes: the Mac's microphone in, its speakers out, through a virtio-snd device
// (`VZVirtioSoundDeviceConfiguration`). Opt-in per sandbox at create (`SandboxSpec.audio`); a sandbox without it
// is exactly what it was before (no device, the pinned kernel, the same keys). Workspace changes/604-*/604.01-SPIKE.md
// holds the evidence and the known defects (an open stream stalls after hibernate/restore; VZ kills the VM if it is
// paused or saved while a capture waits on an unanswered macOS microphone prompt).

/// The sound kernel an audio sandbox boots: kata 6.18.15-186 + `sound.conf` (CONFIG_SOUND, CONFIG_SND,
/// CONFIG_SND_VIRTIO, CONFIG_SND_PROC_FS — and what they select; nothing else differs), built by workspace
/// probes/604-*/kernel/. It is never downloaded: a release carries it (`libexec/doz/kernels/`), the host copies it
/// into the store's kernel cache after checking its sha256, and the VM boots it from there. Image bakes and every
/// image key keep the PINNED kernel (`KernelArtifact.recommended`) — only the audio sandbox's own VM differs.
public enum SoundKernel {
    public static let fileName = "vmlinux-6.18.15-186-sound"
    public static let sha256 = "33d270693f68a25e5b28dafc40aeea1b1035be23022930b406cae0aa2c6ad989"
    public static let size: UInt64 = 16_284_160

    /// The file's sha256 is the pinned one (size first — a cheap refusal).
    public static func isVerified(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? NSNumber)?.uint64Value == size,
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }

    /// Where an audio sandbox's VM reads it: `<kernel cache>/<fileName>`.
    public static func path(inCache directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    /// Put a verified copy into `cache` from `source` (an APFS clone when it can); nothing when one is there.
    /// Returns the cached file. Throws when the source is missing or not the pinned file.
    @discardableResult
    public static func install(from source: URL, into cache: URL) throws -> URL {
        let target = path(inCache: cache)
        if isVerified(target) { return target }
        guard isVerified(source) else {
            throw SandboxError.invalidSpec("the experimental sound kernel at \(source.path) is missing or not the pinned file (sha256 \(sha256.prefix(12)))")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let tmp = cache.appendingPathComponent(".\(fileName).\(getpid()).tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: source, to: tmp)
        _ = try? fm.removeItem(at: target)
        try fm.moveItem(at: tmp, to: target)
        return target
    }
}

/// The audio device an audio sandbox's VM gets: one virtio-snd device with an input stream from the Mac's
/// default microphone and an output stream to its default speakers. A VM input — `VMLayout` records it
/// (`otherDevices["audio"]`), so a snapshot is restored only into a VM that has it.
enum AudioDevice {
    static func add(to config: VZVirtualMachineConfiguration) {
        let snd = VZVirtioSoundDeviceConfiguration()
        let input = VZVirtioSoundDeviceInputStreamConfiguration()
        input.source = VZHostAudioInputStreamSource()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        snd.streams = [input, output]
        config.audioDevices = [snd]
    }
}
