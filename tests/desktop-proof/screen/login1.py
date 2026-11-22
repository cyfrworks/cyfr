# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""logind as swayidle meets it, for the idle proof's container (idle.sh):
org.freedesktop.login1 on the container's system bus, granting delay
locks. SIGUSR1 sends the signal of a sleep beginning, SIGUSR2 of waking."""

import os
import signal

from gi.repository import Gio, GLib

MANAGER = "org.freedesktop.login1.Manager"
PATH = "/org/freedesktop/login1"
INTERFACE = """<node><interface name="org.freedesktop.login1.Manager">
<method name="Inhibit"><arg type="s" direction="in"/><arg type="s" direction="in"/>
<arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="h" direction="out"/></method>
<signal name="PrepareForSleep"><arg type="b"/></signal>
<property name="BlockInhibited" type="s" access="read"/>
</interface></node>"""

bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)
granted = []


def inhibit(_bus, _sender, _path, _interface, _method, _parameters, invocation):
    read, write = os.pipe()
    granted.append(read)
    fds = Gio.UnixFDList.new()
    handle = fds.append(write)
    os.close(write)
    invocation.return_value_with_unix_fd_list(GLib.Variant("(h)", (handle,)), fds)


def prepare(going_down):
    bus.emit_signal(None, PATH, MANAGER, "PrepareForSleep", GLib.Variant("(b)", (going_down,)))
    return True


bus.register_object(PATH, Gio.DBusNodeInfo.new_for_xml(INTERFACE).interfaces[0], inhibit,
                    lambda *_: GLib.Variant("s", ""), None)
Gio.bus_own_name_on_connection(bus, "org.freedesktop.login1", Gio.BusNameOwnerFlags.NONE, None, None)
GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, prepare, True)
GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR2, prepare, False)
GLib.MainLoop().run()
