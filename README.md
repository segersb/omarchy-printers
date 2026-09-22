# Omarchy Printers

A printer settings panel built for Omarchy Shell, intended to replace the
traditional `system-config-printer` screens and bring printer management into
Omarchy. Manage printers, defaults, and print jobs in one keyboard-first panel,
with a compact bar popup for status and quick settings.

The optional [system dialog override](#replace-the-system-printer-settings-dialog)
also makes Chrome's printer-management button open this panel. The longer-term
goal is to make this experience part of Omarchy itself; today it is distributed
as a community plugin.

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

Opening the panel and using **Network scan** are read-only and do not request
administrator approval. **Full scan** searches all CUPS transports and may show
a PolicyKit prompt; cancelling it leaves installed and driverless printers
available.

## Install

Install and enable the plugin:

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

Enabling the plugin adds its printer icon to the right side of the bar. Click
it for cached CUPS queue state and configurable defaults. Opening the popup
does not scan for printers. Its queue state updates when the widget starts and
after printer changes made through the full settings panel.

The full settings panel can also be opened directly:

```bash
omarchy-shell shell summon segersb.omarchy-printers '{}'
```

The full panel opens with installed printers only and never scans
automatically or periodically. Choose **Network scan** or **Full scan** to show
a **Scan results** section containing that scan's current results. Printers
already configured in CUPS remain visible there as **Installed**; new printers
can be installed by selecting their entire row.

Selecting an installed printer opens one management dashboard. Queue actions
stay at the top, with **Printer settings** and **Print jobs** visible together
below. Changed settings are applied only through **Save defaults**; the action
is unavailable while the loaded defaults are unchanged.

To add it to the Omarchy menu, merge
[`docs/omarchy-menu.jsonc`](docs/omarchy-menu.jsonc) into:

```text
~/.config/omarchy/extensions/omarchy-menu.jsonc
```

The plugin installer intentionally does not run install hooks, so this menu
entry is opt-in.

## Replace the system printer settings dialog

After installing and enabling the plugin, you can make applications that
launch `system-config-printer` through `PATH` open the Omarchy panel instead.
This has been tested with Chrome on Omarchy. It replaces the printer-management
screen, not an application's print preview or document print dialog.

Create this executable at `~/.local/bin/system-config-printer`:

```sh
#!/bin/sh
exec omarchy-shell shell summon segersb.omarchy-printers '{}'
```

Make it executable:

```bash
chmod +x ~/.local/bin/system-config-printer
```

The directory must precede `/usr/bin` in the desktop session's `PATH`; a shell
alias does not affect Chrome. Create `~/.config/uwsm/env.d/90-local-bin-first`
(create the parent directory if needed) with:

```sh
case "$PATH" in
  "$HOME/.local/bin"|"$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
```

**Log out and back in**, then open Chrome and try its printer-management
button. Existing processes keep their old environment. In a new terminal,
`command -v system-config-printer` should show the launcher in your home
directory. This PATH change gives all executables in `~/.local/bin` precedence
over matching system commands.

The packaged dialog remains available as `/usr/bin/system-config-printer`.
Applications that launch that absolute path bypass the override.

To undo the override, remove the launcher created above:

```bash
rm ~/.local/bin/system-config-printer
```

You can also remove `~/.config/uwsm/env.d/90-local-bin-first` if you added it
solely for this override, then log out and back in to restore PATH ordering.

## Update and remove

If you enabled the system dialog override, remove it before disabling or
removing the plugin so applications can open the packaged dialog again.

```bash
omarchy plugin update segersb.omarchy-printers
omarchy plugin remove segersb.omarchy-printers
```

## Keyboard controls

Quick popup:

- `j` / `k` or arrows: move through printers and defaults
- `Enter` or Space: activate
- `Esc`: close

Full settings:

- `j` / `k` or arrows: move
- `Enter` or Space: activate
- `r`: scan for driverless network printers
- `f`: scan all CUPS transports (may request administrator approval)
- `Esc`: go back or close
- Tab: move through form controls

On the management dashboard, navigation follows its visual order: queue
actions, setting dropdowns, **Save defaults** when settings have changed, then
job cancellation. Moving above the first item focuses **Back** so it can be
activated from the keyboard. Dropdowns retain the navigation keys while open.

The compact popup intentionally omits administrative actions such as adding,
removing, pausing, and printing a test page. Use **Open printer settings** for
the full panel.

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
- **A legacy printer is missing:** choose **Full scan** or press `f`, then
  approve the system prompt. Cancelling is safe.
- **A driver is missing:** install the vendor/CUPS driver package separately;
  this plugin only offers models already installed on the system.
- **An action is denied:** retry it and approve PolicyKit, or inspect the
  shell log using the command above.

## Safety

Installing the plugin does not automatically change system printer launchers.
The optional user-level override above redirects `system-config-printer`
launches without modifying the packaged executable, desktop entries, or Chrome.
