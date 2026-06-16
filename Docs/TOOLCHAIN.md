# Toolchain — distributing & running `cachebay-cli`

`cachebay-cli` (Rust, in `cli/`) generates the typed Swift for your `.graphql`
operations. SwiftPM can't compile Rust, so the CLI ships as a **prebuilt
`binaryTarget` artifact bundle** (the SwiftLint / Mozilla `rust-components`
pattern) and is driven by the `CachebayCodegen` **command plugin**.

The mode is chosen by the `CACHEBAY_CLI` environment variable:

| `CACHEBAY_CLI` | binary source | who |
|---|---|---|
| `off` *(default)* | none — plugin absent, `swift build`/`test` untouched | bootstrap / library devs |
| `local` | `Artifacts/cachebay-cli.artifactbundle` (you build it) | CLI development |
| `release` | downloaded from the GitHub Release, pinned by checksum | **consumers** |

## Consumers (zero install)

After a release is published (`defaultCLIMode = "release"` in `Package.swift`),
adding the package is enough — SwiftPM fetches the matching, notarized CLI:

```swift
.package(url: "https://github.com/lockvoid/cachebay-ios.git", from: "1.2.0")
```

```sh
swift package --allow-writing-to-package-directory cachebay-codegen \
  --schema path/to/schema.graphql \
  --operations path/to/GraphQL \
  --output path/to/Generated \
  [--namespace API] [--config path/to/cachebay.config.json]
```

In Xcode: right-click the package → **cachebay-codegen**. The binary is pinned in
`Package.swift` at the package version, so CLI and runtime can never drift.

## Maintainer / CLI development

- **Iterating on the Rust CLI** — point the plugin straight at the built binary
  (no bundle):
  ```sh
  ( cd cli && cargo build --release )
  CACHEBAY_CLI=local CACHEBAY_CLI_PATH=cli/target/release/cachebay-cli \
    swift package --allow-writing-to-package-directory cachebay-codegen --schema … --operations … --output …
  ```
  `CACHEBAY_CLI=local` makes SwiftPM include the plugin without a remote
  artifact; `CACHEBAY_CLI_PATH` overrides which binary runs.

- **Exercising the real bundle path**:
  ```sh
  scripts/build-cli-bundle.sh                 # → Artifacts/cachebay-cli.artifactbundle (unsigned)
  CACHEBAY_CLI=local swift package --allow-writing-to-package-directory cachebay-codegen …
  ```

`Artifacts/` is git-ignored — the bundle is a build output, shipped via Releases.

## Cutting a release (first run = activation)

**Push a `vX.Y.Z` tag** — the **Release cachebay-cli** workflow
(`.github/workflows/release-cli.yml`) does the rest:

```sh
git tag v1.2.1 && git push origin v1.2.1
```

1. cross-compiles arm64 + x86_64, `lipo`s a universal binary, assembles the
   `.artifactbundle`;
2. **codesigns (Developer ID, hardened runtime) + notarizes** it;
3. checksums the zip (`shasum`);
4. edits `Package.swift` — flips `defaultCLIMode = "release"`, sets
   `cliReleaseTag` + `cliReleaseChecksum` — commits to `main`, **force-moves the
   tag onto that commit**, and creates the Release with the bundle attached.

The checksum must live in the *tagged* commit's `Package.swift` but isn't known
until the artifact is built, so the workflow builds → commits → force-moves the
tag. Those pushes use `GITHUB_TOKEN`, whose events don't trigger new runs, so
there's no loop. After the first run `defaultCLIMode` is `release` and consumers
need no env var. (`workflow_dispatch` with a `version` input is kept for manual
re-runs.)

> If `main` is branch-protected against direct pushes, give this workflow a
> bypass (or have it open a PR for the `Package.swift` pin) — the commit step
> pushes straight to `main`.

**No secrets required** — see signing below.

### Signing: ad-hoc only, no Apple account

The release does **not** Developer-ID-sign or notarize, and needs no Apple
account or secrets. Two facts:

- **Apple Silicon requires a *valid* signature to exec any binary.** `cargo`'s
  linker ad-hoc-signs each arch, but `lipo` invalidates that, so the script
  re-signs the universal binary ad-hoc (`codesign --force --sign -`) — free, no
  identity. (`codesign --verify` then passes.)
- **Notarization is only for Gatekeeper, which gates *quarantined* downloads.**
  SwiftPM doesn't set the `com.apple.quarantine` xattr on artifacts it fetches,
  so Gatekeeper never runs on the plugin's CLI → an ad-hoc-signed binary is
  enough.

Add Developer ID + notarization **only** if you start distributing the binary
*outside* SwiftPM (e.g. a browser/`curl` download, which *is* quarantined) or
actually hit a Gatekeeper block.

## Fallback: Homebrew / cargo

If you'd rather not run the release pipeline, the CLI is a normal Mac binary:
`cargo install --path cli`, or a Homebrew tap. Point the plugin at it with
`CACHEBAY_CLI_PATH`, or just call `cachebay-cli codegen …` directly (the
pre-plugin workflow). This skips notarization but isn't auto-fetched by SwiftPM.
