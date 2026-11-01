#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Runs inside labwc on this machine's own screen, in the project directory
# (cyfr-screen.service): the on-screen keyboard, always visible, and Chrome,
# on the waiting page until CYFR answers, then on the setup link, which goes
# to Prism once setup is done. It never starts or stops CYFR. `cyfr screen
# on` fills in the address and port. The setup token stays out of arguments:
# a page beside .env, as private as it is, holds it.
screen=$PWD/.cyfr/screen
@PROXY@

wvkbd-mobintl &

answers() { curl -s -o /dev/null --max-time 2 http://127.0.0.1:@PORT@/; }

chrome() {
    google-chrome-stable "$@" --no-first-run --no-default-browser-check \
        --ozone-platform=wayland --user-data-dir="$screen/chrome" "--app=file://$screen/$page" &
    browser=$!
}

while :; do
    if answers; then
        page=open.html
        token=$(sed -n 's/^CYFR_SETUP_TOKEN=//p' .env)
        (umask 077 && printf '<script>location.replace("%s")</script>\n' "@ADDRESS@/setup#$token" >"$screen/$page")
        chrome "$@"
        wait "$browser"
    else
        page=waiting.html
        chrome "$@"
        while kill -0 "$browser" 2>/dev/null && ! answers; do sleep 2; done
        kill "$browser" 2>/dev/null
        wait "$browser"
    fi
    sleep 1
done
