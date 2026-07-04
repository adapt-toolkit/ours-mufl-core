# Versioning

`version.mm` is the single source of truth for the shared core's version. Every
library in the core loads it, so any packet that links the core carries exactly
one version stamp.

Source: [`version.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/version.mm).

## The version type

```mufl
metadef version_t: (
    $MAJ -> int,
    $MIN -> int,
    $PATCH -> int
).
```

The current version is stored in the `hidden` `core_version` field and exposed
via `get_core_version`. The source comment states:

> This MUST be updated every time we update ANY code in the shared core.

Because every library loads `version`, a single edit to any `.mm` file in the
core requires a version bump before the change ships.

## Runtime observability

Each deployed packet exposes its compiled-in version through the read-only
`get_version` transaction described in the README. An integrator can query any
running node to confirm which core version it is running — no out-of-band
coordination needed.

## What changes mean for integrators

| Change | What to do |
|---|---|
| `$PATCH` bump | Wire format is unchanged. Re-compile against the updated submodule; re-run integration tests to confirm nothing regressed. |
| `$MIN` bump | New features added; no existing behaviour removed. Re-compile, re-run integration tests, and read the diff to find new transactions or capability verbs you may want to use. |
| `$MAJ` bump | Breaking changes. Re-compile, re-run all integration tests, and read the diff carefully — wire shapes, transaction names, or type contracts may have changed. |

The docs on this site track `main`; always check the current `core_version` in
`version.mm` to confirm which version the docs describe.
