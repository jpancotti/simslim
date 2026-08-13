# Derived Data cleanup safety model

Derived Data cleanup manages generated Xcode storage on the host Mac. It is
separate from simulator disk cleanup and service slimming.

## Scope

The default root is:

```text
~/Library/Developer/Xcode/DerivedData
```

`simslim derived-data` performs a read-only scan of real directories immediately
inside that root. It reports allocated filesystem size, last modification time,
and whether a name looks like a project directory or shared Xcode cache. Regular
files and symbolic links are ignored.

For project directories, the scan also reads Xcode's generated metadata on a
best-effort basis:

- `info.plist` supplies the source workspace or project path.
- The newest top-level `.app` in `Build/Products` supplies its bundle identifier,
  app version, build number, product name, configuration, platform, SDK, minimum
  OS, product path, and last-build time.
- The nearest `package.json` at or above the source workspace supplies the package
  name and version.

These fields describe the latest build products still present in Derived Data;
they can be absent for caches, interrupted builds, or directories whose products
were already pruned. Source paths are checked for existence and reported as
missing when an old workspace or temporary worktree no longer exists. Metadata
inspection never writes to the source project or build products.

`simslim derived-data-clean` accepts exact directory names returned by the scan.
It does not accept arbitrary paths. Every target must remain:

- A direct child of the resolved DerivedData root.
- A real directory rather than a file or symbolic link.
- Inside the root after resolving symbolic links.

All selected targets are validated and measured before deletion starts. The
DerivedData root is preserved, and cleanup refuses to run without `--confirm`.

Tests cover traversal attempts, direct symbolic links, missing roots, selective
deletion, and preservation of data outside the root.

## What deletion affects

Deleted folders can contain build products, indexes, module caches, SDK caches,
and package working data. Xcode regenerates these as projects build and index,
which can make the next build substantially slower and may require package data
to be fetched again.

Do not run cleanup during an active build or index.

## Explicitly outside the boundary

Derived Data cleanup never scans or deletes:

- Project source directories.
- Xcode Archives.
- iOS DeviceSupport.
- Simulator devices or their data.
- Shared iOS runtimes.
- The DerivedData root itself.

The `SIMSLIM_DERIVED_DATA_PATH` environment variable exists for controlled
testing and custom installations. The explicit root must itself be named
`DerivedData`; when set, it receives the same direct-child and symlink
safeguards. This extra name check prevents an accidentally broad override from
turning a home, volume, or other general directory into a cleanup root.
