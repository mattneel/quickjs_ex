# Vendored QuickJS Workflow

QuickjsEx keeps QuickJS-related sources checked into the repository instead of
using git submodules. This keeps regular checkouts, CI, and source package builds
working without recursive clone setup.

The source of truth for upstream repositories, pinned commits, destination
directories, and allowlisted files is `vendor/quickjs_sources.exs`.

## Validate the current snapshot

```sh
mix quickjs.vendor.check
```

The check verifies that every allowlisted file is present, no extra files are in
the vendored directories, each vendored file has the expected `VENDORED:` header
for the pinned commit, and configured local rewrites have been applied. Local
adapter files listed as `local_files` in the manifest are allowed in a vendor
directory but are not overwritten by the updater.

The Zig bindings intentionally rewrite `@import("quickjs_c")` to
`@import("quickjs_c").c` because Zigler generates `quickjs_c` with a public `c`
namespace. Do not replace that with `pub usingnamespace`; the project is pinned
to Zig 0.15.2.

## Refresh or update the snapshot

Refresh the currently pinned commits:

```sh
mix quickjs.vendor.update
```

Update both upstreams to their default branch HEAD:

```sh
mix quickjs.vendor.update --latest
```

Update specific refs:

```sh
mix quickjs.vendor.update --quickjs-ng-ref <commit-or-tag> --zig-quickjs-ng-ref <commit-or-tag>
```

After updating, run:

```sh
mix quickjs.vendor.check
mix format --check-formatted
mix test test/security_test.exs
mix test
```

Commit a vendor refresh separately from any compatibility fixes so source changes
and local adaptations stay reviewable.
