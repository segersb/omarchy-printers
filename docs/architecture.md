# Architecture

## Trust boundary

The QML panel is an unsandboxed third-party component loaded into
`omarchy-shell`. It never executes printer-provided text. Queue administration goes through
`backend/printers.py` using structured argument arrays and a versioned JSON
response. Separate helpers read optional attributes, listen for CUPS events,
and handle document printing, as described below.

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

`PrinterService.qml` owns one `backend/watch.py` process and the shared queue
cache. The helper registers a CUPS D-Bus push subscription and emits only fixed
`ready`, `changed`, and `unavailable` tokens; signal payloads never reach QML.
Events are coalesced for 250 ms. A separate, serialized `status` backend read
returns queues and, only for an open dashboard, that queue's jobs. UI updates
preserve pending option edits and do not use the administrative process.

The listener renews its finite lease halfway through the server-granted duration.
It cancels its subscription on shutdown, listens for CUPS/systemd lifecycle
events, and makes one recovery attempt after a helper disconnect. Failed recovery
waits for a lifecycle event or explicit panel opening. No periodic status reads,
network discovery, or indefinite reconnect loop runs in the background.

The service is exposed through the plugin's own `serviceFor` interface. The
read-only `segersb.omarchy-printers.quick status` IPC command reports monitoring
health and cached queue states for diagnostics. Hosts without own-service access
retain opening-time reads and do not start another listener.

The full settings surface opens with only a fast installed-queue read. It does
not run discovery on open or periodically. **Scan results** appears only after
the user explicitly starts **Network scan** or **Full scan**, and each scan
shows only its own current results. Network scan remains unprivileged; only
Full scan can invoke privileged discovery. Changing defaults is an explicit
mutation and may invoke PolicyKit only after the user chooses **Save defaults**.

Selecting an installed queue opens a unified management dashboard. Its compact
queue actions stay fixed above separate Settings, Print jobs, and Attributes
tabs. Settings opens first; only the active tab’s content is shown. A single `manage` read combines the existing options
and jobs adapters, avoiding serial loading phases while preserving the
standalone protocol commands. Settings and jobs can fail independently; the
affected section shows a load error while the other remains available.
Cancelling a job reloads only jobs, preserving unsaved settings. The dashboard
refreshes its job list on events and does not poll.

Optional Attributes data comes from `backend/printer_info.py`. It reads local
CUPS metadata and, for IPP/IPPS queues, attempts a direct device query to obtain
supplies and capabilities that CUPS may omit. DNS-SD addresses are resolved
through Avahi. The device query has a six-second timeout and falls back to local
details. QML caps the entire helper at twelve seconds; helper processes also
have 512 MiB address-space and ten-second CPU limits.

Both local and direct responses pass the shared payload bounds before field
normalization. Only recognized fields with validated shapes reach QML: text,
string lists, boolean color support, numeric supply levels, and resolution
triples. Invalid optional values are omitted or replaced with unknown entries
without shifting supply indexes. The encoded result is validated again before
emission. Attributes refresh when a printer is opened; supplies are not polled.

## Read path

- pycups reads installed queues, printer attributes, jobs, defaults, and local
  model metadata.
- The backend `manage` command reads one queue's supported/default options and
  jobs together. This is a read-only aggregation; writes still use their
  dedicated commands.
- The unprivileged CUPS `driverless` helper handles **Network scan**. Opening
  the panel reads installed queues only and never asks for administrator approval.
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

## Print portal and documents

`backend/print_portal.py` owns the user D-Bus backend name and implements
PreparePrint, Print, and Request.Close. Only the desktop portal owner may call
those methods. A separate same-user OpenImage method supports the Nautilus action.
Each request has a random UI identifier, private runtime directory, independent
settings and single-use portal token. The token binds the prepare and print calls
to the app ID; the UI is not shown a file path supplied by an application.

The QML print surface uses a JSON-lines bridge over a private Unix socket, with
peer-UID checks. Closing it cancels its request. State remains isolated across up
to eight simultaneous dialogs. UI edit revisions and backend render generations
prevent printing an outdated preview. Submitting changes state before starting
CUPS I/O; there is no automatic submission retry after an ambiguous error.

Chrome sends a document after PreparePrint returns. The backend resolves that
handshake automatically using incoming settings with CUPS defaults as fallback;
there is no user-facing preparation step. The preparation response preserves the
application's scale hint, asks for one copy and all pages; this backend applies final page selection,
per-page zoom/position, copies and duplex exactly once. This provider deliberately adds a final
preview/confirmation after Print receives the document. Token-bearing calls are
acknowledged once all document bytes have been received: the response confirms
local handoff, not CUPS submission. The local preview then owns cancellation and
final confirmation, independent of the application's portal-request lifetime.
No-token requests retain normal portal cancellation until confirmation. Printer, paper and orientation remain editable in the final preview;
changing them transforms the existing document rather than asking the application
to reflow it. Direct images and no-token documents skip the application-rendering wait.

`backend/print_document.py` runs in a separate process with memory, CPU, file-size
and wall-time limits. Poppler normalizes PDF rotation and crop-box origins; Cairo
clips and transforms content into the selected paper's imageable area, retaining
vector output where supported by Poppler/Cairo. CUPS receives the transformed PDF. The interactive preview places a raster of
the original page using the same scale, offsets and clipping, so dragging and
zooming update immediately. Adjustments use original page numbers, remaining
stable across page selection changes. No content detection or optional Python
imaging/PDF packages are needed.
Document bytes and page counts are capped; temporary files are removed after
completion/cancellation, and abandoned runtime directories are removed at startup.

Setup registers only user-owned D-Bus, portal, desktop and Nautilus files. It
stores prior Print preference state, preserves other portal keys and external
edits, and never changes image-viewer defaults or installs dependencies. Restore
integration before uninstalling. Image metadata and document/printer titles stay
plain text in QML, and subprocess calls use argument arrays throughout.

The System integration panel is reachable directly from the bar popup. It manages three independent opt-in integrations: the user
system-config-printer launcher and UWSM PATH snippet, Print portal selection,
and the Files image action. Portal and Files share one D-Bus activation file,
retained until neither needs it. Version 2 ownership state imports the earlier
combined registration without changing anything during status inspection.
Setup serializes writes, checks owned contents before replacing or removing
files, and recognizes only the exact earlier printer launcher for adoption.
Before changing files it journals both existing ownership and intended contents.
On retry or restore, only either exact recorded version is accepted; external
edits still fail preflight. Pending portal preference changes remain recorded
until the operation completes, so interrupted restores can be retried.
There is no Omarchy uninstall hook: users must restore integrations before
removing or moving the plugin.
