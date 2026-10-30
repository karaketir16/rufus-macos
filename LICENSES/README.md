# File-level license scope

The following two files are offered under the [MIT License](MIT.txt), copyright (c) 2026 Osman Karaketir:

- `macos/Sources/RufusCore/CompressedImage.swift`
- `macos/scripts/build-compressors.sh`

This is a narrow file-level license grant, not a relicensing of the repository or the compressed-image feature as a whole. The combined Rufus-derived application remains GPL-3.0-or-later under the root `LICENSE.txt`. Existing GPL permissions for previously published copies are not revoked.

The MIT grant does not extend to `RawDiskWriter.swift`, `BundledTools.swift`, tests, UI files, upstream Rufus resources, or other files merely because they interact with these two files. In particular, `CompressedImage.swift` references `BundledTools`; copying that helper would require separately respecting its license or providing an independent implementation.

The script's MIT license covers the script text, not the downloaded xz/zstd sources, built binaries, or their license notices. Those components retain their own licenses. Preserve the MIT copyright and permission notice when reusing the MIT files.

## Provenance review

Both files were introduced in commit `efa1d991520c7efd5401ae83f82b1b3cf4381a47`. A technical review compared them with the pinned Rufus baseline recorded in `PROVENANCE.md` and inspected their local history. No copied or translated Rufus implementation was identified. The Swift file cites the upstream format-extension list and summarizes compatible behavior; these factual references are retained rather than obscured. No implementation-code provenance issue was identified in the build script.

The copyright holder confirmed personal-project ownership and no known employer/client or additional contributor rights requiring permission, and authorized the two-file MIT grant. Git authorship and similarity checks alone do not prove ownership or provide legal clearance. This record does not claim that the rest of the commit is MIT-licensed.
