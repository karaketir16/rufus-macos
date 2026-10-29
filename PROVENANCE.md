# Upstream provenance

## Exact baseline

| Field | Recorded value |
| --- | --- |
| Upstream project | [pbatard/rufus](https://github.com/pbatard/rufus) |
| Base commit | `2a8ecf282801668f70945f99eb1f78a979ded5aa` |
| Commit timestamp | `2026-10-28T12:36:21Z` |
| Subject | `[core] prevent TOCTOU when reusing the files downloaded for BIOS/Legacy boot` |
| Resource version at that commit | `FILEVERSION 4,16,2430,0` and `PRODUCTVERSION 4,16,2430,0` in `src/rufus.rc` |
| Configure version | `4.16` in `configure.ac` |
| Release interpretation | **4.16.2430 development snapshot**, not a tagged 4.16 release |

The latest `v4.1*` tag returned by the recorded upstream query was `v4.15` (`6d8fbf98305ff37eb531c45cbd6ff44563c53917`). The base SHA, rather than a moving branch or release label, is authoritative.

## Local development lineage

- `b4bf7ae`: initial native macOS implementation and Windows User Experience workflow.
- `1d52e9c`: language and real-ISO verification documentation.
- `5ee71be`: raw DD mode and NTFS investigation.
- `efa1d99`: streaming compressed DD images and Space verification.
- Subsequent publication cleanup retains the `macos/` layout and minimal required `res/` assets, replacing Windows-only build/docs content without rewriting existing commits.

This checkout began as a shallow upstream clone. During publication preparation, `git fetch --unshallow --tags origin` restored upstream history and tags without rewriting commits. Verification returned `false` for `git rev-parse --is-shallow-repository`; the base describes as `v4.15-34-g2a8ecf28`, with v4.15 verified as an ancestor. No public fork URL is assumed here, and preparing the repository does not create a remote or release.

Historical development notes and removed Windows sources may still exist in earlier commits. Current-tree cleanup is not history sanitization. Review history before making the repository public; if privacy requires a fresh-history source export, retain this document and all licensing/source material in that export.

## Retained upstream binary resources

These files are retained byte-for-byte from the recorded base:

```text
72683fa1250eeea772d3399277b434d4e55ba8dd0dc926e52d817e701fc2eb9e  res/uefi/uefi-ntfs.img
11df838dc69378187e1e1aaf32d34384157642d07096c6e49c1d0e7375634544  res/setup/setup_x64.exe
14bd07f559513890a0f6565df3927392b4fe6b8e6fc3f5e832e9d69c8b7bb7eb  res/setup/setup_arm64.exe
```

The setup-wrapper source, resource definitions and project files remain in `res/setup/`; its required icon and original notice remain in `res/icons/`. The boot image's component/source references remain in `res/uefi/readme.txt`. See [third-party notices](THIRD_PARTY_NOTICES.md).

## Re-check the baseline

```sh
git show -s --format='%H%n%cI%n%s' 2a8ecf282801668f70945f99eb1f78a979ded5aa
git show 2a8ecf282801668f70945f99eb1f78a979ded5aa:src/rufus.rc
shasum -a 256 res/uefi/uefi-ntfs.img res/setup/setup_x64.exe res/setup/setup_arm64.exe
```

References to `src/*.c` in Swift comments refer to this upstream baseline, even though Windows application sources are no longer in the current tree. View them with `git show <base>:src/<file>` or the pinned upstream commit URL.
