import Foundation
import DozerKit

// 617 polish (owner, from a live demo: "base disk flattened (83e613bd2957)" sat under a spinner for 3 min 22 s) —
// what a person READS for each step. The library's labels stay as they are (metrics keys, preparation records,
// suites match them); this table turns each into a pair in plain words:
//   running  present tense, while it happens   "Unpacking the Node.js base image…"
//   done     past tense, when it is done        "Unpacked the Node.js base image (1203 MiB)"
// and a level: `major` (what a person cares about on a first prepare — downloading, unpacking, installing the
// agent, starting) or `detail` (shown with -v, in plain mode and in logs). A label this table does not know reads
// as it is, as a detail.

public struct StepWords: Equatable, Sendable {
    public var running: String
    public var done: String
    public var major: Bool
}

public enum StepWording {
    /// A base name as a person says it: `node` → "Node.js", `python` → "Python"; else the name.
    static func baseTitle(_ ref: String) -> String {
        let name = String(ref.split(separator: "@").first ?? Substring(ref)).split(separator: "/").last.map(String.init) ?? ref
        let short = name.split(separator: ":").first.map(String.init) ?? name
        return BaseCatalogue.all.first { $0.id == short || $0.repository.hasSuffix("/" + short) }?.title ?? short
    }

    static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// The words for a step's label (its done label — a result may follow " → ").
    public static func of(_ label: String) -> StepWords {
        let parts = label.components(separatedBy: " → ")
        let head = parts[0], result = parts.count > 1 ? parts.dropFirst().joined(separator: " → ") : nil
        func w(_ r: String, _ d: String, _ major: Bool = false) -> StepWords { StepWords(running: r, done: d, major: major) }
        func m(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
                  let hit = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) else { return nil }
            return (1..<max(1, hit.numberOfRanges)).map { i in Range(hit.range(at: i), in: head).map { String(head[$0]) } ?? "" }
        }
        // Preparing an image.
        if let g = m(#"pulled the base image (.+)"#) {
            return w("Downloading the \(baseTitle(g[0])) base image", "Downloaded the \(baseTitle(g[0])) base image", true)
        }
        if let g = m(#"base image (.+) \(cached\)"#) {
            return w("Finding the \(baseTitle(g[0])) base image", "The \(baseTitle(g[0])) base image was already downloaded")
        }
        if let g = m(#"base disk flattened \((?:(.+), )?[0-9a-f]+\)"#) {
            let t = g[0].isEmpty ? "base" : "\(baseTitle(g[0])) base"
            return w("Unpacking the \(t) image — first time only for this base; later sandboxes reuse it",
                     "Unpacked the \(t) image" + (result.map { " (\($0))" } ?? ""), true)
        }
        if m(#"base disk ready \(cached, [0-9a-f]+\)"#) != nil { return w("Finding the unpacked base image", "The base image was already unpacked") }
        if head == "cloned the base disk (APFS clone)" { return w("Copying the base image", "Copied the base image (an instant copy)") }
        if head == "booted the bake VM" { return w("Starting a VM to prepare the image", "Started a VM to prepare the image") }
        if head.hasPrefix("bake network: ") { return w("Connecting it through this Mac's network rules", "Connected it through this Mac's network rules") }
        if let g = m(#"step: (.+)"#) {
            let name = g[0]
            for (verb, ing, ed) in [("install", "Installing", "Installed"), ("create", "Creating", "Created"), ("add", "Adding", "Added"),
                                    ("configure", "Configuring", "Configured"), ("set up", "Setting up", "Set up"), ("write", "Writing", "Wrote")]
            where name.hasPrefix(verb + " ") {
                let rest = String(name.dropFirst(verb.count + 1))
                let major = verb == "install" && !rest.contains("launcher")
                return w("\(ing) \(rest)", "\(ed) \(rest)", major)
            }
            return w("Preparing the image: \(name)", "Prepared the image: \(name)")
        }
        if let g = m(#"verify: (.+)"#) {
            let what = g[0].split(separator: " ").first.map(String.init) ?? g[0]
            return w("Checking the image (\(what))", "Checked the image (\(what))" + (result.map { ": \($0)" } ?? ""))
        }
        if head == "trimmed the disk (fstrim /)" { return w("Giving unused disk space back to the Mac", "Gave unused disk space back to the Mac") }
        if head == "stopped the bake VM cleanly" { return w("Stopping the preparation VM", "Stopped the preparation VM") }
        if let g = m(#"flattened (.+) to one ext4 disk \((.+)\)"#) {
            return w("Unpacking the \(baseTitle(g[0])) image — first time only; later sandboxes reuse it", "Unpacked the \(baseTitle(g[0])) image (\(g[1]))", true)
        }
        // The kernel and the start-up image (once per store).
        if let g = m(#"downloaded (.+) \((.+)\)"#) { return w("Downloading \(g[0])", "Downloaded \(g[0]) (\(g[1]))", true) }
        if let g = m(#"verified and extracted (.+)"#) { return w("Checking and unpacking \(g[0])", "Checked and unpacked \(g[0])") }
        if head.hasPrefix("kernel ") && head.contains(" ready") { return w("Getting the Linux kernel ready", "Linux kernel ready") }
        if head.hasPrefix("guest init image ready") { return w("Getting the VM's start-up image ready", "VM start-up image ready") }
        // Starting, waking, stopping.
        if head == "VM created and booted (VZ start + Linux kernel + vminitd)" { return w("Starting the virtual machine", "Started the virtual machine", true) }
        if head == "container process started" { return w("Starting its first process", "Started its first process") }
        if head.hasPrefix("root disk cloned from") { return w("Giving the sandbox its own disk", "Gave the sandbox its own disk (an instant copy)") }
        if head.hasPrefix("created the empty state disk") { return w("Making the sandbox's own state disk", "Made the sandbox's own state disk") }
        if head == "installed deckhold (the guest PTY holder)" { return w("Setting up its terminals", "Set up its terminals") }
        if head.hasPrefix("prepared the guest") { return w("Preparing its system", "Prepared its system") }
        // The tools layer's first set-up: "tools: installing X with apk, through the proxy", "tools: gh 2.102.0 — for …".
        if let g = m(#"tools: installing (.+?) with (\w+).*"#) { return w("Installing \(g[0]) (\(g[1]))", "Installed \(g[0]) (\(g[1]))") }
        if let g = m(#"tools: (.+)"#) { return w("Setting up \(g[0])", "Tools: \(g[0])") }
        if head.hasPrefix("network: no interface") { return w("Connecting it through this Mac's network rules", "Connected it through this Mac's network rules") }
        if head.hasPrefix("e2fsck ") { return w("Checking its disk", "Checked its disk") }
        if head == "restored VM state from disk" { return w("Bringing its memory back from disk", "Brought its memory back from disk", true) }
        if head == "saved VM state to disk" { return w("Saving its memory to disk", "Saved its memory to disk", true) }
        if head.hasPrefix("restored the VM from its snapshot") { return w("Bringing it back after the restart", "Brought it back after the restart", true) }
        if head == "adopted the restored container" { return w("Reconnecting to it", "Reconnected to it") }
        if head == "paused the VM (guest CPU 0, memory kept)" { return w("Pausing it", "Paused it (its memory kept)") }
        if head == "resumed the VM" || head == "resumed" { return w("Resuming it", "Resumed it") }
        if head == "re-synced the guest clock" { return w("Setting its clock", "Set its clock") }
        if head.hasPrefix("re-mounted ") { return w("Reconnecting its shared folders", "Reconnected its shared folders") }
        if head.hasSuffix("to stop it gracefully") { return w("Waking it to stop it cleanly", "Woke it to stop it cleanly") }
        if head == "stopped the container" { return w("Stopping it", "Stopped it") }
        if head == "saving the host's state" { return w("Saving the host's state", "Saved the host's state") }
        if let g = m(#"(.+) ready \((cached|pulled)\)"#) { return w("Getting \(g[0]) ready", "\(cap(g[0])) ready") }
        return w(head, head + (result.map { " → \($0)" } ?? ""))
    }

    /// A transfer's label as a person reads it: "pulling node@1a2b…" → "Downloading node@1a2b…", "unpacking node@…" →
    /// "Unpacking the Node.js base image".
    public static func transfer(_ label: String) -> String {
        if label.hasPrefix("unpacking ") { return "Unpacking the \(baseTitle(String(label.dropFirst(10)))) base image" }
        if label.hasPrefix("pulling ") { return "Downloading " + label.dropFirst(8) }
        if label.hasPrefix("downloading ") { return "Downloading " + label.dropFirst(12) }
        return label
    }

    /// A note a person only needs with -v (the bake's bookkeeping).
    public static func noteIsDetail(_ text: String) -> Bool {
        ["fstrim: ", "bake network: ", "baking image ", "image "].contains { text.hasPrefix($0) } && !text.contains("FAILED")
    }
}
