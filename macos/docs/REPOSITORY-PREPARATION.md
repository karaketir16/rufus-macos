# Experimental-preview repository preparation

## Publication decisions

1. Keep this as a focused derivative of Rufus, preserving Git ancestry rather than rewriting upstream commit IDs.
2. Record the exact base SHA and development version in root `PROVENANCE.md`; do not call the snapshot a released Rufus 4.16.
3. Retain `macos/` and minimal `res/` paths so resource lookup and existing checks need no layout compatibility shims.
4. Remove Windows-only application source, build infrastructure, workflows, translations and unused resource collections from the current tree. Keep setup-wrapper corresponding source and required asset notices.
5. Replace the upstream Windows README with an experimental macOS overview, screenshots, build steps, explicit unsupported features and licensing links.
6. Replace local task/handoff notes with public safety, verification and publishing documentation. Keep raw development records outside the publication tree and in existing history; current-tree deletion does not erase history.
7. Ignore private transcripts, Finder metadata, local dependencies, build outputs and disk images. Do not delete the user's untracked transcript.
8. Use app-focused screenshots reviewed for private names/paths. Preserve development-mode and destructive-operation warnings.
9. Harden helper packaging so missing resources fail visibly instead of silently producing an incomplete app. Retain third-party license notices.

## Evidence gates

- Confirm base version directly with `git show <base>:src/rufus.rc` and verify retained resource SHA-256 hashes.
- Review the final tracked publication file set and local Markdown links.
- Validate shell syntax, required resource presence, helper notices and ad-hoc app signature.
- Build helpers and run the full non-device harness from a fresh source snapshot, without relying on ignored dependencies or build outputs.
- Reuse the recorded Cua evidence because application behavior is unchanged by this repository-only preparation; source license comments and packaging changes require rebuild checks, not a fresh destructive write.

Preparing the repository does not create a remote fork, publish a tag, upload a release, certify a binary, or eliminate the stable-release blockers.

Provenance checks completed: upstream resource version was read directly from the base commit; all three retained binary hashes matched `PROVENANCE.md`. Missing upstream history/tags were fetched without rewriting commits. The base verifies as `v4.15-34-g2a8ecf28`, and this checkout is no longer shallow.

The staged publication tree contains 66 files. Local Markdown links resolve, the retained resource hashes match, and `git diff --cached --check` passes. No transcript, Finder metadata, `.deps/` or `.build/` file is staged. A first clean build stopped at the documented missing `pkg-config` prerequisite, before compilation or checks; that preflight failure is not counted as a successful build.

## Final clean-snapshot result

Exported the staged source tree to a fresh scratch directory using `git checkout-index`, with neither `.deps` nor `.build`. Supplied the documented pkg-config prerequisite using a local-only pkgconf 3.0.10 build (not shipped with the app). Then ran the published commands:

```sh
bash scripts/build-wimlib.sh
bash scripts/build-compressors.sh
bash scripts/check.sh
bash scripts/build-app.sh
codesign --verify --deep --strict .build/RufusMac.app
```

All exited successfully. **34 check groups passed**; the [complete output](verification/2026-10-29-publication-checks.log) is retained. This normal harness did not opt in to externally selected virtual-device writes. Recorded Cua GUI evidence is unchanged and summarized separately in [VERIFICATION.md](VERIFICATION.md).

Packaging inspection confirmed the app contains the Rufus GPL text, wimlib/xz/zstd license files, UEFI:NTFS notice, setup icon notice and third-party notices. `otool -L` showed only system libraries for the three built helpers: wimlib/xz use `libSystem`, and zstd uses `libSystem` plus `libz`. The development signature verified; notarization is still not performed.

Final documentation update adds this record and its log to the publication tree. The GitHub Actions workflow mirrors the local build/check commands but has not yet been run on GitHub. Source publication is prepared; binary-release compliance and stable-release gates remain as documented.
