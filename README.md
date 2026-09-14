# Omarchy Printers

A keyboard-first Omarchy Shell panel for discovering, adding, and managing
local CUPS printers.

![Installed printer view](docs/screenshots/installed.png)

## Scope

- Driverless IPP/IPPS printers
- CUPS-discovered USB and network printers
- Locally installed CUPS drivers and PPDs
- Default printer, queue pause/resume, print jobs, printer defaults, test page,
  and queue removal

The plugin does not download vendor drivers, install packages, collect SMB
credentials, administer remote CUPS servers, or manage printer classes and
sharing.

## Requirements

Current Omarchy installations already include the required packages:

- `cups`
- `cups-pk-helper`
- `python-pycups`
- `python-dbus`

CUPS must be running. Privileged actions use the system CUPS PolicyKit helper
and Omarchy's existing authentication agent.

Opening the panel and using **Refresh** are read-only and do not request
administrator approval. **Find more** searches legacy CUPS transports and may
show a PolicyKit prompt; cancelling it leaves installed and driverless
printers available.

## Install

Once this repository is published:

```bash
omarchy plugin add https://github.com/segersb/omarchy-printers.git --enable
```

For local development:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/segersb.omarchy-printers
omarchy-shell shell rescanPlugins
omarchy plugin enable segersb.omarchy-printers
```

## Open

```bash
omarchy-shell shell summon segersb.omarchy-printers '{}'
```

To add it to the Omarchy menu, merge
[`docs/omarchy-menu.jsonc`](docs/omarchy-menu.jsonc) into:

```text
~/.config/omarchy/extensions/omarchy-menu.jsonc
```

The plugin installer intentionally does not run install hooks, so this menu
entry is opt-in.

## Update and remove

```bash
omarchy plugin update segersb.omarchy-printers
omarchy plugin remove segersb.omarchy-printers
```

## Keyboard controls

- `j` / `k` or arrows: move
- `Enter` or Space: activate
- `r`: refresh the printer list
- `f`: find additional legacy printers (may request administrator approval)
- `Esc`: go back or close
- Tab: move through form controls

## Development

```bash
./test
```

The backend emits versioned JSON on stdout and diagnostics on stderr. Its tests
use fake CUPS and D-Bus adapters and do not modify the host's printer setup.
See [`docs/architecture.md`](docs/architecture.md) for the trust boundary,
device identity rules, and driver-selection design.

### Local checks

```bash
./test
omarchy-shell shell summon segersb.omarchy-printers '{}'
journalctl --user --since "1 minute ago" --no-pager |
  rg 'omarchy-printers|PrinterPanel'
```

## Troubleshooting

- **No printers appear:** confirm CUPS is running with
  `systemctl status cups`.
- **A legacy printer is missing:** choose **Find more** or press `f`, then
  approve the system prompt. Cancelling is safe.
- **A driver is missing:** install the vendor/CUPS driver package separately;
  this plugin only offers models already installed on the system.
- **An action is denied:** retry it and approve PolicyKit, or inspect the
  shell log using the command above.

## Safety

This plugin does not replace `system-config-printer`, alter desktop entries, or
change Chromium's printer-manager command.
