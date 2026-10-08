import Foundation

// 606 — who may do what: the remote-capability table (606.02-PLAN.md). A closed `switch` over every `WebRoute`
// with no `default`, so a new route cannot ship without a decision (`WebExposureTests` pins the table).
//
// Owner ruling: a browser admitted to `doz serve` may do everything the Mac's dashboard does, EXCEPT typing a
// secret while the request is plain HTTP (allowed when it arrived over https through a trusted proxy). Not a
// restriction but a fact: what opens a window on the Mac's own SCREEN (its folder and file pickers, Terminal)
// is not offered to another computer. The server is the wall; the page only hides what it cannot do.

public enum WebExposure {
    /// Who is asking.
    public enum Principal: Equatable, Sendable {
        /// `doz ui` — the Mac's own browser (loopback).
        case mac
        /// A browser admitted to `doz serve`; `secure`: the request arrived over https at a trusted proxy.
        case remote(secure: Bool)

        public var isRemote: Bool { if case .remote = self { true } else { false } }
        public var name: String {
            switch self { case .mac: "mac"; case .remote(let s): s ? "remote-https" : "remote-http" }
        }
    }

    /// What a route is, for this table.
    public enum Kind: String, Sendable, CaseIterable {
        /// The page itself and the session (no data).
        case page
        /// Reads (and changes nothing).
        case read
        /// Changes: actions, terminals, settings, the wizards' writes.
        case change
        /// A key or token typed in a masked field.
        case secretEntry = "secret-entry"
        /// Opens a window on the Mac's own screen.
        case macScreen = "mac-screen"
        /// doz serve's devices and invites.
        case devices
        /// Only doz serve answers it (the doctor's probe).
        case serveOnly = "serve-only"
    }

    public static func kind(_ route: WebRoute) -> Kind {
        switch route {
        case .index, .asset, .terminalFrame, .offline, .serviceWorker, .sessionBootstrap, .sessionInfo, .sessionRenew, .sessionEnd:
            return .page
        case .overview, .sandbox, .sandboxSessions, .sandboxNetwork, .sandboxTools, .images, .imageTree, .accounts, .metrics,
             .metricsCSV, .events, .doctor, .stream, .operations, .settings, .sessionScreen, .terminalLayout, .bootLogs, .bootLog,
             .onboarding, .preparations, .resources, .bases, .access:
            return .read
        case .actions, .policyPreview, .terminalTicket, .terminalSocket, .settingsChange, .terminalLayoutSet, .onboardingConfig,
             .workspaceCheck, .quickAdd, .projectOpen, .projectPreview, .projectWrite, .resourcesPreview, .accessCheck:
            return .change
        case .accountAdd, .sandboxKey, .accessGithubKey:
            return .secretEntry
        case .terminal, .workspaceChoose, .projectsDirChoose, .dockerfileChoose:
            return .macScreen
        case .serveStatus, .serveDevices, .serveShare, .serveRevoke, .serveRename:
            return .devices
        case .serveProbe:
            return .serveOnly
        }
    }

    /// nil: allowed; else the refusal (its message says why and what to do instead).
    public static func decide(_ route: WebRoute, _ who: Principal) -> WebRejection? {
        switch (kind(route), who) {
        case (.secretEntry, .remote(secure: false)): return .secretOverHTTP
        case (.macScreen, .remote): return .macScreen
        case (.serveOnly, .mac): return .notFound
        case (.page, _), (.read, _), (.change, _), (.secretEntry, _), (.macScreen, .mac), (.devices, _), (.serveOnly, .remote):
            return nil
        }
    }
}
