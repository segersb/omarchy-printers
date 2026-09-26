#!/usr/bin/env python3
"""CUPS push notifications. Stdout contains only fixed protocol tokens."""
import signal

EVENTS = ["printer-added", "printer-deleted", "printer-state-changed",
          "printer-config-changed", "job-created", "job-state-changed",
          "job-completed", "server-started", "server-restarted", "server-stopped"]
INTERFACE = "org.cups.cupsd.Notifier"
PATH = "/org/cups/cupsd/Notifier"
LEASE = 3600


class Subscription:
    def __init__(self, connect, schedule, cancel_timer, emit):
        self.connect = connect
        self.schedule = schedule
        self.cancel_timer = cancel_timer
        self.emit = emit
        self.connection = None
        self.id = None
        self.timer = None

    def stop(self):
        if self.timer is not None:
            self.cancel_timer(self.timer)
            self.timer = None
        if self.id is not None:
            try:
                self.connection.cancelSubscription(self.id)
            except Exception:
                pass
        self.id = None
        self.connection = None

    def arm_renewal(self):
        rows = self.connection.getSubscriptions("/", my_subscriptions=True)
        row = next(r for r in rows if int(r.get("notify-subscription-id", -1)) == self.id)
        lease = int(row["notify-lease-duration"])
        if lease > 0:
            self.timer = self.schedule(max(1, lease // 2), self.renew)

    def start(self):
        self.stop()
        try:
            self.connection = self.connect()
            self.id = self.connection.createSubscription(
                "/", events=EVENTS, recipient_uri="dbus://", lease_duration=LEASE)
            self.arm_renewal()
        except Exception:
            self.stop()
            self.emit("unavailable")
            return False
        self.emit("ready")
        return True

    def renew(self):
        self.timer = None
        try:
            self.connection.renewSubscription(self.id, lease_duration=LEASE)
            self.arm_renewal()
        except Exception:
            self.start()  # One recovery attempt; never a recurring status poll.
        return False


def main():
    import cups
    import dbus
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib, GLibUnix

    DBusGMainLoop(set_as_default=True)
    loop = GLib.MainLoop()
    cups.setPasswordCB(lambda prompt: "")  # Monitoring must never prompt.
    emit = lambda token: print(token, flush=True)
    subscription = Subscription(cups.Connection, GLib.timeout_add_seconds,
                                GLib.source_remove, emit)
    pending = [None]

    def changed():
        pending[0] = None
        emit("changed")
        return False

    def notification(*args, member=None):
        # Never forward printer-provided signal arguments to the shell.
        if member in ("ServerStarted", "ServerRestarted"):
            subscription.start()
        elif member == "ServerStopped":
            subscription.stop()
            emit("unavailable")
        elif pending[0] is None:
            pending[0] = GLib.timeout_add(250, changed)

    bus = dbus.SystemBus()
    bus.add_signal_receiver(notification, dbus_interface=INTERFACE,
                            path=PATH, member_keyword="member")
    # systemd lifecycle signals allow recovery even when CUPS lost its subscriptions.
    def unit_changed(interface, values, invalidated):
        if interface == "org.freedesktop.systemd1.Unit" and "ActiveState" in values:
            if values["ActiveState"] == "active":
                subscription.start()
            elif values["ActiveState"] in ("inactive", "failed"):
                subscription.stop()
                emit("unavailable")
    try:
        manager = dbus.Interface(bus.get_object("org.freedesktop.systemd1", "/org/freedesktop/systemd1"),
                                 "org.freedesktop.systemd1.Manager")
        manager.Subscribe()
        bus.add_signal_receiver(unit_changed, signal_name="PropertiesChanged",
                                dbus_interface="org.freedesktop.DBus.Properties",
                                path="/org/freedesktop/systemd1/unit/cups_2eservice")
    except dbus.DBusException:
        pass  # Panel opening and lease renewal still provide recovery opportunities.

    def disconnected(connection):
        emit("unavailable")
        loop.quit()
    bus.call_on_disconnection(disconnected)

    def stop(*args):
        loop.quit()
        return False
    for sig in (signal.SIGTERM, signal.SIGINT):
        GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, sig, stop)

    subscription.start()
    try:
        loop.run()
    finally:
        subscription.stop()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        print("unavailable", flush=True)
        raise SystemExit(1)
