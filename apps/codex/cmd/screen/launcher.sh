#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Runs inside labwc on this machine's own screen, in the project directory
# (cyfr-screen.service): the CYFR app as the box's screen, a native Wayland
# client, which runs `cyfr screen shell` there: the on-screen keyboard, the
# idle and suspend watches and the shell's own pages, locking CYFR
# whenever any of them ends. It never starts or stops CYFR. Tokens stay in
# .env, which the shell reads itself. The app ends when its shell does,
# and an app that ends is started again, locked.
while :; do
    /opt/cyfr/CYFR --screen-project=@DIR@
    sleep 1
done
