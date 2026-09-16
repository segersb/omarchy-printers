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

## Shell surfaces

`PrinterQuickPanel.qml` is a `bar-widget` built on Omarchy's shared `Panel` and
`KeyboardPanel` components. It shows installed-printer presence and all
defaults exposed by the local queue, then links to `PrinterPanel.qml` for full
administration. The quick popup deliberately excludes add/remove, pause,
legacy discovery, and test-page actions.

The quick widget reads installed queues once when its bar instance starts,
then serves popup opens entirely from memory. Successful mutations in the full
panel trigger another lightweight CUPS queue read; they do not run device
discovery. Status labels reflect CUPS queue state—Ready, Printing, Paused, or
Needs attention—rather than network rediscovery.

The full settings surface opens with only a fast installed-queue read. It does
not run discovery on open or periodically. **Detected** appears only after the
user explicitly starts **Network scan** or **Full scan**, and each scan shows
only its own current results. Network scan remains unprivileged; only Full scan
can invoke privileged discovery. Changing defaults is an explicit mutation and
may invoke PolicyKit only after the user chooses **Save defaults**.

## Read path

- pycups reads installed queues, printer attributes, jobs, defaults, and local
  model metadata.
- The unprivileged CUPS `driverless` helper handles normal launch and
  **Network scan**, so opening the panel never asks for administrator approval.
- The explicit **Full scan** action uses `cups-pk-helper` because CUPS protects
  legacy `getDevices()` discovery on the default Omarchy installation.
- If that discovery call is unavailable, the CUPS `driverless` helper keeps
  IPP printers visible while the panel clearly warns that some printers may
  be missing. Legacy discovery is retried on the next refresh.
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

This identity drives Installed/Detected filtering and cursor preservation.
When CUPS exposes an installed queue only by host URI while discovery exposes
only its DNS-SD service, an exact normalized queue/service name is used as a
final association fallback. A matched discovery record is removed from
Detected and shown as **Seen on network** on the installed queue. CUPS queue
state and recent discovery presence remain separate so a paused queue is not
reported as offline.

## Driver selection

Driverless IPP is preferred whenever supported. Legacy devices are matched
only against models already available from the local CUPS server. Matching is
deterministic and explainable; the UI shows the recommendation and requires
confirmation. The plugin never downloads or executes vendor software.
