#!/usr/bin/env python3
"""Versioned JSON interface to CUPS and cups-pk-helper."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import unicodedata
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Protocol, Sequence
from urllib.parse import parse_qsl, quote, unquote, urlencode, urlsplit, urlunsplit

API_VERSION = 1
PK_NAME = "org.opensuse.CupsPkHelper.Mechanism"
PK_PATH = "/"
PK_INTERFACE = PK_NAME
DISCOVERY_TIMEOUT = 8
MAX_DEVICES = 100


@dataclass
class BackendError(Exception):
    code: str
    message: str
    exit_code: int = 1
    diagnostic: str | None = None

    def __str__(self) -> str:
        return self.message


class CupsAPI(Protocol):
    def preflight(self) -> Mapping[str, Any]: ...
    def queues(self) -> tuple[str | None, list[dict[str, Any]]]: ...
    def models(self) -> list[dict[str, Any]]: ...
    def jobs(self, queue: str | None = None) -> list[dict[str, Any]]: ...
    def options(self, queue: str) -> dict[str, Any]: ...
    def test_page(self, queue: str) -> int | None: ...


class HelperAPI(Protocol):
    def preflight(self) -> Mapping[str, Any]: ...
    def devices(self, timeout: int = DISCOVERY_TIMEOUT) -> list[dict[str, str]]: ...
    def mutate(self, method: str, *args: Any) -> None: ...


def _text(value: Any) -> str:
    if value is None:
        return ""
    return str(value)


def _slug(value: str) -> str:
    value = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("._-")
    return value[:127] or "printer"


def unique_queue_name(label: str, existing: Iterable[str]) -> str:
    used = {name.casefold() for name in existing}
    base = _slug(label)
    if base.casefold() not in used:
        return base
    for number in range(2, 10000):
        suffix = f"-{number}"
        candidate = f"{base[:127 - len(suffix)]}{suffix}"
        if candidate.casefold() not in used:
            return candidate
    raise BackendError("name-exhausted", "Could not generate a unique printer name.")


def normalize_uri(uri: str) -> str:
    """Canonicalize device URIs without resolving or contacting the device."""
    raw = _text(uri).strip()
    if not raw:
        return ""
    try:
        parts = urlsplit(raw)
    except ValueError:
        return raw.casefold().rstrip("/")
    scheme = parts.scheme.casefold()
    if scheme in {"ipp", "ipps"}:
        scheme = "ipp"
    host = (parts.hostname or "").casefold().rstrip(".")
    if host.endswith(".local"):
        host = host[:-6]
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    try:
        port = parts.port
    except ValueError:
        return raw.casefold().rstrip("/")
    if (parts.scheme.casefold() == "ipp" and port == 631) or (
        parts.scheme.casefold() == "ipps" and port in {443, 631}
    ):
        port = None
    user = ""
    if parts.username:
        user = quote(unquote(parts.username), safe="") + "@"
    netloc = user + host + (f":{port}" if port is not None else "")
    path = quote(unquote(parts.path or ""), safe="/:@-._~").rstrip("/")
    query = [
        (key.casefold(), value)
        for key, value in parse_qsl(parts.query, keep_blank_values=True)
        if key.casefold() not in {"tls", "transport"}
    ]
    return urlunsplit((scheme, netloc, path, urlencode(sorted(query)), ""))


def parse_device_id(value: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for item in _text(value).split(";"):
        key, separator, val = item.partition(":")
        if separator and key.strip():
            fields[key.strip().upper()] = val.strip()
    aliases = {"MANUFACTURER": "MFG", "MODEL": "MDL", "SERIALNUMBER": "SN"}
    for source, target in aliases.items():
        if source in fields and target not in fields:
            fields[target] = fields[source]
    return fields


def _norm_words(value: str) -> str:
    value = unicodedata.normalize("NFKD", _text(value)).encode("ascii", "ignore").decode()
    return " ".join(re.findall(r"[a-z0-9]+", value.casefold()))


def device_identity(device: Mapping[str, Any]) -> str:
    uuid = _text(device.get("device-uuid") or device.get("printer-uuid")).strip()
    if uuid:
        return "uuid:" + uuid.casefold().removeprefix("urn:uuid:")
    device_id = _text(device.get("device-id"))
    fields = parse_device_id(device_id)
    serial = fields.get("SN") or fields.get("SERN") or fields.get("SERIAL")
    if serial:
        return "ieee1284:" + "|".join(
            _norm_words(value) for value in (fields.get("MFG", ""), fields.get("MDL", ""), serial)
        )
    if device_id:
        normalized = ";".join(
            f"{key}:{_norm_words(value)}" for key, value in sorted(fields.items()) if value
        )
        if normalized:
            return "ieee1284-id:" + normalized
    uri = _text(device.get("device-uri"))
    try:
        parsed = urlsplit(uri)
    except ValueError:
        return "uri-raw:" + uri.casefold().strip().rstrip("/")
    service_uri = parsed.scheme.casefold() in {"dnssd", "mdns"}
    service_host = unquote(parsed.hostname or "")
    if service_uri or re.search(r"\._ipps?\._tcp(?:\.|$)", service_host, re.IGNORECASE):
        service = unquote(parsed.netloc + parsed.path if service_uri else service_host)
        service = service.casefold().rstrip("/").rstrip(".")
        service = re.sub(r"\._ipps?\._tcp(?=\.|$)", "._ipp._tcp", service)
        return "service:" + service
    return "uri:" + normalize_uri(uri)


def discover_driverless(timeout: int = 5) -> list[dict[str, str]]:
    """Use CUPS' machine-readable driverless helper when D-Bus discovery fails."""
    try:
        result = subprocess.run(
            ["driverless"],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return []
    if result.returncode != 0:
        return []
    devices = []
    for line in result.stdout.splitlines():
        uri = line.strip()
        try:
            parsed = urlsplit(uri)
        except ValueError:
            continue
        if parsed.scheme.casefold() not in {"ipp", "ipps"} or not parsed.hostname:
            continue
        host = unquote(parsed.hostname)
        display_host = unquote(parsed.netloc)
        name = re.split(
            r"\._ipps?\._tcp", display_host, maxsplit=1, flags=re.IGNORECASE
        )[0]
        devices.append(
            {
                "device-uri": uri,
                "device-info": name or host,
                "device-make-and-model": name or host,
            }
        )
    return devices


def parse_flattened_devices(flattened: Mapping[Any, Any]) -> list[dict[str, str]]:
    groups: dict[int, dict[str, str]] = {}
    unsuffixed: dict[str, str] = {}
    for raw_key, raw_value in flattened.items():
        key = _text(raw_key)
        match = re.fullmatch(r"(.+):(\d+)", key)
        if match:
            groups.setdefault(int(match.group(2)), {})[match.group(1)] = _text(raw_value)
        else:
            unsuffixed[key] = _text(raw_value)
    if unsuffixed:
        groups.setdefault(0, {}).update(
            {key: value for key, value in unsuffixed.items() if key not in groups.get(0, {})}
        )
    return [groups[index] for index in sorted(groups) if groups[index].get("device-uri")]


def normalize_device(device: Mapping[str, Any]) -> dict[str, Any]:
    result = {str(key): _text(value) for key, value in device.items()}
    uri = result.get("device-uri", "")
    info = result.get("device-info") or result.get("device-make-and-model") or uri
    try:
        scheme = urlsplit(uri).scheme.casefold()
    except ValueError:
        scheme = ""
    driverless = scheme in {"ipp", "ipps"} or (
        scheme in {"dnssd", "mdns"} and bool(re.search(r"\._ipps?\._tcp", uri, re.IGNORECASE))
    )
    transport_labels = {
        "ipp": "Network",
        "ipps": "Network",
        "dnssd": "Network",
        "mdns": "Network",
        "usb": "USB",
        "socket": "Network",
        "lpd": "Network",
    }
    result.update(
        {
            "uri": uri,
            "normalizedUri": normalize_uri(uri),
            "identity": device_identity(result),
            "name": info,
            "kind": scheme or "unknown",
            "driverless": driverless,
            "transportLabel": transport_labels.get(scheme, "Printer"),
        }
    )
    return result


def dedupe_devices(devices: Iterable[Mapping[str, Any]]) -> list[dict[str, Any]]:
    selected: dict[str, dict[str, Any]] = {}
    for raw in devices:
        device = normalize_device(raw)
        identity = device["identity"]
        current = selected.get(identity)
        if current is None:
            selected[identity] = device
            continue
        # Prefer encrypted IPP, then IPP, then a URI with more metadata.
        def preference(item: Mapping[str, Any]) -> tuple[int, int, str]:
            try:
                scheme = urlsplit(_text(item.get("uri"))).scheme.casefold()
            except ValueError:
                scheme = ""
            return (
                {"ipps": 3, "ipp": 2, "dnssd": 1}.get(scheme, 0),
                sum(bool(item.get(key)) for key in ("device-id", "device-uuid", "device-location")),
                _text(item.get("uri")),
            )

        if preference(device) > preference(current):
            selected[identity] = device
    return sorted(selected.values(), key=lambda item: (_text(item["name"]).casefold(), item["identity"]))


def filter_installed(
    devices: Iterable[Mapping[str, Any]], queues: Iterable[Mapping[str, Any]]
) -> list[dict[str, Any]]:
    identities = {_text(queue.get("identity")) for queue in queues}
    uris = {
        normalize_uri(_text(queue.get("uri") or queue.get("device-uri")))
        for queue in queues
    }
    return [
        dict(device)
        for device in devices
        if _text(device.get("identity")) not in identities
        and normalize_uri(_text(device.get("uri") or device.get("device-uri"))) not in uris
    ]


def _commands(value: str) -> set[str]:
    fields = parse_device_id(value)
    return {
        command.strip().casefold()
        for command in re.split(r"[, ]+", fields.get("CMD", ""))
        if command.strip()
    }


def rank_models(
    device: Mapping[str, Any], models: Sequence[Mapping[str, Any]]
) -> dict[str, Any]:
    device_id = parse_device_id(_text(device.get("device-id")))
    manufacturer = _norm_words(device_id.get("MFG") or _text(device.get("device-make-and-model")))
    model_name = _norm_words(device_id.get("MDL") or _text(device.get("device-make-and-model")))
    target_tokens = set((manufacturer + " " + model_name).split())
    device_cmd = _commands(_text(device.get("device-id")))
    try:
        uri_scheme = urlsplit(
            _text(device.get("uri") or device.get("device-uri"))
        ).scheme.casefold()
    except ValueError:
        uri_scheme = ""
    driverless_device = uri_scheme in {"ipp", "ipps", "dnssd"} or bool(
        device_cmd & {"pwg", "urf", "pdf", "apple-raster"}
    )
    ranked: list[tuple[int, str, dict[str, Any], list[str]]] = []
    for raw in models:
        model = dict(raw)
        ppd = _text(model.get("name") or model.get("ppd-name"))
        display = _text(model.get("makeAndModel") or model.get("ppd-make-and-model") or ppd)
        normalized = _norm_words(display + " " + _text(model.get("deviceId") or model.get("ppd-device-id")))
        tokens = set(normalized.split())
        reasons: list[str] = []
        score = len(target_tokens & tokens) * 10
        if manufacturer and manufacturer in normalized:
            score += 25
            reasons.append("manufacturer match")
        if model_name and model_name in normalized:
            score += 45
            reasons.append("model match")
        model_cmd = _commands(_text(model.get("deviceId") or model.get("ppd-device-id")))
        overlap = device_cmd & model_cmd
        if overlap:
            score += min(20, len(overlap) * 5)
            reasons.append("command-set match")
        driverless = "everywhere" in ppd.casefold() or "driverless" in ppd.casefold() or (
            "driverless" in display.casefold()
        )
        if driverless and driverless_device:
            score += 100
            reasons.insert(0, "driverless IPP preferred")
        model.update({"name": ppd, "makeAndModel": display, "score": score})
        ranked.append((score, ppd.casefold(), model, reasons))
    ranked.sort(key=lambda item: (-item[0], item[1]))
    searchable = [item[2] for item in ranked]
    if not ranked:
        return {
            "recommendation": None,
            "confidence": "none",
            "reason": "No local printer models are available.",
            "models": [],
        }
    score, _, recommendation, reasons = ranked[0]
    confidence = "high" if score >= 100 else "medium" if score >= 45 else "low"
    return {
        "recommendation": recommendation,
        "confidence": confidence,
        "reason": ", ".join(reasons) if reasons else "Closest deterministic local model match.",
        "models": searchable,
    }


def map_exception(exc: BaseException, operation: str) -> BackendError:
    if isinstance(exc, BackendError):
        return exc
    name = ""
    if hasattr(exc, "get_dbus_name"):
        try:
            name = _text(exc.get_dbus_name())
        except Exception:
            name = ""
    folded = (name + " " + type(exc).__name__ + " " + _text(exc)).casefold()
    diagnostic = f"{operation}: {type(exc).__name__}" + (f" ({name})" if name else "")
    if any(term in folded for term in ("cancelled", "canceled")):
        return BackendError(
            "authorization-cancelled", "Authorization was cancelled.", diagnostic=diagnostic
        )
    if any(term in folded for term in ("notauthorized", "not authorized", "accessdenied")):
        return BackendError(
            "authorization-denied", "Authorization was denied.", diagnostic=diagnostic
        )
    if any(
        term in folded
        for term in ("serviceunknown", "namehasnoowner", "modulenotfound", "noreply")
    ):
        return BackendError(
            "dependency-unavailable",
            "A required printing service is unavailable.",
            diagnostic=diagnostic,
        )
    if operation == "discovery":
        return BackendError("discovery-failed", "Printer discovery failed.", diagnostic=diagnostic)
    if "cups" in folded or "ipp" in folded:
        return BackendError("cups-error", "The printing service reported an error.", diagnostic=diagnostic)
    return BackendError("backend-error", "The printer operation failed.", diagnostic=diagnostic)


class PyCupsAdapter:
    def __init__(self, connection: Any | None = None, cups_module: Any | None = None):
        if cups_module is None:
            try:
                import cups as cups_module
            except ImportError as exc:
                raise map_exception(exc, "cups") from exc
        self.cups = cups_module
        try:
            self.connection = connection or cups_module.Connection()
        except Exception as exc:
            raise map_exception(exc, "cups") from exc

    def preflight(self) -> Mapping[str, Any]:
        self.connection.getPrinters()
        return {"pycups": True, "cups": True}

    def queues(self) -> tuple[str | None, list[dict[str, Any]]]:
        default = self.connection.getDefault()
        queues: list[dict[str, Any]] = []
        for name, attrs in self.connection.getPrinters().items():
            uri = _text(attrs.get("device-uri"))
            accepting = bool(attrs.get("printer-is-accepting-jobs", True))
            record = dict(attrs)
            record.update(
                {
                    "name": _text(name),
                    "uri": uri,
                    "normalizedUri": normalize_uri(uri),
                    "identity": device_identity(attrs),
                    "enabled": int(attrs.get("printer-state", 0) or 0) != 5 and accepting,
                    "accepting": accepting,
                    "state": int(attrs.get("printer-state", 0) or 0),
                    "stateMessage": _text(attrs.get("printer-state-message")),
                    "isDefault": name == default,
                }
            )
            queues.append(record)
        queues.sort(key=lambda item: item["name"].casefold())
        return default, queues

    def models(self) -> list[dict[str, Any]]:
        result = []
        for name, attrs in self.connection.getPPDs2().items():
            result.append(
                {
                    "name": _text(name),
                    "makeAndModel": _text(attrs.get("ppd-make-and-model")),
                    "make": _text(attrs.get("ppd-make")),
                    "deviceId": _text(attrs.get("ppd-device-id")),
                    "language": _text(attrs.get("ppd-natural-language")),
                }
            )
        return sorted(result, key=lambda item: (item["makeAndModel"].casefold(), item["name"]))

    def jobs(self, queue: str | None = None) -> list[dict[str, Any]]:
        jobs = []
        state_labels = {
            3: "Pending",
            4: "Held",
            5: "Printing",
            6: "Stopped",
            7: "Canceled",
            8: "Aborted",
            9: "Completed",
        }
        for job_id, attrs in self.connection.getJobs(which_jobs="not-completed").items():
            destination = _text(
                attrs.get("job-printer-uri", "").rstrip("/").rsplit("/", 1)[-1]
                or attrs.get("printer-name")
            )
            if queue and destination != queue:
                continue
            jobs.append(
                {
                    "id": int(job_id),
                    "queue": destination,
                    "name": _text(attrs.get("job-name")),
                    "user": _text(attrs.get("job-originating-user-name")),
                    "state": int(attrs.get("job-state", 0) or 0),
                    "stateLabel": state_labels.get(
                        int(attrs.get("job-state", 0) or 0), "Unknown"
                    ),
                    "size": int(attrs.get("job-k-octets", 0) or 0),
                    "created": int(attrs.get("time-at-creation", 0) or 0),
                }
            )
        return sorted(jobs, key=lambda item: item["id"])

    def options(self, queue: str) -> dict[str, Any]:
        attrs = self.connection.getPrinterAttributes(queue)
        defaults = {
            key[:-8]: value for key, value in attrs.items() if _text(key).endswith("-default")
        }
        path: str | None = None
        choices: list[dict[str, Any]] = []
        try:
            path = self.connection.getPPD(queue)
            ppd = self.cups.PPD(path)
            for group in ppd.optionGroups:
                for option in group.options:
                    def choice_value(choice: Any, key: str) -> str:
                        if isinstance(choice, Mapping):
                            return _text(choice.get(key))
                        return _text(getattr(choice, key, ""))

                    choices.append(
                        {
                            "name": _text(option.keyword),
                            "label": _text(option.text),
                            "default": defaults.get(option.keyword, _text(option.defchoice)),
                            "choices": [
                                {
                                    "value": choice_value(choice, "choice"),
                                    "label": choice_value(choice, "text"),
                                }
                                for choice in option.choices
                            ],
                        }
                    )
        finally:
            if path:
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
        return {"queue": queue, "defaults": defaults, "options": choices}

    def test_page(self, queue: str) -> int | None:
        result = self.connection.printTestPage(queue)
        return int(result) if result is not None else None


class PkHelperAdapter:
    def __init__(self, interface: Any | None = None):
        self.dbus = None
        if interface is None:
            try:
                import dbus
            except ImportError as exc:
                raise map_exception(exc, "helper") from exc
            try:
                bus = dbus.SystemBus()
                obj = bus.get_object(PK_NAME, PK_PATH)
                interface = dbus.Interface(obj, dbus_interface=PK_INTERFACE)
                self.dbus = dbus
            except Exception as exc:
                raise map_exception(exc, "helper") from exc
        self.interface = interface

    def _discovery_args(self, timeout: int, limit: int) -> tuple[Any, Any, Any, Any]:
        if self.dbus is None:
            return timeout, limit, [], []
        return (
            self.dbus.Int32(timeout),
            self.dbus.Int32(limit),
            self.dbus.Array([], signature="s"),
            self.dbus.Array([], signature="s"),
        )

    def preflight(self) -> Mapping[str, Any]:
        # Constructing this adapter already verifies python-dbus and the system
        # bus. Do not call a policy-protected method during a read-only check.
        return {"cupsPkHelper": True, "systemBus": True}

    def devices(self, timeout: int = DISCOVERY_TIMEOUT) -> list[dict[str, str]]:
        try:
            error, flattened = self.interface.DevicesGet(
                *self._discovery_args(int(timeout), MAX_DEVICES),
                timeout=max(2, int(timeout) + 1),
                dbus_interface=PK_INTERFACE,
            )
        except Exception as exc:
            raise map_exception(exc, "discovery") from exc
        if _text(error):
            raise BackendError(
                "discovery-failed",
                "Printer discovery failed.",
                diagnostic="DevicesGet returned an error",
            )
        return parse_flattened_devices(flattened)

    def mutate(self, method: str, *args: Any) -> None:
        try:
            call = getattr(self.interface, method)
            result = call(*args, timeout=30, dbus_interface=PK_INTERFACE)
        except Exception as exc:
            raise map_exception(exc, method) from exc
        error = _text(result[0] if isinstance(result, tuple) else result)
        if error:
            folded = error.casefold()
            if "cancel" in folded:
                raise BackendError("authorization-cancelled", "Authorization was cancelled.")
            if "authoriz" in folded or "permission" in folded:
                raise BackendError("authorization-denied", "Authorization was denied.")
            raise BackendError(
                "cups-error",
                "The printing service rejected the operation.",
                diagnostic=f"{method} returned an error",
            )


class PrinterBackend:
    def __init__(self, cups_api: CupsAPI, helper: HelperAPI):
        self.cups = cups_api
        self.helper = helper

    def preflight(self, _: Mapping[str, Any]) -> dict[str, Any]:
        result = dict(self.cups.preflight())
        result.update(self.helper.preflight())
        return result

    def snapshot(self, request: Mapping[str, Any]) -> dict[str, Any]:
        default, queues = self.cups.queues()
        warning = None
        include_legacy = request.get("includeLegacy", False)
        if not isinstance(include_legacy, bool):
            raise BackendError("invalid-request", "includeLegacy must be a boolean.", 2)
        timeout = request.get("timeout", DISCOVERY_TIMEOUT)
        if isinstance(timeout, bool) or not isinstance(timeout, int) or timeout < 1:
            raise BackendError("invalid-request", "timeout must be a positive integer.", 2)
        if include_legacy:
            try:
                discovered = dedupe_devices(self.helper.devices(timeout))
            except BackendError as exc:
                discovered = dedupe_devices(discover_driverless())
                warning = {
                    "code": exc.code,
                    "message": "Some printers may not be shown.",
                }
        else:
            discovered = dedupe_devices(discover_driverless())
        discovered_by_identity = {item["identity"] for item in discovered}
        discovered_uris = {item["normalizedUri"] for item in discovered}
        for queue in queues:
            found = (
                queue["identity"] in discovered_by_identity
                or normalize_uri(_text(queue.get("uri"))) in discovered_uris
            )
            queue["online"] = True if found else (
                False if include_legacy and not warning else None
            )
        available = filter_installed(discovered, queues)
        existing = [queue["name"] for queue in queues]
        reserved = list(existing)
        for device in available:
            device["queueName"] = unique_queue_name(_text(device["name"]), reserved)
            reserved.append(device["queueName"])
        result = {"default": default, "queues": queues, "available": available}
        if warning:
            result["warning"] = warning
        return result

    def models(self, request: Mapping[str, Any]) -> dict[str, Any]:
        models = self.cups.models()
        device = request.get("device")
        if device is None:
            return {"models": models}
        if not isinstance(device, Mapping):
            raise BackendError("invalid-request", "device must be a JSON object.", 2)
        return rank_models(device, models)

    def add(self, request: Mapping[str, Any]) -> dict[str, Any]:
        uri = required_string(request, "uri")
        label = required_string(request, "name")
        _, queues = self.cups.queues()
        existing = [item["name"] for item in queues]
        requested_queue = _text(request.get("queue"))
        queue = requested_queue or unique_queue_name(label, existing)
        if queue != _slug(queue):
            raise BackendError("invalid-request", "queue contains invalid characters.", 2)
        if queue.casefold() in {name.casefold() for name in existing}:
            queue = unique_queue_name(queue, existing)
        ppd = _text(request.get("model")) or "everywhere"
        self.helper.mutate(
            "PrinterAdd",
            queue,
            uri,
            ppd,
            _text(request.get("info")) or label,
            _text(request.get("location")),
        )
        self.helper.mutate("PrinterSetEnabled", queue, True)
        self.helper.mutate("PrinterSetAcceptJobs", queue, True, "")
        return {"queue": queue}

    def remove(self, request: Mapping[str, Any]) -> dict[str, Any]:
        queue = required_string(request, "queue")
        self.helper.mutate("PrinterDelete", queue)
        return {"queue": queue}

    def set_default(self, request: Mapping[str, Any]) -> dict[str, Any]:
        queue = required_string(request, "queue")
        self.helper.mutate("PrinterSetDefault", queue)
        return {"queue": queue}

    def set_enabled(self, request: Mapping[str, Any]) -> dict[str, Any]:
        queue = required_string(request, "queue")
        enabled = required_bool(request, "enabled")
        self.helper.mutate("PrinterSetEnabled", queue, enabled)
        self.helper.mutate(
            "PrinterSetAcceptJobs",
            queue,
            enabled,
            "" if enabled else "Disabled from Omarchy printer panel",
        )
        return {"queue": queue, "enabled": enabled}

    def jobs(self, request: Mapping[str, Any]) -> dict[str, Any]:
        queue = request.get("queue")
        if queue is not None and not isinstance(queue, str):
            raise BackendError("invalid-request", "queue must be a string.", 2)
        return {"jobs": self.cups.jobs(queue)}

    def cancel_job(self, request: Mapping[str, Any]) -> dict[str, Any]:
        job_id = required_int(request, "jobId", minimum=1)
        purge = request.get("purge", False)
        if not isinstance(purge, bool):
            raise BackendError("invalid-request", "purge must be a boolean.", 2)
        self.helper.mutate("JobCancelPurge", job_id, purge)
        return {"jobId": job_id}

    def options(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self.cups.options(required_string(request, "queue"))

    def set_options(self, request: Mapping[str, Any]) -> dict[str, Any]:
        queue = required_string(request, "queue")
        options = request.get("options")
        if not isinstance(options, Mapping) or not options:
            raise BackendError("invalid-request", "options must be a non-empty JSON object.", 2)
        supported = {
            _text(option.get("name")): {
                _text(choice.get("value"))
                for choice in option.get("choices", [])
                if isinstance(choice, Mapping)
            }
            for option in self.cups.options(queue).get("options", [])
            if isinstance(option, Mapping)
        }
        applied: dict[str, list[str]] = {}
        for option in sorted(options):
            if not isinstance(option, str) or not option or option.startswith("-"):
                raise BackendError("invalid-request", "option names must be non-empty strings.", 2)
            if option not in supported:
                raise BackendError("invalid-request", f"Unsupported printer option: {option}.", 2)
            value = options[option]
            values = value if isinstance(value, list) else [value]
            if not values or any(not isinstance(item, (str, int, float, bool)) for item in values):
                raise BackendError("invalid-request", f"Invalid value for option {option}.", 2)
            text_values = [str(item).lower() if isinstance(item, bool) else str(item) for item in values]
            if supported[option] and any(item not in supported[option] for item in text_values):
                raise BackendError("invalid-request", f"Unsupported value for {option}.", 2)
            self.helper.mutate("PrinterAddOptionDefault", queue, option, text_values)
            applied[option] = text_values
        return {"queue": queue, "options": applied}

    def test_page(self, request: Mapping[str, Any]) -> dict[str, Any]:
        queue = required_string(request, "queue")
        return {"queue": queue, "jobId": self.cups.test_page(queue)}


def required_string(request: Mapping[str, Any], key: str) -> str:
    value = request.get(key)
    if not isinstance(value, str) or not value.strip():
        raise BackendError("invalid-request", f"{key} must be a non-empty string.", 2)
    return value.strip()


def required_bool(request: Mapping[str, Any], key: str) -> bool:
    value = request.get(key)
    if not isinstance(value, bool):
        raise BackendError("invalid-request", f"{key} must be a boolean.", 2)
    return value


def required_int(request: Mapping[str, Any], key: str, minimum: int | None = None) -> int:
    value = request.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or (
        minimum is not None and value < minimum
    ):
        raise BackendError("invalid-request", f"{key} must be an integer.", 2)
    return value


COMMANDS = {
    "preflight": "preflight",
    "snapshot": "snapshot",
    "models": "models",
    "add": "add",
    "remove": "remove",
    "set-default": "set_default",
    "set-enabled": "set_enabled",
    "jobs": "jobs",
    "cancel-job": "cancel_job",
    "options": "options",
    "set-options": "set_options",
    "test-page": "test_page",
}


def dispatch(
    command: str,
    request: Mapping[str, Any],
    backend: PrinterBackend | None = None,
) -> dict[str, Any]:
    if command not in COMMANDS:
        raise BackendError("invalid-command", f"Unknown command: {command}.", 2)
    if not isinstance(request, Mapping):
        raise BackendError("invalid-request", "Request must be a JSON object.", 2)
    backend = backend or PrinterBackend(PyCupsAdapter(), PkHelperAdapter())
    try:
        data = getattr(backend, COMMANDS[command])(request)
    except Exception as exc:
        raise map_exception(exc, command) from exc
    return {"version": API_VERSION, "ok": True, "data": data}


def _json_object(value: str, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise BackendError("invalid-json", f"{label} JSON is invalid.", 2, str(exc)) from exc
    if not isinstance(parsed, dict):
        raise BackendError("invalid-request", f"{label} must be a JSON object.", 2)
    return parsed


def _argument_bool(value: str) -> bool:
    normalized = value.casefold()
    if normalized in {"true", "1", "yes", "on"}:
        return True
    if normalized in {"false", "0", "no", "off"}:
        return False
    raise argparse.ArgumentTypeError("expected true or false")


def _request_from_args(args: argparse.Namespace) -> dict[str, Any]:
    if args.json is not None:
        return _json_object(args.json, "Request")
    request = {
        key: value
        for key, value in vars(args).items()
        if key not in {"command", "json"} and value is not None
    }
    if args.command == "models":
        device = {
            key.replace("_", "-"): value
            for key, value in request.items()
            if key.startswith("device_")
        }
        request = {key: value for key, value in request.items() if not key.startswith("device_")}
        if device:
            request["device"] = device
    if args.command == "set-options" and "options" in request:
        request["options"] = _json_object(request["options"], "options")
    if request:
        return request
    if not sys.stdin.isatty():
        payload = sys.stdin.read()
        if payload.strip():
            return _json_object(payload, "Request")
    return request


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        if "argument command: invalid choice:" in message:
            raise BackendError("invalid-command", "Unknown command.", 2, message)
        raise BackendError("invalid-request", "Command-line arguments are invalid.", 2, message)


def build_parser() -> argparse.ArgumentParser:
    parser = JSONArgumentParser(description=__doc__, add_help=False)
    subparsers = parser.add_subparsers(dest="command", required=True)

    def command_parser(name: str) -> argparse.ArgumentParser:
        child = subparsers.add_parser(name, add_help=False)
        child.add_argument("--json", help="Complete JSON request object")
        return child

    command_parser("preflight")

    snapshot = command_parser("snapshot")
    snapshot.add_argument("--timeout", type=int)
    snapshot.add_argument(
        "--include-legacy", dest="includeLegacy", type=_argument_bool
    )

    models = command_parser("models")
    models.add_argument("--device-uri")
    models.add_argument("--device-id")
    models.add_argument("--device-make-and-model")
    models.add_argument("--device-uuid")

    add = command_parser("add")
    add.add_argument("--name")
    add.add_argument("--uri")
    add.add_argument("--queue")
    add.add_argument("--model")
    add.add_argument("--info")
    add.add_argument("--location")

    for command in ("remove", "set-default", "options", "test-page"):
        command_parser(command).add_argument("--queue")

    enabled = command_parser("set-enabled")
    enabled.add_argument("--queue")
    enabled.add_argument("--enabled", type=_argument_bool)

    jobs = command_parser("jobs")
    jobs.add_argument("--queue")

    cancel = command_parser("cancel-job")
    cancel.add_argument("--job-id", dest="jobId", type=int)
    cancel.add_argument("--purge", type=_argument_bool)

    set_options = command_parser("set-options")
    set_options.add_argument("--queue")
    set_options.add_argument("--options")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = build_parser().parse_args(argv)
        response = dispatch(args.command, _request_from_args(args))
        json.dump(response, sys.stdout, sort_keys=True, separators=(",", ":"))
        sys.stdout.write("\n")
        return 0
    except BackendError as exc:
        if exc.diagnostic:
            print(f"printers backend: {exc.diagnostic}", file=sys.stderr)
        json.dump(
            {
                "version": API_VERSION,
                "ok": False,
                "error": {"code": exc.code, "message": exc.message},
            },
            sys.stdout,
            sort_keys=True,
            separators=(",", ":"),
        )
        sys.stdout.write("\n")
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
