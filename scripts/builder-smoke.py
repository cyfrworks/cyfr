#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Smoke-test a builder image as docker-compose.yml's locus-builds service.

Starts the image with the locus-builds service's own settings (the
`locus-builds` profile of docker-compose.yml, layered with
tests/builder-image/compose.locus-builds.yml for the image and a loopback
port), then drives the build wire (`Prima.BuilderProtocol`, signed by
tests/builder-image/stack.py) through a component's life: a Rust build
that streams its progress and resolves its Cargo.lock, a dependency added
without re-resolving (refused by `--locked`), a re-resolve, a locked
rebuild, a compiler error that reports its diagnostics, and a tincture
build from its lockfile through npm and Vite; no process of a build uid may be left running
and no build home may remain. A request at another protocol version is
refused naming both ends' versions, one signed with another key is refused
as unauthorized, and the routes the wire replaced are no operation. Then,
with a 15 s build deadline, a build that outlives it, having started a
daemon that ignores SIGTERM, is refused as timed out with nothing of it
left.

Usage: scripts/builder-smoke.py IMAGE
"""

import json
import os
import secrets
import shutil
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "builder-image"))

from stack import (  # noqa: E402
    RELEASE_BIN, RELEASE_USER, VERSION, Stack, brief, diagnostics, expect, output_bytes, output_file, tincture,
)

LIB_RS = """#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::reagent::compute::Guest;

struct Smoke;
bindings::export!(Smoke with_types_in bindings);

impl Guest for Smoke {
    fn compute(input: String) -> String {
        input
    }
}
"""

# The lockfile `npm install --package-lock-only` writes for TINCTURE's
# package.json, one package a line: a tincture builds only from its
# lockfile, and `npm ci` installs exactly these from the npm registry.
# Changing the package's dependencies means regenerating these lines.
TINCTURE_PACKAGES = {
    "node_modules/@esbuild/aix-ppc64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/aix-ppc64/-/aix-ppc64-0.25.12.tgz","integrity":"sha512-Hhmwd6CInZ3dwpuGTF8fJG6yoWmsToE+vYgD4nytZVxcu1ulHpUQRAB1UJ8+N1Am3Mz4+xOByoQoSZf4D+CpkA==","cpu":["ppc64"],"dev":True,"license":"MIT","optional":True,"os":["aix"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/android-arm": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/android-arm/-/android-arm-0.25.12.tgz","integrity":"sha512-VJ+sKvNA/GE7Ccacc9Cha7bpS8nyzVv0jdVgwNDaR4gDMC/2TTRc33Ip8qrNYUcpkOHUT5OZ0bUcNNVZQ9RLlg==","cpu":["arm"],"dev":True,"license":"MIT","optional":True,"os":["android"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/android-arm64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/android-arm64/-/android-arm64-0.25.12.tgz","integrity":"sha512-6AAmLG7zwD1Z159jCKPvAxZd4y/VTO0VkprYy+3N2FtJ8+BQWFXU+OxARIwA46c5tdD9SsKGZ/1ocqBS/gAKHg==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["android"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/android-x64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/android-x64/-/android-x64-0.25.12.tgz","integrity":"sha512-5jbb+2hhDHx5phYR2By8GTWEzn6I9UqR11Kwf22iKbNpYrsmRB18aX/9ivc5cabcUiAT/wM+YIZ6SG9QO6a8kg==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["android"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/darwin-arm64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/darwin-arm64/-/darwin-arm64-0.25.12.tgz","integrity":"sha512-N3zl+lxHCifgIlcMUP5016ESkeQjLj/959RxxNYIthIg+CQHInujFuXeWbWMgnTo4cp5XVHqFPmpyu9J65C1Yg==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["darwin"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/darwin-x64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/darwin-x64/-/darwin-x64-0.25.12.tgz","integrity":"sha512-HQ9ka4Kx21qHXwtlTUVbKJOAnmG1ipXhdWTmNXiPzPfWKpXqASVcWdnf2bnL73wgjNrFXAa3yYvBSd9pzfEIpA==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["darwin"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/freebsd-arm64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/freebsd-arm64/-/freebsd-arm64-0.25.12.tgz","integrity":"sha512-gA0Bx759+7Jve03K1S0vkOu5Lg/85dou3EseOGUes8flVOGxbhDDh/iZaoek11Y8mtyKPGF3vP8XhnkDEAmzeg==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["freebsd"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/freebsd-x64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/freebsd-x64/-/freebsd-x64-0.25.12.tgz","integrity":"sha512-TGbO26Yw2xsHzxtbVFGEXBFH0FRAP7gtcPE7P5yP7wGy7cXK2oO7RyOhL5NLiqTlBh47XhmIUXuGciXEqYFfBQ==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["freebsd"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/linux-arm": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/linux-arm/-/linux-arm-0.25.12.tgz","integrity":"sha512-lPDGyC1JPDou8kGcywY0YILzWlhhnRjdof3UlcoqYmS9El818LLfJJc3PXXgZHrHCAKs/Z2SeZtDJr5MrkxtOw==","cpu":["arm"],"dev":True,"license":"MIT","optional":True,"os":["linux"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/linux-arm64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/linux-arm64/-/linux-arm64-0.25.12.tgz","integrity":"sha512-8bwX7a8FghIgrupcxb4aUmYDLp8pX06rGh5HqDT7bB+8Rdells6mHvrFHHW2JAOPZUbnjUpKTLg6ECyzvas2AQ==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["linux"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/linux-ia32": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/linux-ia32/-/linux-ia32-0.25.12.tgz","integrity":"sha512-0y9KrdVnbMM2/vG8KfU0byhUN+EFCny9+8g202gYqSSVMonbsCfLjUO+rCci7pM0WBEtz+oK/PIwHkzxkyharA==","cpu":["ia32"],"dev":True,"license":"MIT","optional":True,"os":["linux"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/linux-loong64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/linux-loong64/-/linux-loong64-0.25.12.tgz","integrity":"sha512-h///Lr5a9rib/v1GGqXVGzjL4TMvVTv+s1DPoxQdz7l/AYv6LDSxdIwzxkrPW438oUXiDtwM10o9PmwS/6Z0Ng==","cpu":["loong64"],"dev":True,"license":"MIT","optional":True,"os":["linux"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/linux-mips64el": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/linux-mips64el/-/linux-mips64el-0.25.12.tgz","integrity":"sha512-iyRrM1Pzy9GFMDLsXn1iHUm18nhKnNMWscjmp4+hpafcZjrr2WbT//d20xaGljXDBYHqRcl8HnxbX6uaA/eGVw==","cpu":["mips64el"],"dev":True,"license":"MIT","optional":True,"os":["linux"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/linux-ppc64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/linux-ppc64/-/linux-ppc64-0.25.12.tgz","integrity":"sha512-9meM/lRXxMi5PSUqEXRCtVjEZBGwB7P/D4yT8UG/mwIdze2aV4Vo6U5gD3+RsoHXKkHCfSxZKzmDssVlRj1QQA==","cpu":["ppc64"],"dev":True,"license":"MIT","optional":True,"os":["linux"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/linux-riscv64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/linux-riscv64/-/linux-riscv64-0.25.12.tgz","integrity":"sha512-Zr7KR4hgKUpWAwb1f3o5ygT04MzqVrGEGXGLnj15YQDJErYu/BGg+wmFlIDOdJp0PmB0lLvxFIOXZgFRrdjR0w==","cpu":["riscv64"],"dev":True,"license":"MIT","optional":True,"os":["linux"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/linux-s390x": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/linux-s390x/-/linux-s390x-0.25.12.tgz","integrity":"sha512-MsKncOcgTNvdtiISc/jZs/Zf8d0cl/t3gYWX8J9ubBnVOwlk65UIEEvgBORTiljloIWnBzLs4qhzPkJcitIzIg==","cpu":["s390x"],"dev":True,"license":"MIT","optional":True,"os":["linux"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/linux-x64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.25.12.tgz","integrity":"sha512-uqZMTLr/zR/ed4jIGnwSLkaHmPjOjJvnm6TVVitAa08SLS9Z0VM8wIRx7gWbJB5/J54YuIMInDquWyYvQLZkgw==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["linux"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/netbsd-arm64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/netbsd-arm64/-/netbsd-arm64-0.25.12.tgz","integrity":"sha512-xXwcTq4GhRM7J9A8Gv5boanHhRa/Q9KLVmcyXHCTaM4wKfIpWkdXiMog/KsnxzJ0A1+nD+zoecuzqPmCRyBGjg==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["netbsd"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/netbsd-x64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/netbsd-x64/-/netbsd-x64-0.25.12.tgz","integrity":"sha512-Ld5pTlzPy3YwGec4OuHh1aCVCRvOXdH8DgRjfDy/oumVovmuSzWfnSJg+VtakB9Cm0gxNO9BzWkj6mtO1FMXkQ==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["netbsd"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/openbsd-arm64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/openbsd-arm64/-/openbsd-arm64-0.25.12.tgz","integrity":"sha512-fF96T6KsBo/pkQI950FARU9apGNTSlZGsv1jZBAlcLL1MLjLNIWPBkj5NlSz8aAzYKg+eNqknrUJ24QBybeR5A==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["openbsd"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/openbsd-x64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/openbsd-x64/-/openbsd-x64-0.25.12.tgz","integrity":"sha512-MZyXUkZHjQxUvzK7rN8DJ3SRmrVrke8ZyRusHlP+kuwqTcfWLyqMOE3sScPPyeIXN/mDJIfGXvcMqCgYKekoQw==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["openbsd"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/openharmony-arm64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/openharmony-arm64/-/openharmony-arm64-0.25.12.tgz","integrity":"sha512-rm0YWsqUSRrjncSXGA7Zv78Nbnw4XL6/dzr20cyrQf7ZmRcsovpcRBdhD43Nuk3y7XIoW2OxMVvwuRvk9XdASg==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["openharmony"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/sunos-x64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/sunos-x64/-/sunos-x64-0.25.12.tgz","integrity":"sha512-3wGSCDyuTHQUzt0nV7bocDy72r2lI33QL3gkDNGkod22EsYl04sMf0qLb8luNKTOmgF/eDEDP5BFNwoBKH441w==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["sunos"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/win32-arm64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/win32-arm64/-/win32-arm64-0.25.12.tgz","integrity":"sha512-rMmLrur64A7+DKlnSuwqUdRKyd3UE7oPJZmnljqEptesKM8wx9J8gx5u0+9Pq0fQQW8vqeKebwNXdfOyP+8Bsg==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["win32"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/win32-ia32": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/win32-ia32/-/win32-ia32-0.25.12.tgz","integrity":"sha512-HkqnmmBoCbCwxUKKNPBixiWDGCpQGVsrQfJoVGYLPT41XWF8lHuE5N6WhVia2n4o5QK5M4tYr21827fNhi4byQ==","cpu":["ia32"],"dev":True,"license":"MIT","optional":True,"os":["win32"],"engines":{"node":">=18"}},
    "node_modules/@esbuild/win32-x64": {"version":"0.25.12","resolved":"https://registry.npmjs.org/@esbuild/win32-x64/-/win32-x64-0.25.12.tgz","integrity":"sha512-alJC0uCZpTFrSL0CCDjcgleBXPnCrEAhTBILpeAp7M/OFgoqtAetfBzX0xM00MUsVVPpVjlPuMbREqnZCXaTnA==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["win32"],"engines":{"node":">=18"}},
    "node_modules/@napi-rs/lzma-linux-x64-gnu": {"version":"1.5.1","resolved":"https://registry.npmjs.org/@napi-rs/lzma-linux-x64-gnu/-/lzma-linux-x64-gnu-1.5.1.tgz","integrity":"sha512-oTXEIha4SsuXdTA4Iyskj0kpdx2yVXdhd75c2v3xGrHFfVMsbhTPZU/nMPL4sWKo4pBHm3aucLaqGlF696dTyQ==","cpu":["x64"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"],"engines":{"node":"^22.20 || ^24.12 || >=25"}},
    "node_modules/@rollup/rollup-android-arm-eabi": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-android-arm-eabi/-/rollup-android-arm-eabi-4.63.5.tgz","integrity":"sha512-J25QJU+B78T4FhhBsNpLJyVWOi31mwtpcMwywHmOKH65Q9IWGA81gPj+dnwlhU8wktVriYE+tFAaQgrnJRzAZg==","cpu":["arm"],"dev":True,"license":"MIT","optional":True,"os":["android"]},
    "node_modules/@rollup/rollup-android-arm64": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-android-arm64/-/rollup-android-arm64-4.63.5.tgz","integrity":"sha512-LDopB3zuZM5Ux9TT2luNEBJW/tYbGU2g1d+VpKk6I+gSKDb+/7sYE6M225gRQt4RbMX6MSwMsVR/phdjVUgRLg==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["android"]},
    "node_modules/@rollup/rollup-darwin-arm64": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-darwin-arm64/-/rollup-darwin-arm64-4.63.5.tgz","integrity":"sha512-wlJEERGfeuHeBavCL2qVnNacOK43NDoZM4sjkeRPymd04OAE9T1zBqDJgmZ+CIsPTYKwdzpUC8vmOw84dwY4Tg==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["darwin"]},
    "node_modules/@rollup/rollup-darwin-x64": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-darwin-x64/-/rollup-darwin-x64-4.63.5.tgz","integrity":"sha512-4nJJGg5jbo2wwPP4JP+LfEBA3bvP8rU9CLuhp7jWvq9sxEyhjQFTFdrqi+/dHEin/pd8jpT0vcehIpnZtmEdcQ==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["darwin"]},
    "node_modules/@rollup/rollup-freebsd-arm64": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-freebsd-arm64/-/rollup-freebsd-arm64-4.63.5.tgz","integrity":"sha512-DrZbyCDF1hneuO6jRbvZ2D7+PIBM6yIwYnJpg2vIk58T+wuFpiaGZrfUr59lDWw45bg+IrpTGLPiNi/Fk4w3Cg==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["freebsd"]},
    "node_modules/@rollup/rollup-freebsd-x64": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-freebsd-x64/-/rollup-freebsd-x64-4.63.5.tgz","integrity":"sha512-gqfUVMJMB3mehqywxp6hTBFfgtMQykZY19+cfiaYP0toIJLb/1DZRJHVkQQGP13W4TAwfZDWeg1qBcheTRioXQ==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["freebsd"]},
    "node_modules/@rollup/rollup-linux-arm-gnueabihf": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-arm-gnueabihf/-/rollup-linux-arm-gnueabihf-4.63.5.tgz","integrity":"sha512-CFmhpvAwzSaWMlN3VN7UtmoTihlZNzoP0juQib5TQRnYUyDV8dXeWOp29sobWAT6gXl/hQgAClLlEiYozQG3OQ==","cpu":["arm"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-arm-musleabihf": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-arm-musleabihf/-/rollup-linux-arm-musleabihf-4.63.5.tgz","integrity":"sha512-Uc9H8eXCOayV6JLTH5bXKMId6qbhNHa818/BgYjm4jrlq3vZquC9cqyvHBw17xy5Mnj5f+I3gFK5JcEf3hSqrw==","cpu":["arm"],"dev":True,"libc":["musl"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-arm64-gnu": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-arm64-gnu/-/rollup-linux-arm64-gnu-4.63.5.tgz","integrity":"sha512-VcPr/szv/1BFw112Kt//fxulXt/JPqzzidU84iW68L2DdjnOO8QFUv2zTSYBEPHD6movBD4z+bbr5y60GYM7Jw==","cpu":["arm64"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-arm64-musl": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-arm64-musl/-/rollup-linux-arm64-musl-4.63.5.tgz","integrity":"sha512-BnxtJ5/91BrIHYIkGrmjz/lbMhqEHt1dPFqIxIFR+jPn0xVc/oUSCtIT089zfp5ufwGDlYz2UC+Fe1SRBpYFbQ==","cpu":["arm64"],"dev":True,"libc":["musl"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-loong64-gnu": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-loong64-gnu/-/rollup-linux-loong64-gnu-4.63.5.tgz","integrity":"sha512-LrYcHZwF+fAMNKHYTOQ5osWM4AZF7YF6D+XtsjDyEvljtt11twc+zHVXBLNEjxVSUnKYsOhvVz4Z213eW02COQ==","cpu":["loong64"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-loong64-musl": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-loong64-musl/-/rollup-linux-loong64-musl-4.63.5.tgz","integrity":"sha512-nj7QKQePAAUpCpJHtg0pR0W/b92A9NO17JS3BAQmHDn/yhmkir2p8llrKY9TOhleKIaSzy1JhxS3T9FVld6coA==","cpu":["loong64"],"dev":True,"libc":["musl"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-ppc64-gnu": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-ppc64-gnu/-/rollup-linux-ppc64-gnu-4.63.5.tgz","integrity":"sha512-5ylkX6dWMeBKge9nTU+Rxfb+ZfaCIJ9lRqIFaK0eAMcWp7OJbYnLveLgXmm0VrvuLKb8qIK+mHyH0qu88RM+iA==","cpu":["ppc64"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-ppc64-musl": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-ppc64-musl/-/rollup-linux-ppc64-musl-4.63.5.tgz","integrity":"sha512-oHK4ZHYFDKjZviK34I+NwgfbGxgI7ztrNxj2hPTSSNFgeq1a/lEd7dHV2fdGAuTH4Iym3RHJg+vAbWaWG4B7Zg==","cpu":["ppc64"],"dev":True,"libc":["musl"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-riscv64-gnu": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-riscv64-gnu/-/rollup-linux-riscv64-gnu-4.63.5.tgz","integrity":"sha512-UcetmHZ6XOXuUByiKZyQmb55ZPr0LABr3Ec/HB9wKZn6CEAFWZkE+hsJErJ9hbPBC7nI0dKuELx7CoV6IM7TMg==","cpu":["riscv64"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-riscv64-musl": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-riscv64-musl/-/rollup-linux-riscv64-musl-4.63.5.tgz","integrity":"sha512-C5CmDPQBtvjVo8cgQsBs+w6WB0JLkiixhgi6hVLV11hERWdn/p0XcPU2OUcZzac9BPOFq7SbaHFa8r3SWEysCQ==","cpu":["riscv64"],"dev":True,"libc":["musl"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-s390x-gnu": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-s390x-gnu/-/rollup-linux-s390x-gnu-4.63.5.tgz","integrity":"sha512-lHVQHJFKsuuxLMi3MQO9XVL8Tje3JR82CzB+QDKC5NWBcsIWuwsn9uIM5e3lBhI+fF1/s63qnyYqsg65+8rV/w==","cpu":["s390x"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-x64-gnu": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-x64-gnu/-/rollup-linux-x64-gnu-4.63.5.tgz","integrity":"sha512-3W9bTFcQNJn71cSJVM9RKIiZOy8DO/XLDii8Uv/Pm6WKqDRj7JV3ZfuXIEfyuy5LXpIzAbB/1M4Ukp9GKNa7nA==","cpu":["x64"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-linux-x64-musl": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-linux-x64-musl/-/rollup-linux-x64-musl-4.63.5.tgz","integrity":"sha512-VDC7rRJlee/scpki96GZ27Omf6yU87s1YXwVTpjE5841faVlDYYT565rgfmoR1U0sqL7z5ivQSDjcsF6VRXyBA==","cpu":["x64"],"dev":True,"libc":["musl"],"license":"MIT","optional":True,"os":["linux"]},
    "node_modules/@rollup/rollup-openbsd-x64": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-openbsd-x64/-/rollup-openbsd-x64-4.63.5.tgz","integrity":"sha512-z86Ok2p4pTdv5xqCKZsTooO7yBEiaJR/HzU3Wx8RmWsPoLppnMKROhJusQob8B3IE1ghC343kUW9rC2r+Wf3ig==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["openbsd"]},
    "node_modules/@rollup/rollup-openharmony-arm64": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-openharmony-arm64/-/rollup-openharmony-arm64-4.63.5.tgz","integrity":"sha512-IzQmj+xXwQFGhMAMKMQVXkMwMZN3TqkJgAE0nSsqvVwWWciP4AIPMmWRqOQ2GfX7TUDZr+xqGFcBS36CRPGw0g==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["openharmony"]},
    "node_modules/@rollup/rollup-win32-arm64-msvc": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-win32-arm64-msvc/-/rollup-win32-arm64-msvc-4.63.5.tgz","integrity":"sha512-F6qpTaPc9bwBH85kjy0/BLmLSW1uv7AoOXCoRIkg2arlgCYlWYcAbiMkvZuAcaWk9TpCRG//okznLAqLGshkMw==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["win32"]},
    "node_modules/@rollup/rollup-win32-ia32-msvc": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-win32-ia32-msvc/-/rollup-win32-ia32-msvc-4.63.5.tgz","integrity":"sha512-igoDsTFhhwECBeGbUuLeIk7t8Y1apa+cs6mDWpx2EZ0ch7oEQgzHbFUXN9euoHekCAQzXdXApAGkV6jznS7tWw==","cpu":["ia32"],"dev":True,"license":"MIT","optional":True,"os":["win32"]},
    "node_modules/@rollup/rollup-win32-x64-gnu": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-win32-x64-gnu/-/rollup-win32-x64-gnu-4.63.5.tgz","integrity":"sha512-U3teMeMbXFmaM5D+OTJpsOXd+wV/qftIeYF9kBKL4v73641qyJmoXFtA28DQLsnmlyayEsTe72xpLHrArq6vHw==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["win32"]},
    "node_modules/@rollup/rollup-win32-x64-msvc": {"version":"4.63.5","resolved":"https://registry.npmjs.org/@rollup/rollup-win32-x64-msvc/-/rollup-win32-x64-msvc-4.63.5.tgz","integrity":"sha512-ypfC34F3RKXvCXBglGqGMsUSMKlgwd1HX9AOAlx9RoZZ6GaI42YHVeKpzg3JG+wpBUJYTG+NNZhqbDWL8tBZkw==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["win32"]},
    "node_modules/@types/estree": {"version":"1.0.9","resolved":"https://registry.npmjs.org/@types/estree/-/estree-1.0.9.tgz","integrity":"sha512-GhdPgy1el4/ImP05X05Uw4cw2/M93BCUmnEvWZNStlCzEKME4Fkk+YpoA5OiHNQmoS7Cafb8Xa3Pya8m1Qrzeg==","dev":True,"license":"MIT"},
    "node_modules/esbuild": {"version":"0.25.12","resolved":"https://registry.npmjs.org/esbuild/-/esbuild-0.25.12.tgz","integrity":"sha512-bbPBYYrtZbkt6Os6FiTLCTFxvq4tt3JKall1vRwshA3fdVztsLAatFaZobhkBC8/BrPetoa0oksYoKXoG4ryJg==","dev":True,"hasInstallScript":True,"license":"MIT","bin":{"esbuild":"bin/esbuild"},"engines":{"node":">=18"},"optionalDependencies":{"@esbuild/aix-ppc64":"0.25.12","@esbuild/android-arm":"0.25.12","@esbuild/android-arm64":"0.25.12","@esbuild/android-x64":"0.25.12","@esbuild/darwin-arm64":"0.25.12","@esbuild/darwin-x64":"0.25.12","@esbuild/freebsd-arm64":"0.25.12","@esbuild/freebsd-x64":"0.25.12","@esbuild/linux-arm":"0.25.12","@esbuild/linux-arm64":"0.25.12","@esbuild/linux-ia32":"0.25.12","@esbuild/linux-loong64":"0.25.12","@esbuild/linux-mips64el":"0.25.12","@esbuild/linux-ppc64":"0.25.12","@esbuild/linux-riscv64":"0.25.12","@esbuild/linux-s390x":"0.25.12","@esbuild/linux-x64":"0.25.12","@esbuild/netbsd-arm64":"0.25.12","@esbuild/netbsd-x64":"0.25.12","@esbuild/openbsd-arm64":"0.25.12","@esbuild/openbsd-x64":"0.25.12","@esbuild/openharmony-arm64":"0.25.12","@esbuild/sunos-x64":"0.25.12","@esbuild/win32-arm64":"0.25.12","@esbuild/win32-ia32":"0.25.12","@esbuild/win32-x64":"0.25.12"}},
    "node_modules/fdir": {"version":"6.5.0","resolved":"https://registry.npmjs.org/fdir/-/fdir-6.5.0.tgz","integrity":"sha512-tIbYtZbucOs0BRGqPJkshJUYdL+SDH7dVM8gjy+ERp3WAUjLEFJE+02kanyHtwjWOnwrKYBiwAmM0p4kLJAnXg==","dev":True,"license":"MIT","engines":{"node":">=12.0.0"},"peerDependencies":{"picomatch":"^3 || ^4"},"peerDependenciesMeta":{"picomatch":{"optional":True}}},
    "node_modules/fsevents": {"version":"2.3.3","resolved":"https://registry.npmjs.org/fsevents/-/fsevents-2.3.3.tgz","integrity":"sha512-5xoDfX+fL7faATnagmWPpbFtwh/R77WmMMqqHGS65C3vvB0YHrgF+B1YmZ3441tMj5n63k0212XNoJwzlhffQw==","dev":True,"hasInstallScript":True,"license":"MIT","optional":True,"os":["darwin"],"engines":{"node":"^8.16.0 || ^10.6.0 || >=11.0.0"}},
    "node_modules/nanoid": {"version":"3.3.19","resolved":"https://registry.npmjs.org/nanoid/-/nanoid-3.3.19.tgz","integrity":"sha512-Y2tUNy4ouw6tq5oDSKeQYGOyhkUBhNOcGV/02KC+6kd9eDGqdZd++mjMiIDilrBYvjEnCYvVtsuHCuP+okSfug==","dev":True,"funding":[{"type":"github","url":"https://github.com/sponsors/ai"}],"license":"MIT","bin":{"nanoid":"bin/nanoid.cjs"},"engines":{"node":"^10 || ^12 || ^13.7 || ^14 || >=15.0.1"}},
    "node_modules/picocolors": {"version":"1.1.1","resolved":"https://registry.npmjs.org/picocolors/-/picocolors-1.1.1.tgz","integrity":"sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA==","dev":True,"license":"ISC"},
    "node_modules/picomatch": {"version":"4.0.7","resolved":"https://registry.npmjs.org/picomatch/-/picomatch-4.0.7.tgz","integrity":"sha512-qcJu88Q2IWqJsDD529JKMdwGm/dvInW4HvQnRwiH9JtihJvzGOscDtHE3x1pBKeUOTysQ8kVmLnJ2kJu7yhcGA==","dev":True,"license":"MIT","engines":{"node":">=12"},"funding":{"url":"https://github.com/sponsors/jonschlinkert"}},
    "node_modules/postcss": {"version":"8.5.28","resolved":"https://registry.npmjs.org/postcss/-/postcss-8.5.28.tgz","integrity":"sha512-RRuzqDtt5Y9h3quz5hWhK+TPnsmVs6WwSU6LkJMeY4HstUEDuYTG8UJSdawMRzmzAtV+KEoG8N3Qg2qLy5vM/A==","dev":True,"funding":[{"type":"opencollective","url":"https://opencollective.com/postcss/"},{"type":"tidelift","url":"https://tidelift.com/funding/github/npm/postcss"},{"type":"github","url":"https://github.com/sponsors/ai"}],"license":"MIT","dependencies":{"nanoid":"^3.3.18","picocolors":"^1.1.1","source-map-js":"^1.2.1"},"engines":{"node":"^10 || ^12 || >=14"}},
    "node_modules/rollup": {"version":"4.63.5","resolved":"https://registry.npmjs.org/rollup/-/rollup-4.63.5.tgz","integrity":"sha512-KRWwmNLlPw5M7HcdYfm15oBv9n9LPtjzpzCIxS/phwqvPyxHSoKX6Y2YU3pxSPfy0CLquVgsx/j/hBi6OvH1Nw==","dev":True,"license":"MIT","dependencies":{"@types/estree":"1.0.9"},"bin":{"rollup":"dist/bin/rollup"},"engines":{"node":">=18.0.0","npm":">=8.0.0"},"optionalDependencies":{"@napi-rs/lzma-linux-x64-gnu":"1.5.1","@rollup/rollup-android-arm-eabi":"4.63.5","@rollup/rollup-android-arm64":"4.63.5","@rollup/rollup-darwin-arm64":"4.63.5","@rollup/rollup-darwin-x64":"4.63.5","@rollup/rollup-freebsd-arm64":"4.63.5","@rollup/rollup-freebsd-x64":"4.63.5","@rollup/rollup-linux-arm-gnueabihf":"4.63.5","@rollup/rollup-linux-arm-musleabihf":"4.63.5","@rollup/rollup-linux-arm64-gnu":"4.63.5","@rollup/rollup-linux-arm64-musl":"4.63.5","@rollup/rollup-linux-loong64-gnu":"4.63.5","@rollup/rollup-linux-loong64-musl":"4.63.5","@rollup/rollup-linux-ppc64-gnu":"4.63.5","@rollup/rollup-linux-ppc64-musl":"4.63.5","@rollup/rollup-linux-riscv64-gnu":"4.63.5","@rollup/rollup-linux-riscv64-musl":"4.63.5","@rollup/rollup-linux-s390x-gnu":"4.63.5","@rollup/rollup-linux-x64-gnu":"4.63.5","@rollup/rollup-linux-x64-musl":"4.63.5","@rollup/rollup-openbsd-x64":"4.63.5","@rollup/rollup-openharmony-arm64":"4.63.5","@rollup/rollup-win32-arm64-msvc":"4.63.5","@rollup/rollup-win32-ia32-msvc":"4.63.5","@rollup/rollup-win32-x64-gnu":"4.63.5","@rollup/rollup-win32-x64-msvc":"4.63.5","fsevents":"~2.3.2"}},
    "node_modules/source-map-js": {"version":"1.2.1","resolved":"https://registry.npmjs.org/source-map-js/-/source-map-js-1.2.1.tgz","integrity":"sha512-UXWMKhLOwVKb728IUtQPXxfYU+usdybtUrK/8uGE8CQMvrhOpwvzDBwj0QhSL7MQc7vIsISBG8VQ8+IDQxpfQA==","dev":True,"license":"BSD-3-Clause","engines":{"node":">=0.10.0"}},
    "node_modules/tinyglobby": {"version":"0.2.17","resolved":"https://registry.npmjs.org/tinyglobby/-/tinyglobby-0.2.17.tgz","integrity":"sha512-wXR/dYpcqKmfWpEdZjiKJOwCNFndD0DMnrW/cYjVGttEkBfVgcLFHoNrlj47mjOVic9yyNu65alsgF4NQyTa2g==","dev":True,"license":"MIT","dependencies":{"fdir":"^6.5.0","picomatch":"^4.0.4"},"engines":{"node":">=12.0.0"},"funding":{"url":"https://github.com/sponsors/SuperchupuDev"}},
    "node_modules/vite": {"version":"6.4.3","resolved":"https://registry.npmjs.org/vite/-/vite-6.4.3.tgz","integrity":"sha512-NTKlcQjlAK7MlQoyb6LgaqHc8sso/pVyUJYWMws3jg21uTJw/LddqIFPcPqP6PzpgbIcZyKI85sFE4HBrQDA8A==","dev":True,"license":"MIT","dependencies":{"esbuild":"^0.25.0","fdir":"^6.4.4","picomatch":"^4.0.2","postcss":"^8.5.3","rollup":"^4.34.9","tinyglobby":"^0.2.13"},"bin":{"vite":"bin/vite.js"},"engines":{"node":"^18.0.0 || ^20.0.0 || >=22.0.0"},"funding":{"url":"https://github.com/vitejs/vite?sponsor=1"},"optionalDependencies":{"fsevents":"~2.3.3"},"peerDependencies":{"@types/node":"^18.0.0 || ^20.0.0 || >=22.0.0","jiti":">=1.21.0","less":"*","lightningcss":"^1.21.0","sass":"*","sass-embedded":"*","stylus":"*","sugarss":"*","terser":"^5.16.0","tsx":"^4.8.1","yaml":"^2.4.2"},"peerDependenciesMeta":{"@types/node":{"optional":True},"jiti":{"optional":True},"less":{"optional":True},"lightningcss":{"optional":True},"sass":{"optional":True},"sass-embedded":{"optional":True},"stylus":{"optional":True},"sugarss":{"optional":True},"terser":{"optional":True},"tsx":{"optional":True},"yaml":{"optional":True}}},
}

TINCTURE = {
    "package.json": """{"name": "smoke-tincture", "private": true, "version": "0.0.1", "type": "module",
 "scripts": {"build": "vite build"}, "devDependencies": {"vite": "^6.0.0"}}""",
    "package-lock.json": json.dumps({
        "name": "smoke-tincture", "version": "0.0.1", "lockfileVersion": 3, "requires": True,
        "packages": {
            "": {"name": "smoke-tincture", "version": "0.0.1", "devDependencies": {"vite": "^6.0.0"}},
            **TINCTURE_PACKAGES,
        },
    }),
    "index.html": '<!doctype html><html><body><div id="app"></div>'
    '<script type="module" src="/src/main.js"></script></body></html>\n',
    "src/main.js": 'document.getElementById("app").textContent = "smoke";\n',
}


def cargo_toml(stack):
    """The release's own reagent manifest, printed between markers: eval can print runtime warnings."""
    result = stack.exec(
        f"""{RELEASE_BIN} eval 'IO.puts("<<<" <> Locus.Builder.cargo_toml_for(:reagent) <> ">>>")'""",
        user=RELEASE_USER,
    )
    out = result.stdout
    expect("<<<" in out and ">>>" in out, "the release prints its reagent manifest", result.stdout + result.stderr)
    return out.split("<<<", 1)[1].split(">>>", 1)[0]


def main(image):
    empty = tempfile.mkdtemp(prefix="locus-builds-smoke-")
    stack = Stack("locus-builds-smoke", image, empty)
    try:
        stack.up()
        expect(stack.health.get("version") == VERSION and all(t["available"] for t in stack.health["toolchains"].values()),
               "the service answers the wire's health operation with both toolchains available", stack.health)
        manifest = cargo_toml(stack)

        sources = {"src/lib.rs": LIB_RS, "Cargo.toml": manifest}
        http_status, progress, answer = stack.build_lines(sources, "rust", "reagent")
        expect(http_status == 200 and answer["type"] == "result" and (output_bytes(answer, "component.wasm") or b"").startswith(b"\0asm"),
               "a Rust reagent builds in the image", brief(answer))
        stages = [line.get("stage") for line in progress]
        expect(all(line.get("type") == "progress" and line.get("version") == VERSION for line in progress)
               and stages[:2] == ["preparing", "compiling"] and "output" in stages and "validating" in stages,
               "its answer streams the build's progress before the one terminal line", stages)
        lock = output_file(answer, "Cargo.lock") or ""
        expect('name = "wit-bindgen-rt"' in lock, "the build resolves and returns its Cargo.lock", brief(answer))

        widened = manifest.replace("[dependencies]\n", '[dependencies]\nsmallvec = "1"\n', 1)
        status, answer = stack.build({**sources, "Cargo.toml": widened, "Cargo.lock": lock}, "rust", "reagent")
        expect(status == 422 and answer.get("class") == "failed" and "status" in answer["reason"] and "--locked" in diagnostics(answer),
               "a dependency the lock does not cover is refused", brief(answer))

        status, answer = stack.build({**sources, "Cargo.toml": widened, "Cargo.lock": lock}, "rust", "reagent", resolve=True)
        resolved = output_file(answer, "Cargo.lock") or ""
        expect(status == 200 and 'name = "smallvec"' in resolved, "resolve re-resolves the lock", brief(answer))

        status, answer = stack.build({**sources, "Cargo.toml": widened, "Cargo.lock": resolved}, "rust", "reagent")
        expect(status == 200 and output_file(answer, "Cargo.lock") == resolved, "a locked rebuild keeps its lock", brief(answer))

        broken = {**sources, "src/lib.rs": LIB_RS.replace("input\n", "input +\n")}
        status, answer = stack.build(broken, "rust", "reagent")
        expect(status == 422 and answer.get("class") == "failed" and "error" in diagnostics(answer).lower() and "lib.rs" in diagnostics(answer),
               "a compiler error reports its diagnostics", brief(answer))

        status, answer = stack.build(TINCTURE, "javascript", "tincture")
        expect(status == 200 and output_file(answer, "index.html"), "a tincture builds through npm and Vite", brief(answer))

        expect(stack.pool_processes() == [], "no process of a build uid outlives its build", stack.pool_processes())
        expect(stack.homes() == [], "no build home outlives its build", stack.homes())
        logs = stack.logs()
        expect("quarantined" not in logs and "outlived retirement" not in logs, "every build uid was retired clean", logs)

        test_refusals(stack, sources)
        test_deadline(stack)
    finally:
        stack.down()
        shutil.rmtree(empty, ignore_errors=True)


def test_refusals(stack, sources):
    http_status, _progress, answer = stack.build_lines(sources, "rust", "reagent", version=VERSION + 1)
    expect(http_status == 409 and answer.get("class") == "protocol_mismatch"
           and answer["reason"] == {"builder": VERSION, "client": VERSION + 1},
           "a request at another protocol version is refused naming both ends' versions", answer)

    http_status, _progress, answer = stack.build_lines(sources, "rust", "reagent", key=secrets.token_hex(32))
    expect(http_status == 401 and answer.get("class") == "unauthorized" and answer["reason"] == "bad_mac",
           "a request signed with another key is refused as unauthorized", answer)

    # What the wire replaced: the bearer-token POST /build and GET /health.
    for method, path in (("POST", "/build"), ("GET", "/health")):
        request = urllib.request.Request(stack.base + path, data=b"{}" if method == "POST" else None, method=method,
                                         headers={"authorization": f"Bearer {stack.key}"})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                status, line = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, line = error.code, error.read()
        expect(status == 400 and json.loads(line).get("class") == "malformed", f"{method} {path} is no operation of the service", line.decode())

    expect(stack.pool_processes() == [] and stack.homes() == [], "nothing was started for a refused request", stack.pool_processes())


def test_deadline(stack):
    stack.up(timeout_ms=15_000)
    overrun = tincture("setsid sh -c \"trap '' TERM; exec sleep 1000\" </dev/null >/dev/null 2>&1 &\nsleep 300\n")
    result = {}
    started = time.monotonic()
    worker = threading.Thread(target=lambda: result.update(answer=stack.build(overrun, "javascript", "tincture")))
    worker.start()

    daemon_seen = False
    while worker.is_alive():
        daemon_seen = daemon_seen or any("sleep 1000" in p["cmd"] for p in stack.pool_processes())
        time.sleep(0.5)
    worker.join()
    elapsed = time.monotonic() - started

    status, answer = result["answer"]
    expect(daemon_seen, "the overrunning build started its daemon under its uid")
    expect(status == 504 and answer.get("class") == "timeout" and answer["reason"] == {"budget_ms": 15_000} and elapsed < 60,
           "a build past its deadline is refused as timed out, naming its budget", {"elapsed": elapsed, "answer": brief(answer)})
    expect(stack.pool_processes() == [], "no process of it survives, its daemon included", stack.pool_processes())
    expect(stack.homes() == [], "its home is gone", stack.homes())


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
