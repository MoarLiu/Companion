# Changelog

## Companion 0.1.0 (2026-06-19)

### Changed

- Reset the project boundary around Companion itself: XiaoHuaEr, lightweight AI chat and translation settings, Journal, reminders, Pomodoro, Focus Review, asset upload, local workflow history, and the Companion MCP tools.
- Removed inherited developer-tooling surfaces from the app, tests, resources, and documentation.
- Rebuilt the dashboard and menu around Companion-owned actions and lightweight AI settings.
- Restructured the menu bar into user-facing groups: Dashboard, Reminders, Pomodoro, Journal, Focus, AI Quick Actions, Companion Data, update, and quit.
- Replaced inherited app/menu bar artwork with Companion-owned icon assets and README artwork.
- Reworked README.md for the initial GitHub repository with product scope, privacy boundaries, AI settings, MCP tools, build, package, and release instructions.
- Regenerated localization resources from the current Swift source keys so unused historical strings are no longer bundled.

### Release

- Prepared local release artifact: `Companion-0.1.0-macos-arm64-build4.zip`.
- DMG packaging is supported by `scripts/package-dmg.sh`, but the current sandbox could not complete `hdiutil create` (`设备未配置`). Run the same script from a normal macOS terminal for the final DMG.

### Tests

- `swift build --product Companion`
- `bash scripts/run-tests.sh`
- `npm run lint` in `website`
- `npm run build` in `website`
