import DozerHost

/// 611: the OpenAI (Codex) account choices the CLI offers — the onboarding step and the create preflight — as data,
/// so both build flavors are unit-tested. A public build offers no ChatGPT sign-in of its own.
enum OpenAIChoices {
    struct Choice: Equatable { var value: String; var label: String }

    static func onboarding(macSignedIn: Bool, flavor: BuildFlavor) -> [Choice] {
        var c: [Choice] = []
        if macSignedIn { c.append(Choice(value: "mac", label: "Use this Mac's Codex login (recommended)")) }
        if flavor.chatgptSignIn { c.append(Choice(value: "chatgpt", label: "Sign in with ChatGPT now — your browser opens (Codex on your ChatGPT plan)")) }
        c.append(Choice(value: "openai-key", label: "Add an OpenAI API key"))
        c.append(Choice(value: "later", label: "Decide later"))
        return c
    }

    /// What the create preflight may add on the spot (after the accounts that already fit).
    static func preflightAdds(flavor: BuildFlavor) -> [Choice] {
        (flavor.chatgptSignIn ? [Choice(value: "chatgpt", label: "sign in with ChatGPT now (your browser opens)")] : [])
            + [Choice(value: "openai-key", label: "add an OpenAI API key now")]
    }

    static func laterHint(flavor: BuildFlavor) -> String {
        flavor.chatgptSignIn
            ? "doz account add chatgpt --chatgpt (or NAME --openai-key), doz account default NAME"
            : "sign in with codex on this Mac (the account mac), or doz account add NAME --openai-key, doz account default NAME"
    }
}
