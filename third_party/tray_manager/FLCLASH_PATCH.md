# FlClash tray_manager patch

This directory vendors `tray_manager` 0.5.2 from pub.dev under its MIT
license. The macOS implementation uses `NSStatusBarButton` directly and caches
the last title, based on the fix proposed in
`chen08209/tray_manager#1` (`ca201c0146f49b87d2b8a2a5760fa228ad7cd29b`).

It is vendored so FlClash does not depend on a personal Git repository at
build time. Linux, Windows, and the Dart API remain identical to 0.5.2.
