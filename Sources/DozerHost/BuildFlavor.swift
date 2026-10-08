import Foundation

/// 611: what a PUBLIC build of doz leaves out — decided at build time (`make release PUBLIC=1`, the default for real
/// releases, compiles with `-DDOZ_PUBLIC_BUILD`), never by a setting a person could flip.
///
/// - **Dozer's own ChatGPT sign-in** (`doz account add NAME --chatgpt`, the onboarding's and the create preflight's
///   "sign in with ChatGPT") — it signs in with Codex's PUBLIC client id, which is Codex's to use. A public build
///   keeps Codex's other two ways in: the account `mac` (this Mac's own Codex login, read-only) and an OpenAI API key.
///   A ChatGPT account an earlier build put in a store is kept, never used: every request says why.
/// - **The experimental sound kernel** (`doz create --audio`): not in the tarball (a GPL kernel we would have to
///   offer source for, and v2's sound design will differ). `--audio` then says this build does not include it.
///
/// Tests reach both modes without two builds: every decision takes a `BuildFlavor`, and a real process can be
/// told which one it is with the TEST seam `DOZ_TEST_PUBLIC_BUILD=1|0`.
public struct BuildFlavor: Sendable, Equatable {
    public var isPublic: Bool
    public init(isPublic: Bool) { self.isPublic = isPublic }

    public static let publicBuild = BuildFlavor(isPublic: true)
    public static let privateBuild = BuildFlavor(isPublic: false)

    /// How this binary was compiled.
    public static let compiled: BuildFlavor = {
        #if DOZ_PUBLIC_BUILD
        return .publicBuild
        #else
        return .privateBuild
        #endif
    }()

    /// This process's flavor: the compiled one, unless the test seam says otherwise.
    public static var current: BuildFlavor { from(ProcessInfo.processInfo.environment) }

    public static func from(_ env: [String: String], compiled: BuildFlavor = .compiled) -> BuildFlavor {
        switch env["DOZ_TEST_PUBLIC_BUILD"] {
        case "1": .publicBuild
        case "0": .privateBuild
        default: compiled
        }
    }

    /// Dozer's own ChatGPT sign-in is part of this build.
    public var chatgptSignIn: Bool { !isPublic }

    /// Why a ChatGPT sign-in cannot be made with this build.
    public static let chatgptSignInMissing =
        "this doz does not include Dozer's own ChatGPT sign-in. For Codex, use this Mac's own Codex login (the account mac: "
        + "sign in with codex on this Mac) or an OpenAI API key (doz account add NAME --openai-key)"

    /// Why an existing ChatGPT account (made by an earlier, pre-release doz) is not used.
    public static func chatgptAccountUnsupported(_ name: String) -> String {
        "the account \(name) is a ChatGPT sign-in, which this doz does not support — use this Mac's own Codex login "
            + "(doz account use SANDBOX mac) or an OpenAI API key (doz account add NAME --openai-key); doz account rm \(name) removes it"
    }

    /// Why `--audio` cannot be used with this build (a public build never carries the sound kernel).
    public static let audioMissing =
        "this build of doz does not include the experimental audio support (doz create --audio) — it is not part of public releases"
}
