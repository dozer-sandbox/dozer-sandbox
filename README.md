<!-- placeholder: SnoozeContainerKit library name · {{ONE_LINE_DESCRIPTION}} · {{PRODUCTS_TABLE}} rows of
     product name -> what it is · johnoscott GitHub owner/org · {{PIN}} current tag e.g. v0.1.0 ·
     {{LINUX_OR_NOT}} one line: either "checked on both macOS and Linux in CI" or the reason this
     package is macOS-only (e.g. it links AppKit/Metal) -->

# SnoozeContainerKit

SnoozeContainerKit is {{ONE_LINE_DESCRIPTION}}.

{{LINUX_OR_NOT}}

## Products

| Product | What it is |
|---|---|
{{PRODUCTS_TABLE}}

## Consuming

```swift
dependencies: [
    .package(url: "https://github.com/johnoscott/SnoozeContainerKit.git", from: "{{PIN}}"),
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "SnoozeContainerKit", package: "SnoozeContainerKit"),
    ]),
]
```

The package identity SwiftPM derives is the lowercased last URL component — which must stay
`SnoozeContainerKit`.

> **Prelaunch note.** Until this repo is unveiled publicly, the URL above is not yet reachable.
> Consumers keep the public URL in their manifest and redirect it with a SwiftPM mirror supplied
> only in remote mode:
>
> ```bash
> swift build --config-path Scripts/swiftpm-remote-config
> ```
>
> SwiftPM derives identity from the original URL, not the mirror, so the mirror entry is simply
> deleted at unveil. It must **not** live at `.swiftpm/configuration/mirrors.json` — a mirror there
> applies in every mode and rewrites package identity, which breaks path-dependency (local) mode.
> See [`Scripts/swiftpm-remote-config/README.md`](Scripts/swiftpm-remote-config/README.md).

## Storage / identity is configured by the host, not by this package

This package owns no brand and no directory name. A host app declares its own identity and
bootstraps it before anything reads a path or a bundle id. Nothing in `Sources/` may hardcode a
consumer's bundle id, product name, or storage directory — `Scripts/audit.sh` fails the build if
one appears.

## Development

```bash
make build     # swift build, mirror flag applied only when it is needed
make test      # swift test
make audit     # neutrality + de-branding (+ Linux import seams, if this package supports Linux)
make linux     # compile-check in the pinned Linux container (Foundation-only packages only)
make smoke     # run the package's runtime smoke executable in that container, if it has one
```

## Contributing

Features arrive here by **graduation** from a private playground repo, where they are built and
lived with first — see `docs/GRADUATION.md` in the workspace. That is why the history may be
shallow and why a change can appear fully formed: this repo is the destination, not the workshop.

Issues and fixes are welcome directly. A bug report, a reproduction, a fix, a documentation
correction — open it here and it is handled here. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Licence

MIT (see [`LICENSE`](LICENSE)); third-party licences are inventoried in
[`LICENCES.md`](LICENCES.md).
