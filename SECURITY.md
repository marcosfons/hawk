# Security and privacy

Hawk reads a lot about your Mac and can change fan speeds and delete caches, so
its limits matter more than its features.

## What Hawk does and does not do

- **Local.** Nothing leaves your Mac. There is no network code apart from
  measuring traffic.
- **One root process, small on purpose.** `hawkd` (installed only with
  `sudo make install-helper`) sets fan speeds and reads process counters. Its
  socket accepts admin users only; it clamps every speed to the fans' own
  limits and gives the fans back to macOS when Hawk disconnects, goes quiet for
  5 seconds, the chip reaches 90 °C, or it is stopped.
- **Deletes only what you confirm**, one item at a time, after checking that the
  app owning the files is not running. WhatsApp data, Xcode archives and backups
  are never offered for deletion. Every deletion is logged.
- **Read-only where it reads other apps' data**: WhatsApp's database is opened
  with `SQLITE_OPEN_READONLY`.
- Logs (`~/Library/Logs/Hawk/`) record warnings, errors and timings, not file
  contents.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting
(**Security > Report a vulnerability** on this repository) rather than a public
issue.
