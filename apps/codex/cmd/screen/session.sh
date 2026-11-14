#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The main process of this machine's screen (cyfr-screen.service): labwc
# under a D-Bus of its own, which starts launcher.sh. PAMName=login puts
# this process and everything it starts in its login session's scope,
# outside the service's cgroup, and labwc starts the launcher apart from
# it, so the service's stop (systemctl stop, `cyfr screen off`, `cyfr
# uninstall`) signals this process alone. Whenever it ends, at that stop's
# SIGTERM or because labwc ended by itself, it ends its login session, and
# logind stops every process in it: labwc, its D-Bus, the launcher, `cyfr
# screen shell` and Chrome. It then exits 0: after a stop the service
# stays stopped; after labwc's own end Restart= starts the screen again,
# in a new session. A SIGKILL to this process ends nothing else.
#
# The trap ends the session wherever the signal lands, before the wait as
# well as during it, and ignores the signals that follow, logind's
# SIGTERM to this session's processes among them. The compositor keeps
# the terminal as its standard input, which a background job would
# otherwise lose.
end() {
    trap '' TERM HUP INT
    loginctl --no-ask-password terminate-session self
    exit 0
}
trap end TERM HUP INT
exec 3<&0
dbus-run-session labwc -C @DIR@/.cyfr/screen -s @DIR@/.cyfr/screen/launcher.sh <&3 3<&- &
wait
end
