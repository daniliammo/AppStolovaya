#!/usr/bin/python3
"""D-Bus integration: dbus-run-session -- /usr/bin/python3 tests/test_export_notification.py build/Столовая

Uses fake notification and file manager services; never opens real windows.
Requires python3-gi. The application runs without GTK or a display.
"""
import os
from pathlib import Path
import subprocess
import sys
import unittest

from gi.repository import Gio, GLib


APP = str(Path(sys.argv.pop()).resolve())
NOTIFICATIONS = "org.freedesktop.Notifications"
MANAGER = "org.freedesktop.FileManager1"
XML = """<node>
<interface name="org.freedesktop.Notifications">
  <method name="Notify">
    <arg type="s" direction="in"/><arg type="u" direction="in"/>
    <arg type="s" direction="in"/><arg type="s" direction="in"/>
    <arg type="s" direction="in"/><arg type="as" direction="in"/>
    <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
    <arg type="u" direction="out"/>
  </method>
  <signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
  <signal name="ActivationToken"><arg type="u"/><arg type="s"/></signal>
  <signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
</interface>
<interface name="org.freedesktop.FileManager1">
  <method name="ShowItems"><arg type="as" direction="in"/><arg type="s" direction="in"/></method>
</interface>
</node>"""


class ExportNotificationTest(unittest.TestCase):
    def setUp(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.registrations = []
        for interface in Gio.DBusNodeInfo.new_for_xml(XML).interfaces:
            self.bus.call_sync(
                "org.freedesktop.DBus", "/org/freedesktop/DBus",
                "org.freedesktop.DBus", "RequestName",
                GLib.Variant("(su)", (interface.name, 0)), None,
                Gio.DBusCallFlags.NONE, 2000, None)
            self.registrations.append(self.bus.register_object(
                "/" + interface.name.replace(".", "/"), interface,
                self.method_call, None, None))
        self.notifications = []
        self.opened = []
        self.action = "default"
        self.loop = GLib.MainLoop()

    def tearDown(self):
        for registration in self.registrations:
            self.bus.unregister_object(registration)

    def signal(self, name, signature, values):
        self.bus.emit_signal(None, "/org/freedesktop/Notifications", NOTIFICATIONS,
                             name, GLib.Variant(signature, values))

    def invoke(self):
        # Signals for another application's notification must be ignored.
        self.signal("ActionInvoked", "(us)", (99, "default"))
        if self.action == "close":
            self.signal("NotificationClosed", "(uu)", (42, 2))
        else:
            self.signal("ActivationToken", "(us)", (42, "activation-token"))
            self.signal("ActionInvoked", "(us)", (42, self.action))
        return GLib.SOURCE_REMOVE

    def method_call(self, connection, sender, path, interface, method, parameters, invocation):
        if method == "Notify":
            self.notifications.append(parameters.unpack())
            invocation.return_value(GLib.Variant("(u)", (42,)))
            if self.notifications[-1][5]:
                GLib.timeout_add(30, self.invoke)
        elif method == "ShowItems":
            self.opened.append(parameters.unpack())
            invocation.return_value(GLib.Variant("()", ()))

    def run_helper(self, action, files):
        self.action = action
        env = dict(os.environ, DISPLAY="", WAYLAND_DISPLAY="")
        child = subprocess.Popen([APP, "--export-notification", "Сохранено", "\n".join(files), *files],
                                 env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = GLib.get_monotonic_time() + 5_000_000

        def poll():
            if child.poll() is not None or GLib.get_monotonic_time() > deadline:
                self.loop.quit()
                return GLib.SOURCE_REMOVE
            return GLib.SOURCE_CONTINUE

        GLib.timeout_add(20, poll)
        self.loop.run()
        if child.poll() is None:
            child.kill()
        stdout, stderr = child.communicate()
        self.assertEqual(child.returncode, 0, stderr.decode())
        self.assertEqual(len(self.notifications), 1)
        self.assertNotIn("desktop-entry", self.notifications[0][6])
        if files:
            self.assertEqual(self.notifications[0][5],
                             ["default", "Открыть папку", "open-folder", "Открыть папку"])

    def test_click_body(self):
        files = ["/tmp/Папка с пробелами/отчёт.xlsx", "/tmp/Папка с пробелами/другой.xlsx"]
        self.run_helper("default", files)
        self.assertEqual(self.opened, [([Path(f).as_uri() for f in files], "activation-token")])

    def test_click_button(self):
        self.run_helper("open-folder", ["/tmp/report.xlsx"])
        self.assertEqual(self.opened, [(["file:///tmp/report.xlsx"], "activation-token")])

    def test_dismiss(self):
        self.run_helper("close", ["/tmp/report.xlsx"])
        self.assertEqual(self.opened, [])

    def test_error_without_files(self):
        self.run_helper("close", [])
        self.assertEqual(self.notifications[0][5], [])
        self.assertEqual(self.opened, [])


if __name__ == "__main__":
    unittest.main()
