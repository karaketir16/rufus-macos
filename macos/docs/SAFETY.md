# Safety and support boundaries

This is an experimental disk-writing application. Selecting a target and starting a write erases data. Disk identifiers can change after unplugging or attaching devices; always re-select and verify the current target.

## Existing protections

- Conservative external whole-disk discovery, with an explicit opt-in for fixed external USB devices.
- Typed disk identifier confirmation in the interface.
- Capacity and IOKit registry identity revalidation around writes.
- Disk Arbitration mount blocking during raw device operations.
- Rejection of an input image located on the target disk.
- Raw DD and compressed DD read-back comparison against the input stream.

These checks reduce risk; they do not eliminate device-replacement races, failing hardware, operating-system bugs or user selection errors. A failed or cancelled write can leave an unusable, partially overwritten disk. There is no undo or recovery promise.

## Development-only virtual targets

`RUFUS_ALLOW_VIRTUAL_DISKS=1` enables disk images as targets. It does **not** restrict the app to virtual disks. The orange development banner is intentional. Use a disposable VM/Space without physical disk passthrough for automated write tests, and verify the target's backing image before every run.

## Windows silent install

Silent-install media can wipe **Disk 0 on the computer booted from that media**, without asking during installation. This is separate from erasing the USB target on the Mac. Do not enable silent install on media intended for general distribution.

## Validation boundary

Recorded writes were tested on disk images in a macOS Cua Space. No complete Windows installation or physical USB write has been established by those tests. A valid byte comparison is not proof of bootability.

NTFS media creation is not offered: the tested Apple NTFS driver mounted volumes read-only. Adding a writable filesystem implementation is a separate dependency and safety decision; users are not required to install a kernel extension for the current preview.
