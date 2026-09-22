# Architecture

## Trust boundary

The QML panel is an unsandboxed third-party component loaded into
`omarchy-shell`. It never executes printer-provided text. All CUPS interaction
goes through `backend/printers.py` using structured argument arrays and a
versioned JSON response.

The backend writes exactly one JSON response to stdout. Diagnostics go to
stderr, where Quickshell records them in its log. User-facing errors use stable
error codes and short messages rather than raw CUPS, D-Bus, or subprocess
output.

All plugin-owned `Text` elements explicitly use `Text.PlainText`, including
row titles, status messages, option labels, and reusable text components.
The shared Omarchy `Dropdown`, `SearchableDropdown`, and `ConfirmDialog`
components must also render their dynamic labels and messages as plain text;
the installed versions were checked for this contract. Markup in printer
metadata remains literal data rather than formatting or image references.

Before emitting JSON, the backend rejects strings longer than 4,096 characters,
more than 256 queues, 1,000 jobs, 10,000 driver models, 256 options or choices,
or 100 discovery results. Other collections are limited to 1,024 entries.
Nested data is limited to 12 levels, 100,000 nodes, and a total encoded response
of 4 MiB. Errors and diagnostics are length-limited too. Oversized data produces
a controlled error; identifiers and option values are never silently truncated.
Settings and jobs are checked separately so one oversized section does not
hide the other. These are limits on data passed to the shell, not memory limits
on CUPS or the backend's initial retrieval from its dependencies.

## Shell surfaces

`PrinterQuickPanel.qml` is a `bar-widget` built on Omarchy's shared `Panel` and
`KeyboardPanel` components. It shows installed-printer CUPS status and all
defaults exposed by the local queue, then links to `PrinterPanel.qml` for full
administration. The quick popup deliberately excludes add/remove, pause,
legacy discovery, and test-page actions.

The quick widget reads installed queues once when its bar instance starts,
then serves popup opens entirely from memory. Successful mutations in the full
panel trigger another lightweight CUPS queue read; they do not run device
discovery. Status labels reflect CUPS queue state—Ready, Printing, Paused, or
Needs attention—rather than network rediscovery.

The full settings surface opens with only a fast installed-queue read. It does
not run discovery on open or periodically. **Scan results** appears only after
the user explicitly starts **Network scan** or **Full scan**, and each scan
shows only its own current results. Network scan remains unprivileged; only
Full scan can invoke privileged discovery. Changing defaults is an explicit
mutation and may invoke PolicyKit only after the user chooses **Save defaults**.

Selecting an installed queue opens a unified management dashboard. Its compact
queue actions stay fixed above one scrollable surface containing printer
settings and print jobs. A single `manage` read combines the existing options
and jobs adapters, avoiding serial loading phases while preserving the
standalone protocol commands. Settings and jobs can fail independently; the
affected section shows a load error while the other remains available.
Cancelling a job reloads only jobs, preserving unsaved settings. The dashboard
does not poll.

## Read path

- pycups reads installed queues, printer attributes, jobs, defaults, and local
  model metadata.
- The backend `manage` command reads one queue's supported/default options and
  jobs together. This is a read-only aggregation; writes still use their
  dedicated commands.
- The unprivileged CUPS `driverless` helper handles normal launch and
  **Network scan**, so opening the panel never asks for administrator approval.
- The explicit **Full scan** action uses `cups-pk-helper` because CUPS protects
  legacy `getDevices()` discovery on the default Omarchy installation.
- If that discovery call is unavailable, the CUPS `driverless` helper keeps
  IPP printers visible. Legacy discovery is retried on the next explicit Full scan.
- Device records are normalized and deduplicated before reaching QML.

## Write path

Privileged queue changes use the system
`org.opensuse.CupsPkHelper.Mechanism` D-Bus service. PolicyKit prompts are
handled by Omarchy's existing authentication agent. The plugin does not embed
credentials, add the user to printer-administration groups, or invoke a shell.

## Device identity

Identity is independent of a user-visible queue name:

1. Printer UUID when advertised.
2. IEEE 1284 manufacturer/model/serial identity.
3. DNS-SD service identity with IPP/IPPS normalized together.
4. Normalized device URI as a final fallback.

This identity drives installed-device association and cursor preservation.
Model metadata without a serial number does not establish identity. Installed
queues are matched by identity or normalized URI, never by display name or
model description. When a host URI and a DNS-SD service cannot be associated
by either, the discovery record remains available. A matched record remains in **Scan
results** as a non-actionable **Installed** row. Installed-printer status comes
only from CUPS queue state, independent of discovery results.

## Driver selection

Driverless IPP is preferred whenever supported. Legacy devices are matched
only against models already available from the local CUPS server. Matching is
deterministic and explainable; the UI shows the recommendation and requires
confirmation. The plugin never downloads or executes vendor software.
