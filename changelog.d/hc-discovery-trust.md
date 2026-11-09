### Fixed
- Looking for herdr-core no longer runs an `hc` or `herdr-core` from a folder another account can
  change on Linux and macOS, nor lets one it runs find its helpers in such a folder, and the usual
  install places now come before the PATH (on Windows too). A path set in `OVIS_HC_BIN` is still
  run as named.
- A Portal visitor that drives a PC can no longer switch its runtime between herdr and herdr-core,
  nor read which runtime and herdr-core session it serves.
