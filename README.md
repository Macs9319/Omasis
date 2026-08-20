# Omasis

A community plugin marketplace browser for the [Omarchy](https://omarchy.org/)
shell bar. Browse, search, and filter the plugin registry behind
[omarchyplugins.com](https://omarchyplugins.com) and install anything in it
with one click — all from the bar, no browser or terminal required.

## Install

**Option 1 — `omarchy plugin add` (recommended):**

```bash
omarchy plugin add https://github.com/Macs9319/Omasis.git --enable
```

You'll be prompted to pick a bar section (left/center/right) for the icon.

**Option 2 — manual clone:**

```bash
git clone https://github.com/Macs9319/Omasis.git ~/.config/omarchy/plugins/omasis
omarchy plugin enable omasis right
```

Either way, the shell picks up the plugin without a restart — edits under
`~/.config/omarchy/plugins/` hot-reload automatically.

## Usage

Click the 🧩 bar icon to open the browser. Type in the search box to filter by
name, author, or tag; click a category chip to narrow the list further.

Each card shows an install button:

- **Get** — installs the plugin directly via `omarchy plugin add`, the same
  CLI you'd run by hand. Clone, manifest validation, and enabling are all
  handled by that command.
- **View** — opens the plugin's repo on GitHub instead. Used for plugin
  suites, entries the registry flags as needing manual setup, and
  repositories that bundle more than one plugin (which `omarchy plugin add`
  can't install a single one from yet).
- **✓ Installed** — already present on this system.

A ↻ refresh button in the header re-fetches the registry on demand; it also
refreshes automatically once an hour.

## Data source

The registry data comes from
[`HANCORE-linux/omarchy-plugin-marketplace`](https://github.com/HANCORE-linux/omarchy-plugin-marketplace)
— the same feed that backs omarchyplugins.com. Most entries in that registry
carry only an id, category, and tags (no name/description/author), so Omasis
derives a display name from the plugin id and an author from the repo owner
where the registry doesn't supply them directly.

## Configuration

Settings live on the plugin's bar entry in `~/.config/omarchy/shell.json`
(hot-reloads on save). Defaults:

| Setting | Default | Meaning |
|---|---|---|
| `refreshHours` | `1` | How often to re-fetch the registry (minimum 1) |

Example entry:

```json
{ "id": "omasis", "refreshHours": 6 }
```

## Uninstall

```bash
omarchy plugin remove omasis
```

## License

MIT — see [LICENSE](LICENSE).
