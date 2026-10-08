# Licence texts not carried by a dependency's own checkout

Fetched verbatim from upstream at the exact revision named, for the components below whose licence text is not in
the SwiftPM checkout (BoringSSL, LibYAML) or that this project ports (Go, moby/patternmatcher, fsutil).
`Scripts/third-party-licences.sh` copies every file here into each release's `THIRD-PARTY-LICENSES.txt`;
`Scripts/audit.sh` checks each file's sha256 against this table.

| file | what | source | sha256 |
|---|---|---|---|
| `boringssl-817ab07ebb53da35afea409ab9328f578492832d.LICENSE` | BoringSSL as vendored by swift-nio-ssl 2.37.5 (`Sources/CNIOBoringSSL/hash.txt`) | https://raw.githubusercontent.com/google/boringssl/817ab07ebb53da35afea409ab9328f578492832d/LICENSE | `756a61a8300d105ae68e7f2993e27d41a765c946f3400422e2403b01e7ded527` |
| `boringssl-0226f30467f540a3f62ef48d453f93927da199b6.LICENSE` | BoringSSL as vendored by swift-crypto 4.5.2 (`Sources/CCryptoBoringSSL/hash.txt`) | https://raw.githubusercontent.com/google/boringssl/0226f30467f540a3f62ef48d453f93927da199b6/LICENSE | `827c8d8fc207c2392794eef9e00fe246f9f61fdcc132556c275be3dd8c3cd97f` |
| `libyaml-0.1.7.LICENSE` | LibYAML as vendored in Yams (`Sources/CYaml`, imported 2016-11-19 in Yams f7165ec, no version recorded; 0.1.7 was the release then — its licence is unchanged in substance in later releases, which add a second copyright line) | https://raw.githubusercontent.com/yaml/libyaml/0.1.7/LICENSE | `d0d8b09800a45cd982e9568fc7669d9c1a4c330e275a821bbe24d54366d16fe9` |
| `go-go1.25.0.LICENSE` | Go — `Guest/dozview/match/dozre.c` (regexp/syntax), `dozmatch.c` and `Sources/DozerKit/DockerIgnore.swift` (path.Clean, path/filepath.Match) are ports | https://raw.githubusercontent.com/golang/go/go1.25.0/LICENSE | `911f8f5782931320f5b8d1160a76365b83aea6447ee6c04fa6d5591467db9dad` |
| `moby-patternmatcher-v0.6.1.LICENSE` | moby/patternmatcher v0.6.1 — ported in `dozmatch.c` and `DockerIgnore.swift` | https://raw.githubusercontent.com/moby/patternmatcher/v0.6.1/LICENSE | `7c87873291f289713ac5df48b1f2010eb6963752bbd6b530416ab99fc37914a8` |
| `moby-patternmatcher-v0.6.1.NOTICE` | its NOTICE (Apache-2.0 §4(d)) | https://raw.githubusercontent.com/moby/patternmatcher/v0.6.1/NOTICE | `7a3adb8e71d95e4536be8dab1aab2c21eedecf3ee45d2c968d034ee594d7b144` |
| `tonistiigi-fsutil-83cac42c1c52.LICENSE` | tonistiigi/fsutil — its filter rule for an excluded directory, ported in `DockerIgnore.swift` | https://raw.githubusercontent.com/tonistiigi/fsutil/83cac42c1c5296d6bbc4017ec1ee3c6701f49938/LICENSE | `5fd05bdc4791a1ca9366222f7e26ca631a9d3aa575974900959b9f23cd2eb331` |
