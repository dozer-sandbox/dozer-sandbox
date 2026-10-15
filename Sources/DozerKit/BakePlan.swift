import Foundation

/// 617 (owner: "the objective is to show how the image was made including all the commands to build and configure"):
/// what a bake RUNS, taken from the ImageSpec and the bake's inputs at the moment it runs — never reconstructed. The
/// baker hands it out once per bake (`SandboxEvent.bakePlan`); the host keeps it in the image's build log. It changes
/// nothing a bake does: the bake key, the scripts and the checks are the spec's, as before (`RecipePinTests`).
public struct BakePlan: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        /// The spec's step name ("install the developer baseline (…)"); the event label is "step: " + name.
        public var name: String
        /// Exactly the argv the bake executes (a script step: bash -euo pipefail -c SCRIPT).
        public var argv: [String]
        /// The user it runs as (nil: root).
        public var user: String?
        /// The environment it is given, exactly as passed (already scrubbed of credential names by the bake).
        public var environment: [String: String]
        public var timeoutSeconds: Int64
        public init(name: String, argv: [String], user: String?, environment: [String: String], timeoutSeconds: Int64) {
            self.name = name
            self.argv = argv
            self.user = user
            self.environment = environment
            self.timeoutSeconds = timeoutSeconds
        }
    }
    public struct Check: Codable, Equatable, Sendable {
        public var argv: [String]
        /// What its output must contain (nil: only exit 0).
        public var expect: String?
        public var user: String
        public init(argv: [String], expect: String?, user: String) {
            self.argv = argv
            self.expect = expect
            self.user = user
        }
    }
    public var image: String
    /// The OCI base with its digest (`repo@sha256:…`).
    public var base: String
    /// The bake key (what this build of the image is cached under) and the base disk's key.
    public var key: String
    public var baseKey: String
    /// The agent package and exact version the image installs (nil: none).
    public var agent: AgentPackage?
    /// The kernel the bake VM boots (its file name and sha256), and the guest init image.
    public var kernelFile: String
    public var kernelSHA256: String
    public var initfsReference: String
    /// How the bake reaches the network: "proxy" (no interface; the Mac's proxy under `policy`) or "nat".
    public var network: String
    /// The bake network policy's preset and its rules, one line each ("allow registry.npmjs.org:443").
    public var policyPreset: String?
    public var policyRules: [String]
    public var policyDefault: String?
    public var cpus: Int
    public var memoryMiB: UInt64
    public var user: String
    public var home: String
    public var steps: [Step]
    public var checks: [Check]
    /// The last command: the disk's trim (run as root).
    public var trimCommand: [String]

    public init(image: String, base: String, key: String, baseKey: String, agent: AgentPackage?, kernelFile: String, kernelSHA256: String,
                initfsReference: String, network: String, policyPreset: String?, policyRules: [String], policyDefault: String?,
                cpus: Int, memoryMiB: UInt64, user: String, home: String, steps: [Step], checks: [Check], trimCommand: [String]) {
        self.image = image
        self.base = base
        self.key = key
        self.baseKey = baseKey
        self.agent = agent
        self.kernelFile = kernelFile
        self.kernelSHA256 = kernelSHA256
        self.initfsReference = initfsReference
        self.network = network
        self.policyPreset = policyPreset
        self.policyRules = policyRules
        self.policyDefault = policyDefault
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.user = user
        self.home = home
        self.steps = steps
        self.checks = checks
        self.trimCommand = trimCommand
    }

    /// One rule as a person reads it: "allow GET registry.npmjs.org:443 /pkg/".
    static func describe(_ r: EgressRule) -> String {
        var s = r.action.rawValue
        if let m = r.methods, !m.isEmpty { s += " " + m.joined(separator: ",") }
        s += " " + r.host
        if let p = r.ports, !p.isEmpty { s += ":" + p.map(String.init).joined(separator: ",") }
        if let p = r.pathPrefixes, !p.isEmpty { s += " " + p.joined(separator: " ") }
        if !r.note.isEmpty { s += " — " + r.note }
        return s
    }
}
