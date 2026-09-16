from __future__ import annotations

import io
import json
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend import printers


class FakeCups:
    def __init__(self):
        self.default = "Office"
        self.queue_rows = [
            {
                "name": "Office",
                "uri": "ipps://office.local:631/ipp/print/",
                "identity": "uuid:abc",
                "enabled": True,
                "accepting": True,
                "state": 3,
            }
        ]
        self.model_rows = [
            {
                "name": "drv:///sample.drv/acme.ppd",
                "makeAndModel": "Acme Laser 2000",
                "deviceId": "MFG:Acme;MDL:Laser 2000;CMD:PCL,PDF;",
            },
            {
                "name": "everywhere",
                "makeAndModel": "IPP Everywhere",
                "deviceId": "CMD:PDF,PWG,URF;",
            },
        ]

    def preflight(self):
        return {"pycups": True, "cups": True}

    def queues(self):
        return self.default, [dict(row) for row in self.queue_rows]

    def models(self):
        return [dict(row) for row in self.model_rows]

    def jobs(self, queue=None):
        rows = [{"id": 4, "queue": "Office", "name": "Document"}]
        return [row for row in rows if not queue or row["queue"] == queue]

    def options(self, queue):
        return {
            "queue": queue,
            "defaults": {"Duplex": "None", "Copies": "1"},
            "options": [
                {
                    "name": "Duplex",
                    "choices": [
                        {"value": "None", "label": "Off"},
                        {"value": "two-sided", "label": "Two-sided"},
                    ],
                },
                {
                    "name": "Copies",
                    "choices": [
                        {"value": "1", "label": "1"},
                        {"value": "2", "label": "2"},
                    ],
                },
            ],
        }

    def test_page(self, queue):
        return 99


class FakeHelper:
    def __init__(self):
        self.calls = []
        self.device_rows = []

    def preflight(self):
        return {"cupsPkHelper": True, "systemBus": True}

    def devices(self, timeout=printers.DISCOVERY_TIMEOUT):
        self.calls.append(("DevicesGet", timeout))
        return [dict(row) for row in self.device_rows]

    def mutate(self, method, *args):
        self.calls.append((method, *args))


class URIAndIdentityTests(unittest.TestCase):
    def test_normalizes_ipp_and_ipps_equally(self):
        self.assertEqual(
            printers.normalize_uri("IPPS://Printer.LOCAL:631/ipp/print/"),
            printers.normalize_uri("ipp://printer/ipp/print"),
        )

    def test_normalizes_query_order_and_transport(self):
        self.assertEqual(
            printers.normalize_uri("ipp://p.local/q?b=2&transport=tls&a=1"),
            "ipp://p/q?a=1&b=2",
        )

    def test_preserves_legacy_scheme(self):
        self.assertEqual(printers.normalize_uri("socket://HOST.local:9100/"), "socket://host:9100")

    def test_malformed_port_is_stable(self):
        self.assertEqual(printers.normalize_uri("ipp://host:notaport/q"), "ipp://host:notaport/q")

    def test_malformed_ipv6_device_gets_raw_identity(self):
        device = printers.normalize_device(
            {"device-uri": "ipp://[broken", "device-info": "Malformed"}
        )
        self.assertEqual(device["identity"], "uri-raw:ipp://[broken")
        self.assertFalse(device["driverless"])

    def test_uuid_identity_has_priority(self):
        identity = printers.device_identity(
            {
                "device-uuid": "urn:uuid:ABC",
                "device-id": "MFG:X;MDL:Y;SN:123;",
                "device-uri": "ipp://x",
            }
        )
        self.assertEqual(identity, "uuid:abc")

    def test_ieee1284_serial_identity(self):
        first = {"device-id": "MFG:Acme;MDL:Laser;SN:A-1;", "device-uri": "ipp://v4"}
        second = {"device-id": "MDL:Laser;MFG:Acme;SN:A-1;", "device-uri": "ipps://v6"}
        self.assertEqual(printers.device_identity(first), printers.device_identity(second))
        self.assertTrue(printers.device_identity(first).startswith("ieee1284:"))

    def test_service_identity_normalizes_ipp_and_ipps(self):
        one = {"device-uri": "dnssd://Office._ipp._tcp.local/"}
        two = {"device-uri": "dnssd://office._ipps._tcp.local/"}
        self.assertEqual(printers.device_identity(one), printers.device_identity(two))

    def test_service_identity_matches_resolved_ipps_uri(self):
        dnssd = {"device-uri": "dnssd://Office._ipp._tcp.local/"}
        resolved = {"device-uri": "ipps://office._ipps._tcp.local/"}
        self.assertEqual(printers.device_identity(dnssd), printers.device_identity(resolved))


class DiscoveryTests(unittest.TestCase):
    def test_driverless_fallback_accepts_only_ipp_uris(self):
        completed = printers.subprocess.CompletedProcess(
            ["driverless"],
            0,
            "ipps://Office%20Printer._ipps._tcp.local/\n"
            "socket://untrusted:9100\n",
            "",
        )
        with patch.object(printers.subprocess, "run", return_value=completed):
            rows = printers.discover_driverless()
        self.assertEqual(
            rows,
            [
                {
                    "device-uri": "ipps://Office%20Printer._ipps._tcp.local/",
                    "device-info": "Office Printer",
                    "device-make-and-model": "Office Printer",
                }
            ],
        )

    def test_parses_flattened_fixture(self):
        fixture = ROOT / "tests" / "fixtures" / "devices_flattened.json"
        rows = printers.parse_flattened_devices(json.loads(fixture.read_text()))
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["device-info"], "Office Printer")
        self.assertEqual(rows[1]["device-uri"], "socket://192.0.2.5")

    def test_parses_unsuffixed_single_device(self):
        rows = printers.parse_flattened_devices(
            {"device-uri": "usb://Acme/P", "device-info": "USB Printer"}
        )
        self.assertEqual(rows, [{"device-uri": "usb://Acme/P", "device-info": "USB Printer"}])

    def test_dedupes_ip_versions_by_device_id(self):
        devices = [
            {
                "device-uri": "ipp://192.0.2.4/ipp/print",
                "device-id": "MFG:A;MDL:B;SN:42;",
            },
            {
                "device-uri": "ipps://[2001:db8::4]/ipp/print",
                "device-id": "MFG:A;MDL:B;SN:42;",
            },
        ]
        result = printers.dedupe_devices(devices)
        self.assertEqual(len(result), 1)
        self.assertTrue(result[0]["uri"].startswith("ipps:"))

    def test_keeps_legacy_devices(self):
        devices = printers.dedupe_devices(
            [
                {"device-uri": "usb://Acme/Printer?serial=1", "device-info": "USB"},
                {"device-uri": "socket://192.0.2.8", "device-info": "JetDirect"},
                {"device-uri": "lpd://print.example/q", "device-info": "LPD"},
            ]
        )
        self.assertEqual({item["kind"] for item in devices}, {"usb", "socket", "lpd"})
        self.assertFalse(any(item["driverless"] for item in devices))

    def test_marks_ipp_devices_as_driverless(self):
        device = printers.normalize_device(
            {"device-uri": "ipps://printer.local/ipp/print", "device-info": "Office"}
        )
        self.assertTrue(device["driverless"])
        self.assertEqual(device["transportLabel"], "Network")

    def test_filters_installed_by_identity_or_uri(self):
        devices = printers.dedupe_devices(
            [
                {"device-uri": "ipp://new/ipp/print", "device-uuid": "new"},
                {"device-uri": "ipps://old.local:631/ipp/print/", "device-uuid": "old"},
                {"device-uri": "socket://legacy:9100", "device-info": "Legacy"},
            ]
        )
        queues = [
            {"identity": "uuid:old", "uri": "ipp://different/ipp/print"},
            {"identity": "unrelated", "uri": "socket://legacy:9100/"},
        ]
        available = printers.filter_installed(devices, queues)
        self.assertEqual([item["identity"] for item in available], ["uuid:new"])

    def test_matches_installed_by_normalized_queue_name(self):
        device = printers.normalize_device(
            {
                "device-uri": "ipps://Brother%20HL-L2445DW._ipps._tcp.local/",
                "device-info": "Brother HL-L2445DW",
            }
        )
        queue = {
            "name": "Brother_HL-L2445DW",
            "identity": "uri:ipp://brwc4137538a799/ipp/print",
            "uri": "ipps://BRWC4137538A799.local:443/ipp/print",
        }
        self.assertTrue(printers.device_matches_queue(device, queue))
        self.assertEqual(printers.filter_installed([device], [queue]), [])


class QueueNameTests(unittest.TestCase):
    def test_sanitizes_queue_name(self):
        self.assertEqual(printers.unique_queue_name("Café / Office!", []), "Cafe-Office")

    def test_unique_name_is_case_insensitive_and_bounded(self):
        name = printers.unique_queue_name("A" * 200, ["a" * 127])
        self.assertEqual(len(name), 127)
        self.assertTrue(name.endswith("-2"))

    def test_reserves_names_deterministically_in_snapshot(self):
        cups = FakeCups()
        helper = FakeHelper()
        helper.device_rows = [
            {"device-uri": "usb://x/1", "device-info": "Label Printer"},
            {"device-uri": "usb://x/2", "device-info": "Label Printer"},
        ]
        data = printers.PrinterBackend(cups, helper).snapshot({"includeLegacy": True})
        self.assertEqual(
            [item["queueName"] for item in data["available"]],
            ["Label-Printer", "Label-Printer-2"],
        )


class ModelRankingTests(unittest.TestCase):
    def test_driverless_is_preferred_for_ipp(self):
        result = printers.rank_models(
            {
                "device-uri": "ipps://printer/ipp/print",
                "device-id": "MFG:Acme;MDL:Laser 2000;CMD:PDF,PWG;",
            },
            FakeCups().models(),
        )
        self.assertEqual(result["recommendation"]["name"], "everywhere")
        self.assertEqual(result["confidence"], "high")
        self.assertIn("driverless", result["reason"])

    def test_exact_legacy_model_wins_for_socket(self):
        result = printers.rank_models(
            {
                "device-uri": "socket://printer:9100",
                "device-id": "MFG:Acme;MDL:Laser 2000;CMD:PCL;",
            },
            FakeCups().models(),
        )
        self.assertEqual(result["recommendation"]["name"], "drv:///sample.drv/acme.ppd")
        self.assertIn("model match", result["reason"])

    def test_ranking_is_deterministic(self):
        models = [
            {"name": "z", "makeAndModel": "Generic"},
            {"name": "a", "makeAndModel": "Generic"},
        ]
        result = printers.rank_models({"device-uri": "usb://x"}, models)
        self.assertEqual([model["name"] for model in result["models"]], ["a", "z"])

    def test_no_models_has_explicit_result(self):
        result = printers.rank_models({"device-uri": "usb://x"}, [])
        self.assertIsNone(result["recommendation"])
        self.assertEqual(result["confidence"], "none")


class ErrorTests(unittest.TestCase):
    class DBusError(Exception):
        def __init__(self, name, message="detail"):
            self.name = name
            super().__init__(message)

        def get_dbus_name(self):
            return self.name

    def test_maps_authorization_cancel(self):
        error = printers.map_exception(
            self.DBusError("org.freedesktop.PolicyKit1.Error.Cancelled"), "PrinterAdd"
        )
        self.assertEqual(error.code, "authorization-cancelled")
        self.assertNotIn("detail", error.message)

    def test_maps_authorization_denial(self):
        error = printers.map_exception(
            self.DBusError("org.freedesktop.DBus.Error.AccessDenied"), "PrinterDelete"
        )
        self.assertEqual(error.code, "authorization-denied")

    def test_maps_missing_helper(self):
        error = printers.map_exception(
            self.DBusError("org.freedesktop.DBus.Error.ServiceUnknown"), "helper"
        )
        self.assertEqual(error.code, "dependency-unavailable")

    def test_maps_unresponsive_helper(self):
        error = printers.map_exception(
            self.DBusError("org.freedesktop.DBus.Error.NoReply"), "helper"
        )
        self.assertEqual(error.code, "dependency-unavailable")

    def test_maps_discovery_separately(self):
        error = printers.map_exception(RuntimeError("network"), "discovery")
        self.assertEqual(error.code, "discovery-failed")


class OperationsTests(unittest.TestCase):
    def setUp(self):
        self.cups = FakeCups()
        self.helper = FakeHelper()
        self.backend = printers.PrinterBackend(self.cups, self.helper)

    def test_add_uses_helper_and_enables_queue(self):
        result = self.backend.add({"name": "New Printer", "uri": "ipp://new/ipp/print"})
        self.assertEqual(result["queue"], "New-Printer")
        self.assertEqual(self.helper.calls[0][0], "PrinterAdd")
        self.assertEqual(self.helper.calls[1], ("PrinterSetEnabled", "New-Printer", True))
        self.assertEqual(
            self.helper.calls[2], ("PrinterSetAcceptJobs", "New-Printer", True, "")
        )

    def test_add_regenerates_explicit_colliding_queue_name(self):
        result = self.backend.add(
            {"name": "Office", "uri": "ipp://new/ipp/print", "queue": "Office"}
        )
        self.assertEqual(result["queue"], "Office-2")
        self.assertEqual(self.helper.calls[0][1], "Office-2")

    def test_set_enabled_changes_enabled_and_accepting(self):
        self.backend.set_enabled({"queue": "Office", "enabled": False})
        self.assertEqual(self.helper.calls[0], ("PrinterSetEnabled", "Office", False))
        self.assertEqual(self.helper.calls[1][0], "PrinterSetAcceptJobs")
        self.assertFalse(self.helper.calls[1][2])

    def test_remove_uses_helper(self):
        self.assertEqual(
            self.backend.remove({"queue": "Office"}), {"queue": "Office"}
        )
        self.assertEqual(self.helper.calls, [("PrinterDelete", "Office")])

    def test_set_default_uses_helper(self):
        self.assertEqual(
            self.backend.set_default({"queue": "Office"}), {"queue": "Office"}
        )
        self.assertEqual(self.helper.calls, [("PrinterSetDefault", "Office")])

    def test_jobs_and_options_use_read_adapter(self):
        self.assertEqual(self.backend.jobs({"queue": "Office"})["jobs"][0]["id"], 4)
        self.assertEqual(
            self.backend.options({"queue": "Office"})["defaults"]["Duplex"], "None"
        )
        management = self.backend.manage({"queue": "Office"})
        self.assertEqual(management["queue"], "Office")
        self.assertEqual(management["jobs"][0]["id"], 4)
        self.assertEqual(management["defaults"]["Duplex"], "None")
        self.assertEqual(management["options"][0]["name"], "Duplex")

    def test_manage_requires_queue(self):
        with self.assertRaises(printers.BackendError) as context:
            self.backend.manage({})
        self.assertEqual(context.exception.code, "invalid-request")

    def test_queues_does_not_run_discovery(self):
        self.assertEqual(self.backend.queues({})["queues"][0]["name"], "Office")
        self.assertEqual(self.helper.calls, [])

    def test_cancel_job_uses_purge_method(self):
        self.backend.cancel_job({"jobId": 12, "purge": True})
        self.assertEqual(self.helper.calls, [("JobCancelPurge", 12, True)])

    def test_set_options_are_sorted_and_values_are_lists(self):
        result = self.backend.set_options(
            {"queue": "Office", "options": {"Duplex": "two-sided", "Copies": 2}}
        )
        self.assertEqual(self.helper.calls[0], ("PrinterAddOptionDefault", "Office", "Copies", ["2"]))
        self.assertEqual(
            self.helper.calls[1],
            ("PrinterAddOptionDefault", "Office", "Duplex", ["two-sided"]),
        )
        self.assertEqual(result["options"]["Copies"], ["2"])

    def test_test_page_uses_read_adapter(self):
        self.assertEqual(self.backend.test_page({"queue": "Office"})["jobId"], 99)

    def test_snapshot_keeps_queue_state_separate_from_online(self):
        with patch.object(printers, "discover_driverless", return_value=[]):
            data = self.backend.snapshot({})
        queue = data["queues"][0]
        self.assertTrue(queue["enabled"])
        self.assertIsNone(queue["online"])

    def test_snapshot_marks_name_matched_queue_seen_and_not_available(self):
        discovered = {
            "device-uri": "ipps://Office._ipps._tcp.local/",
            "device-info": "Office",
        }
        with patch.object(printers, "discover_driverless", return_value=[discovered]):
            data = self.backend.snapshot({})
        self.assertTrue(data["queues"][0]["online"])
        self.assertEqual(data["available"], [])
        self.assertEqual(len(data["scanResults"]), 1)
        self.assertTrue(data["scanResults"][0]["installed"])
        self.assertEqual(data["scanResults"][0]["installedQueue"], "Office")

    def test_snapshot_marks_new_scan_results_installable(self):
        discovered = {
            "device-uri": "ipps://Lobby._ipps._tcp.local/",
            "device-info": "Lobby",
        }
        with patch.object(printers, "discover_driverless", return_value=[discovered]):
            data = self.backend.snapshot({})
        self.assertFalse(data["scanResults"][0]["installed"])
        self.assertEqual(data["scanResults"][0]["queueName"], "Lobby")
        self.assertEqual(data["scanResults"], data["available"])

    def test_normal_snapshot_does_not_call_privileged_discovery(self):
        with patch.object(printers, "discover_driverless", return_value=[]):
            self.backend.snapshot({})
        self.assertEqual(self.helper.calls, [])

    def test_snapshot_rejects_untyped_legacy_flag(self):
        with self.assertRaises(printers.BackendError) as context:
            self.backend.snapshot({"includeLegacy": "true"})
        self.assertEqual(context.exception.code, "invalid-request")

    def test_snapshot_keeps_queues_when_discovery_fails(self):
        class FailingHelper(FakeHelper):
            def devices(self, timeout=printers.DISCOVERY_TIMEOUT):
                raise printers.BackendError(
                    "discovery-failed", "Printer discovery failed."
                )

        with patch.object(printers, "discover_driverless", return_value=[]):
            data = printers.PrinterBackend(self.cups, FailingHelper()).snapshot(
                {"includeLegacy": True}
            )
        self.assertEqual([queue["name"] for queue in data["queues"]], ["Office"])
        self.assertIsNone(data["queues"][0]["online"])
        self.assertEqual(data["warning"]["code"], "discovery-failed")

    def test_rejects_unsupported_option_value(self):
        with self.assertRaises(printers.BackendError) as context:
            self.backend.set_options(
                {"queue": "Office", "options": {"Duplex": "not-a-choice"}}
            )
        self.assertEqual(context.exception.code, "invalid-request")

    def test_rejects_unknown_option(self):
        with self.assertRaises(printers.BackendError) as context:
            self.backend.set_options(
                {"queue": "Office", "options": {"Injected": "value"}}
            )
        self.assertEqual(context.exception.code, "invalid-request")


class CLITests(unittest.TestCase):
    def setUp(self):
        self.backend = printers.PrinterBackend(FakeCups(), FakeHelper())

    def test_dispatch_has_versioned_envelope(self):
        result = printers.dispatch("jobs", {}, self.backend)
        self.assertEqual(result["version"], 1)
        self.assertTrue(result["ok"])

    def test_unknown_command_is_typed(self):
        with self.assertRaises(printers.BackendError) as context:
            printers.dispatch("bogus", {}, self.backend)
        self.assertEqual(context.exception.code, "invalid-command")
        self.assertEqual(context.exception.exit_code, 2)

    def test_rejects_non_object_request(self):
        with self.assertRaises(printers.BackendError) as context:
            printers.dispatch("jobs", [], self.backend)
        self.assertEqual(context.exception.code, "invalid-request")

    def test_validates_required_types(self):
        with self.assertRaises(printers.BackendError) as context:
            printers.dispatch(
                "set-enabled", {"queue": "Office", "enabled": "false"}, self.backend
            )
        self.assertEqual(context.exception.code, "invalid-request")

    def test_invalid_json_produces_json_error_and_diagnostic(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            patch.object(sys, "stdin", io.StringIO("{")),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            code = printers.main(["jobs"])
        response = json.loads(stdout.getvalue())
        self.assertEqual(code, 2)
        self.assertEqual(response["error"]["code"], "invalid-json")
        self.assertNotEqual(stderr.getvalue(), "")

    def test_unknown_cli_command_produces_json_error(self):
        stdout = io.StringIO()
        with (
            patch.object(sys, "stdin", io.StringIO("")),
            redirect_stdout(stdout),
            redirect_stderr(io.StringIO()),
        ):
            code = printers.main(["bogus"])
        response = json.loads(stdout.getvalue())
        self.assertEqual(code, 2)
        self.assertEqual(response["error"]["code"], "invalid-command")

    def test_add_argv_builds_request(self):
        args = printers.build_parser().parse_args(
            [
                "add",
                "--name",
                "Office Printer",
                "--uri",
                "ipp://office/ipp/print",
                "--model",
                "everywhere",
            ]
        )
        self.assertEqual(
            printers._request_from_args(args),
            {
                "name": "Office Printer",
                "uri": "ipp://office/ipp/print",
                "model": "everywhere",
            },
        )

    def test_models_argv_builds_device_object(self):
        args = printers.build_parser().parse_args(
            [
                "models",
                "--device-uri",
                "socket://printer:9100",
                "--device-id",
                "MFG:Acme;MDL:Laser;",
            ]
        )
        self.assertEqual(
            printers._request_from_args(args),
            {
                "device": {
                    "device-uri": "socket://printer:9100",
                    "device-id": "MFG:Acme;MDL:Laser;",
                }
            },
        )

    def test_boolean_argv_is_typed(self):
        args = printers.build_parser().parse_args(
            ["set-enabled", "--queue", "Office", "--enabled", "false"]
        )
        self.assertEqual(
            printers._request_from_args(args), {"queue": "Office", "enabled": False}
        )

    def test_manage_argv_requires_queue_value(self):
        args = printers.build_parser().parse_args(["manage", "--queue", "Office"])
        self.assertEqual(printers._request_from_args(args), {"queue": "Office"})

    def test_snapshot_legacy_flag_is_typed(self):
        args = printers.build_parser().parse_args(
            ["snapshot", "--include-legacy", "true"]
        )
        self.assertEqual(
            printers._request_from_args(args), {"includeLegacy": True}
        )

    def test_set_options_argv_decodes_json_object(self):
        args = printers.build_parser().parse_args(
            ["set-options", "--queue", "Office", "--options", '{"Duplex":"None"}']
        )
        self.assertEqual(
            printers._request_from_args(args),
            {"queue": "Office", "options": {"Duplex": "None"}},
        )

    def test_queues_command_takes_no_arguments(self):
        args = printers.build_parser().parse_args(["queues"])
        self.assertEqual(printers._request_from_args(args), {})

    def test_invalid_argv_produces_only_json_on_stdout(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = printers.main(["set-enabled", "--enabled", "maybe"])
        lines = stdout.getvalue().splitlines()
        self.assertEqual(code, 2)
        self.assertEqual(len(lines), 1)
        self.assertEqual(json.loads(lines[0])["error"]["code"], "invalid-request")
        self.assertNotEqual(stderr.getvalue(), "")


class OptionsAdapterTests(unittest.TestCase):
    class Choice(dict):
        pass

    class Option:
        keyword = "Duplex"
        text = "Two-sided"
        defchoice = "None"
        choices = [{"choice": "None", "text": "Off"}, {"choice": "DuplexNoTumble", "text": "Long"}]

    class Group:
        def __init__(self):
            self.options = [OptionsAdapterTests.Option()]

    class PPD:
        def __init__(self):
            self.optionGroups = [OptionsAdapterTests.Group()]

    class CupsModule:
        @staticmethod
        def PPD(path):
            return OptionsAdapterTests.PPD()

    class Connection:
        def getPrinterAttributes(self, queue):
            return {"Duplex-default": "DuplexNoTumble"}

        def getPPD(self, queue):
            return "/controlled/printer.ppd"

    def test_ppd_is_always_removed_after_reading(self):
        adapter = printers.PyCupsAdapter(self.Connection(), self.CupsModule())
        with patch.object(printers.os, "unlink") as unlink:
            result = adapter.options("Office")
        unlink.assert_called_once_with("/controlled/printer.ppd")
        self.assertEqual(result["options"][0]["default"], "DuplexNoTumble")


class PkHelperAdapterTests(unittest.TestCase):
    class Interface:
        def __init__(self, result):
            self.result = result
            self.args = None

        def DevicesGet(self, *args, **kwargs):
            self.args = (args, kwargs)
            return self.result

    def test_devices_get_uses_new_signature_and_timeout(self):
        interface = self.Interface(
            ("", {"device-uri:0": "ipp://x", "device-info:0": "Printer"})
        )
        rows = printers.PkHelperAdapter(interface).devices(7)
        self.assertEqual(interface.args[0], (7, printers.MAX_DEVICES, [], []))
        self.assertEqual(interface.args[1]["timeout"], 8)
        self.assertEqual(rows[0]["device-uri"], "ipp://x")

    def test_preflight_does_not_call_policy_protected_method(self):
        interface = self.Interface(AssertionError("must not be called"))
        self.assertEqual(
            printers.PkHelperAdapter(interface).preflight(),
            {"cupsPkHelper": True, "systemBus": True},
        )
        self.assertIsNone(interface.args)

    def test_devices_get_error_is_not_exposed(self):
        interface = self.Interface(("private server detail", {}))
        with self.assertRaises(printers.BackendError) as context:
            printers.PkHelperAdapter(interface).devices()
        self.assertEqual(context.exception.code, "discovery-failed")
        self.assertNotIn("private", context.exception.message)


if __name__ == "__main__":
    unittest.main()
