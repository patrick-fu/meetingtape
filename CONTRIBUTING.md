# Contributing

- **Focus.** Solve one problem per PR and follow existing code patterns.
- **Discuss.** Bring new features, architecture, and compatibility changes to an issue; send small fixes directly as PRs.
- **Preserve.** Keep recordings, recovery materials, and settings intact. Store credentials in Keychain and use synthetic or sanitized test fixtures.
- **Submit.** Branch from `main`, use sentence-style commit titles, and open a PR. Maintainers handle versioning and releases.
- **Changelog.** Use version headings and pair each English line with its Chinese translation immediately below, joined by a Markdown hard break. Apply this format to `CHANGELOG.md` and release notes.

## Verify

With an Apple Silicon Mac, macOS 14.2+, and Xcode command-line tools:

```sh
./scripts/build-apm.sh
swift test
```

- **Exercise.** Verify fixes with a reproducer and UI changes in light and dark mode. See [signed App and device checks](docs/local-verification.md).

## Pull requests

- **Explain.** Lead with the problem and resulting behavior. Write for a reviewer new to the change.
- **Show.** Prefer visuals: before/after screenshots for UI, flowcharts for logic, sequence diagrams for async work, and component or dependency diagrams for structure. Keep each diagram beside its explanation.
- **Compare.** Show behavior changes with short pseudocode diffs. For example:

```diff
 on save
+  if saving: return
+  mark saving
-  await save()
+  try: await save()
+  finally: clear saving
```

- **Evidence.** Include actual check results and remaining checks; link supporting files or logs.
- **Impact.** Explain compatibility, data changes, and rollback when relevant. Match the detail to the change.
