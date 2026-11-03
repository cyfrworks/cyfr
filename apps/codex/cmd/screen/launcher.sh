#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Runs inside labwc on this machine's own screen, in the project directory
# (cyfr-screen.service): `cyfr screen shell`, which runs the on-screen
# keyboard, the idle watch and Chrome on the shell's own pages, and locks
# CYFR whenever any of them ends. It never starts or stops CYFR. Tokens stay
# in .env, which the shell reads itself. A shell that ends is started again,
# locked.
while :; do
    @CYFR@ screen shell
    sleep 1
done
