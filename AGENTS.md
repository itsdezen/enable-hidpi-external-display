# enable-hidpi-external-display

Single-file bash tool (`enable-hidpi-external-display.sh`) that injects HiDPI display-override
profiles into `/Library/Displays/Contents/Resources/Overrides` on macOS 26+.

## Hard rules

- macOS 26 (Tahoe) or later only. No backward compatibility.
- Never write anywhere under `/System`. Only `/Library/Displays/...`.
- The built-in display (and any Apple-branded display, VendorID `0610`) must
  never be selectable or touched — this is checked before any display list
  is shown, not just at write time.
- `Icons.plist` is merged (via `PlistBuddy`), never overwritten wholesale —
  other displays' icons must survive untouched.
- English only, no i18n tables.
- Bash 3.2 compatible (macOS ships no newer bash by default): no
  associative arrays, no `${var,,}`, no `mapfile`.
- Watch for the `IFS=x arr=(...)` leak: it only scopes temporarily before a
  real command, not before a bare assignment. Use `local IFS=` or
  save/restore explicitly.

## Layout

- `enable-hidpi-external-display.sh` — all logic.
- `enable-hidpi-external-display.command` — double-click launcher, just calls `enable-hidpi-external-display.sh`.

## Testing

No test suite. Verify by sourcing the script (`source ./enable-hidpi-external-display.sh`) and
calling functions directly — the `main` entry point is guarded so sourcing
doesn't execute it. Never run the real `sudo` install path against this
machine's display without explicit confirmation.

## Git conventions

- Commit subjects use Conventional Commits: `<type>(<scope>): <summary>`;
  omit the scope when it adds no clarity. Use lowercase types such as
  `feat`, `fix`, `docs`, `refactor`, `chore`, and `test`.
- Write concise English summaries that explain the change; do not add a
  trailing period. Keep the subject focused on one change.
- Name topic branches with up to three lowercase, hyphen-separated words;
  do not use slash-separated type prefixes (for example, `display-recovery`).
- Keep `main` as the stable branch. Push a topic branch to its matching
  origin branch.
