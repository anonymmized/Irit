# Contributing

Thanks for contributing to `Irit`.

## Development expectations

- Keep the project Bash-first and dependency-light.
- Prefer clear operational safety over clever shortcuts.
- Preserve compatibility with Ubuntu and Debian targets.
- Avoid destructive behavior unless explicitly requested by the user.

## Before opening a pull request

Run:

```bash
bash -n fastserver.sh irit.sh
shellcheck fastserver.sh irit.sh
./irit.sh --help
```

## Pull request guidelines

- Explain the operational impact of the change.
- Mention whether setup, report, access, rollback, or doctor behavior changed.
- Update `README.md` when UX, flags, or outputs change.
- Update `CHANGELOG.md` for visible improvements.

## Good first contributions

- Improve diagnostics in `doctor` mode.
- Expand client bundle exports.
- Improve README examples and troubleshooting.
- Add safer validations around ports and prerequisites.
