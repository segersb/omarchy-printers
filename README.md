# Omarchy Printers

A printer settings panel built for Omarchy Shell, intended to replace the
traditional `system-config-printer` screens and bring printer management into
Omarchy. Manage printers, defaults, and print jobs in one keyboard-first panel,
with a compact bar popup for status and quick settings. A shared print dialog
also offers print zoom and positioning from Chrome or directly from PNG/JPEG images.

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
- `python-gobject` (GLib event loop for CUPS notifications)

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
it for CUPS queue state and configurable defaults. The printer icon uses the
current theme’s accent color while CUPS reports a queue is processing; problems
use the urgent color.

A shared CUPS notification listener updates the bar and open panels when
printers or jobs change. There is no status polling or automatic network scan.
The listener renews its notification subscription before its lease expires.
Opening a panel also refreshes status once. Background updates preserve unsaved
defaults. Job lists update live while their printer dashboard is open.

If notifications are unavailable, the tooltip says **Live status unavailable**
and the printing highlight is cleared. Opening a panel retries the listener
and refreshes status; it never silently enables polling. Replacement bars that
cannot access plugin services use opening-time refreshes.

“Printing” reflects CUPS processing, which can include preparing or transferring
a job; it does not guarantee that paper is moving. Page percentages and desktop
notifications are not included.

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
stay at the top, above separate **Settings**, **Print jobs**, and **Attributes**
tabs. Attributes show available printer details and supply levels; unsupported
information is omitted. Changed settings are applied only through **Save defaults**; the action
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

Open the bar popup → **System integration** → **Printer settings** and turn on its toggle.
This creates a user launcher and an owned UWSM login configuration that puts
`~/.local/bin` first in the desktop session PATH. **Log out and back in** to
activate the change. This PATH ordering also gives other executables in that
directory precedence over matching system commands.

The packaged dialog remains available as `/usr/bin/system-config-printer`;
applications using that absolute path bypass the override. Turning the toggle off removes
only the plugin-owned launcher and login configuration. Existing PATH settings,
including the earlier manually created `90-local-bin-first`, remain unchanged.
The exact launcher from earlier versions is recognized and can be restored here.

The integration panel also independently enables the **System print dialog**
and **Print from Files**. Each has its own toggle; **Enable all** enables the
remaining integrations. Files printing does not require changing the system Print provider.
Existing integration files are never overwritten without an ownership record;
externally edited files are retained and reported for manual resolution. If a
setup change is interrupted, retry it or choose **Restore defaults**; the
ownership record retains both the previous and intended file contents.

## Update and remove

Before disabling, removing, or moving the plugin, open **System integration**
and choose **Restore defaults**. Omarchy’s removal command does not run plugin cleanup.
Close print dialogs first; restore restarts the desktop portal and attempts to
restart Files. Log out and back in to apply changes to the printer settings launcher. The same recovery action is available as
`python3 backend/print_setup.py restore all` from the plugin directory.

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
actions, tabs, then the active tab’s controls. **Save defaults** becomes
available when settings change; job cancellation is in **Print jobs**. The
default-printer star is skipped once that printer is already the default. Moving above the first item focuses **Back** so it can be
activated from the keyboard. Dropdowns retain the navigation keys while open.

The compact popup intentionally omits administrative actions such as adding,
removing, pausing, and printing a test page. Use **Printer settings** for
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

## Print dialog and image printing

The shared print dialog has a fixed paper preview, **10–400% print zoom**, and
**drag-to-position**. **Ctrl + scroll** over the sheet zooms in 5% steps around
the pointer. Changes affect the printed output; anything outside the
outlined printable area is clipped. Each page keeps its own adjustment.
**Reset page** restores 100% and centers it; **Apply to all pages** copies the
current zoom and position to every page. The preview uses the same placement
and hardware margins as the output PDF, with no content or whitespace detection.

Open the bar popup → **System integration** and enable **System print dialog**.
Enable **Print from Files** separately for the PNG/JPEG context menu. Close open print dialogs before enabling or restoring;
setup restarts the desktop portal. After enabling or disabling the Files action, the plugin attempts to restart
Files and reopen its folder locations. If Files cannot quit, it is left running
without an error; the change takes effect on its next full restart or login. Other portal preferences and the default image viewer are preserved.

- **From Chrome:** choose **Print using system dialog**. The plugin automatically
  uses Chrome's current paper settings (or printer defaults when unavailable) to
  obtain the document and open its preview. Change printer, paper, orientation,
  copies, color, duplex or sizing, then choose **Print**. Paper changes resize the
  output sheet; they do not reflow webpage text or change Chrome's pagination.
  Once the document has arrived, the plugin owns the preview. Chrome's request
  finishes at that handoff; printing still requires **Print** in this dialog.
- **From Files:** right-click one local PNG or JPEG → **Print**. The original
  image opens directly in the preview. Paper and orientation remain editable.
  Transparent pixels print on white; JPEG orientation metadata is respected.
  100% uses embedded DPI when valid, otherwise 96 DPI.
- **From a terminal:** `python3 backend/print_portal.py image /absolute/path/image.png`
  from the plugin directory, after enabling integration.

Turn off individual integrations using their toggles, or choose **Restore
defaults** to disable them all. Do this **before removing or moving the plugin**. Integration uses absolute paths to the installed plugin;
there are no package installs or copied backend binaries. To repair registration
after moving a development checkout, restore from the new checkout, then enable.

Printing uses Omarchy's existing `poppler-glib` (through Evince), `python-cairo`
(through system-config-printer), GTK/GdkPixbuf, and the existing Python CUPS/D-Bus
bindings. It does not need Pillow, pypdf, or pip. Setup checks these components
before making changes. A minimal/custom installation missing them shows a
missing-component message rather than installing anything.

The system route supports applications using the Print portal, not applications
that create GTK dialogs directly. V1 accepts PDF portal documents and local
PNG/JPEG images, with up to 500 PDF pages, 128 MiB input, and 40-megapixel images.
It does not provide print-to-file or content-aware cropping. For Chrome documents,
100% refers to the received PDF, including any margins and scaling Chrome applied. Requests expire after 15 minutes, and cancellation never submits a job.
