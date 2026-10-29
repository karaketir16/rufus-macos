# Publishing an experimental preview

This repository is source-ready for an experimental preview, not a stable or safety-certified USB utility. Do not imply endorsement by the upstream Rufus project.

## Before publishing source

- Preserve `LICENSE.txt`, upstream provenance, dependency notices, and required resource sources.
- Keep disk images, Windows ISOs, local dependencies, build outputs, credentials, and private session notes out of Git.
- Build the application and run the non-device check harness from the documented clean-checkout steps.
- Review screenshots for personal information. Retain development-mode warnings and explain that recorded writes used disposable disk images.
- Inspect `git diff --check` and the complete publication diff.

## Before publishing binaries

- Supply the corresponding source, including local changes and build scripts, in accordance with the applicable GPL licenses. Link the exact source commit used for each binary.
- Include the dependency license notices and identify the source/version/hash of every bundled helper and upstream boot resource.
- Verify helper architectures and dynamic-library dependencies on a clean machine. A locally built arm64 app is not evidence of Intel support.
- Decide on Developer ID signing and notarization. The development build script only produces an ad-hoc signature; it is not notarized.
- Publish SHA-256 checksums alongside artifacts, and clearly label them **experimental**.
- Test installation and first launch on a clean macOS machine, including Gatekeeper behavior. Do not tell users to disable system security protections.

## Stable-release blockers

Real physical USB writes, authorization failures and recovery, booting representative firmware, and complete Windows installations still require validation. NTFS writing, Windows To Go, persistence and several upstream formats/workflows remain unsupported. Successful virtual-device byte comparisons do not establish those properties.

No remote repository, GitHub release, tag, notarized binary or upload is created by preparing these files.
