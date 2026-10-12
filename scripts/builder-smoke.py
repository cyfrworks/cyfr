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
    "node_modules/@oxc-project/types": {"version":"0.153.0","resolved":"https://registry.npmjs.org/@oxc-project/types/-/types-0.153.0.tgz","integrity":"sha512-jSNrRIyvPVLL5E1z/tS5zLAprosGz/FuI1PWwEOz59j3E4TTTzSpqKb/RDGqJhhW0QHYISGXxq582wGx6T11Tw==","dev":True,"license":"MIT","funding":{"url":"https://github.com/sponsors/oxc-project"}},
    "node_modules/@rolldown/binding-android-arm-eabi": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-android-arm-eabi/-/binding-android-arm-eabi-1.2.13.tgz","integrity":"sha512-Vu/NICrgdRvUOeaJZIyB2FP63s6fO/4ud5l8dXmxDx9yDyn+mN0y+gsvsVviSli+T361Aqo0h46EuMoobrwawA==","cpu":["arm"],"dev":True,"license":"MIT","optional":True,"os":["android"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-android-arm64": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-android-arm64/-/binding-android-arm64-1.2.13.tgz","integrity":"sha512-6LEoIrGy5vvCd2boNnv2soPSUZj/PRvhp8R/t9KlX+mIZxThIE/ZqxrGXxmuNX0FuvQFvLdZr7S4HrYpYBVhEQ==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["android"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-darwin-arm64": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-darwin-arm64/-/binding-darwin-arm64-1.2.13.tgz","integrity":"sha512-CaJSRzlQ6Q+zkDMVA9OkVxBjVoPRCDEE3v0FSJ9kIQBgRjFApA3Si4ijhbNVUji7ZJt+PfO0e46qy4nPInHUPA==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["darwin"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-darwin-x64": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-darwin-x64/-/binding-darwin-x64-1.2.13.tgz","integrity":"sha512-e4r340I5hxSzJkD3YJBxgzq/rJ3wwxwdLLb2FPt1Zpyem20nrQPT11DDEEkazwxaHumH8wpglsp/Ozgj/wT6mw==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["darwin"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-freebsd-x64": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-freebsd-x64/-/binding-freebsd-x64-1.2.13.tgz","integrity":"sha512-hoBWDZ4/K/mJKVMbsgUd1jfpA2DiOrJ54mpegObU9TBHBBrtX4FLIXJJQRDPZ/2Dn91GvPob+Z2hwKJzf4E5SQ==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["freebsd"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-linux-arm-gnueabihf": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-arm-gnueabihf/-/binding-linux-arm-gnueabihf-1.2.13.tgz","integrity":"sha512-oF9fZu3vTWnTiVAkDFxU9PJLt1nh20K9RRpuHsR7ZnE2L7XookBbDBVLojCVSLGbvtSlxeUNnjAj6DbNsKyzbg==","cpu":["arm"],"dev":True,"license":"MIT","optional":True,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-linux-arm64-gnu": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-arm64-gnu/-/binding-linux-arm64-gnu-1.2.13.tgz","integrity":"sha512-DTpb/+jMiqWMPgphn4ksW1zW+XLJ6dJJ9FMvnIk9I291LhCctMPhMYJrP5t9p6C9qa3KXadDdUEZHBaPh3kNxQ==","cpu":["arm64"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-linux-arm64-musl": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-arm64-musl/-/binding-linux-arm64-musl-1.2.13.tgz","integrity":"sha512-xU+Kvv9N2A3SY35zFh1FWWNjxbadE/BKeqnkXe7vScU4GZsw757BlVmDLITZEq8DPpk6m7uoDYkK7P+x/uU5Ow==","cpu":["arm64"],"dev":True,"libc":["musl"],"license":"MIT","optional":True,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-linux-ppc64-gnu": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-ppc64-gnu/-/binding-linux-ppc64-gnu-1.2.13.tgz","integrity":"sha512-XMk/hnhh25oQ756Lclb1Q11h4ll0xC0Esa5w4Vzp+mAE2S3AGJgeM0SonrIgY8fHhjarb6hcoTuwoFG0VVP2ig==","cpu":["ppc64"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-linux-s390x-gnu": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-s390x-gnu/-/binding-linux-s390x-gnu-1.2.13.tgz","integrity":"sha512-U1BoTHYmlywE2n3HUWjzZ+8EQsKr+OwpxYuDWaubx42tUL8QSL7nOqRz/NVHanibbFP3M1Rxuprz/wNcbMKjqw==","cpu":["s390x"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-linux-x64-gnu": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-x64-gnu/-/binding-linux-x64-gnu-1.2.13.tgz","integrity":"sha512-J4cm80Pc6wEwV5AZ42o62sIQgDk+Y7R2s646jIwuvO+4V46QB58N4vVuMPWCBaNgursXLpmUWJV//WQAkPvHBQ==","cpu":["x64"],"dev":True,"libc":["glibc"],"license":"MIT","optional":True,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-linux-x64-musl": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-x64-musl/-/binding-linux-x64-musl-1.2.13.tgz","integrity":"sha512-W0euZS40U4V6JkmEnVCIX9mcsL6cbXQ4X8c2w+MMOIjFg68TXUW+u3RT+2e1t1pv9mg/EP3pDtK3POXdQ7Rxyw==","cpu":["x64"],"dev":True,"libc":["musl"],"license":"MIT","optional":True,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-openharmony-arm64": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-openharmony-arm64/-/binding-openharmony-arm64-1.2.13.tgz","integrity":"sha512-do/AF/4n9MRshia3a5aXoy8xM2c6mgfT6D7H/dY6my5z+hfCIR4ab7mk4IRj++nsEQpKy39kd0DQnDq+r692tw==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["openharmony"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-win32-arm64-msvc": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-win32-arm64-msvc/-/binding-win32-arm64-msvc-1.2.13.tgz","integrity":"sha512-6FtUf2cJZobutJdxnGYX8z0vtbgqU0b2v8vfBhkXb9wp2MppMFtkunE+IaOntyi01rkIQoPW2GHABtfzsC0BRQ==","cpu":["arm64"],"dev":True,"license":"MIT","optional":True,"os":["win32"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/binding-win32-x64-msvc": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-win32-x64-msvc/-/binding-win32-x64-msvc-1.2.13.tgz","integrity":"sha512-UKhFaZTeTcbKrb3iU82m17jVcPEAoqDkCN5MBqgPyZSwp/cQmib21crTS0DdH7T1B7wZRWEI89YQAOJMet5yhg==","cpu":["x64"],"dev":True,"license":"MIT","optional":True,"os":["win32"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
    "node_modules/@rolldown/pluginutils": {"version":"1.0.1","resolved":"https://registry.npmjs.org/@rolldown/pluginutils/-/pluginutils-1.0.1.tgz","integrity":"sha512-2j9bGt5Jh8hj+vPtgzPtl72j0yRxHAyumoo6TNfAjsLB04UtpSvPbPcDcBMxz7n+9CYB0c1GxQFxYRg2jimqGw==","dev":True,"license":"MIT"},
    "node_modules/detect-libc": {"version":"2.1.2","resolved":"https://registry.npmjs.org/detect-libc/-/detect-libc-2.1.2.tgz","integrity":"sha512-Btj2BOOO83o3WyH59e8MgXsxEQVcarkUOpEYrubB0urwnN10yQ364rsiByU11nZlqWYZm05i/of7io4mzihBtQ==","dev":True,"license":"Apache-2.0","engines":{"node":">=8"}},
    "node_modules/fdir": {"version":"6.5.0","resolved":"https://registry.npmjs.org/fdir/-/fdir-6.5.0.tgz","integrity":"sha512-tIbYtZbucOs0BRGqPJkshJUYdL+SDH7dVM8gjy+ERp3WAUjLEFJE+02kanyHtwjWOnwrKYBiwAmM0p4kLJAnXg==","dev":True,"license":"MIT","engines":{"node":">=12.0.0"},"peerDependencies":{"picomatch":"^3 || ^4"},"peerDependenciesMeta":{"picomatch":{"optional":True}}},
    "node_modules/fsevents": {"version":"2.3.3","resolved":"https://registry.npmjs.org/fsevents/-/fsevents-2.3.3.tgz","integrity":"sha512-5xoDfX+fL7faATnagmWPpbFtwh/R77WmMMqqHGS65C3vvB0YHrgF+B1YmZ3441tMj5n63k0212XNoJwzlhffQw==","dev":True,"hasInstallScript":True,"license":"MIT","optional":True,"os":["darwin"],"engines":{"node":"^8.16.0 || ^10.6.0 || >=11.0.0"}},
    "node_modules/lightningcss": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss/-/lightningcss-1.33.0.tgz","integrity":"sha512-WkUDrojuJs0xkgGf2udWxa3yGBRxPtxUkB79i6aCZLRgc7PM8fZe9TosfPDcvEpQZbuFASnHYmRLBLUbmLOIIA==","dev":True,"license":"MPL-2.0","dependencies":{"detect-libc":"^2.0.3"},"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"},"optionalDependencies":{"lightningcss-android-arm64":"1.33.0","lightningcss-darwin-arm64":"1.33.0","lightningcss-darwin-x64":"1.33.0","lightningcss-freebsd-x64":"1.33.0","lightningcss-linux-arm-gnueabihf":"1.33.0","lightningcss-linux-arm64-gnu":"1.33.0","lightningcss-linux-arm64-musl":"1.33.0","lightningcss-linux-x64-gnu":"1.33.0","lightningcss-linux-x64-musl":"1.33.0","lightningcss-win32-arm64-msvc":"1.33.0","lightningcss-win32-x64-msvc":"1.33.0"}},
    "node_modules/lightningcss-android-arm64": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-android-arm64/-/lightningcss-android-arm64-1.33.0.tgz","integrity":"sha512-gEpRTalKdosp4Bb8qWtc2iOgE5SeIHlpS1up9bFq2wAyYhl1UdTObYiHe98zEM9SQvSoqQZ1IQD0JNpg3Ml5pg==","cpu":["arm64"],"dev":True,"license":"MPL-2.0","optional":True,"os":["android"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
    "node_modules/lightningcss-darwin-arm64": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-darwin-arm64/-/lightningcss-darwin-arm64-1.33.0.tgz","integrity":"sha512-Sciaz8eenNTKn9b3t7+xr0ipTp9YxKQY4npwQ3mrRuL0BAVHBLyZxofhaKBAVtzmtRZ/zTyo0/to4B1uWG/Djg==","cpu":["arm64"],"dev":True,"license":"MPL-2.0","optional":True,"os":["darwin"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
    "node_modules/lightningcss-darwin-x64": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-darwin-x64/-/lightningcss-darwin-x64-1.33.0.tgz","integrity":"sha512-Z5UPAxzrjlWNNyGy6i65cJzzvgJ5D3T6wMvs+gWpY9d7qRhANrxqAp6LhxIgZhWEw18RfJTGcRxjuLIBr+m8XQ==","cpu":["x64"],"dev":True,"license":"MPL-2.0","optional":True,"os":["darwin"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
    "node_modules/lightningcss-freebsd-x64": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-freebsd-x64/-/lightningcss-freebsd-x64-1.33.0.tgz","integrity":"sha512-QQM/Ti/hQajJwCY+RiWuCZ9sdtI/XQk7nDK5vC8kkdwixezOlDgvDx7+RT+QjK6FcFT4MpsuoBnHIo/O3StRRg==","cpu":["x64"],"dev":True,"license":"MPL-2.0","optional":True,"os":["freebsd"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
    "node_modules/lightningcss-linux-arm-gnueabihf": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-linux-arm-gnueabihf/-/lightningcss-linux-arm-gnueabihf-1.33.0.tgz","integrity":"sha512-N7FVBe6iS24MlM6R/4RBTxGhQheZGs7tiQ9U32UtF75NzP5Q7xWPRqLBCKxlRQRk3rY1jCIPLzx7WzOhuUIRLQ==","cpu":["arm"],"dev":True,"license":"MPL-2.0","optional":True,"os":["linux"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
    "node_modules/lightningcss-linux-arm64-gnu": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-linux-arm64-gnu/-/lightningcss-linux-arm64-gnu-1.33.0.tgz","integrity":"sha512-j2v/itmy4HlNxlc6voKXYgBqNi0Ng2LShg4z7GufpEgs05P+2suBVyi9I6YHq5uoVFx9ETin3eCEhLVyXGQnKg==","cpu":["arm64"],"dev":True,"libc":["glibc"],"license":"MPL-2.0","optional":True,"os":["linux"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
    "node_modules/lightningcss-linux-arm64-musl": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-linux-arm64-musl/-/lightningcss-linux-arm64-musl-1.33.0.tgz","integrity":"sha512-yiO5ROMuYQgXbC60yjZU5CYSFZGKXL0HFATXt9mHJn1+zW55oCtMI9NfcVhYLMFDL7gV7oBPon/EmMMGg2OvtQ==","cpu":["arm64"],"dev":True,"libc":["musl"],"license":"MPL-2.0","optional":True,"os":["linux"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
    "node_modules/lightningcss-linux-x64-gnu": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-linux-x64-gnu/-/lightningcss-linux-x64-gnu-1.33.0.tgz","integrity":"sha512-ar+Ju7LmcN0Jo4FpL4hpFybwNG9/3A/Br5KW2n2jyODg3MEZXaDYADdemoNS+BDNfMgKvylJLj4S5tyRActuAg==","cpu":["x64"],"dev":True,"libc":["glibc"],"license":"MPL-2.0","optional":True,"os":["linux"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
    "node_modules/lightningcss-linux-x64-musl": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-linux-x64-musl/-/lightningcss-linux-x64-musl-1.33.0.tgz","integrity":"sha512-RYiYbkokw0trfKqqzfF55lginwEPrD3OJDfTuJzFs1MK6iFnDenaz1fqLLtX4ITG3OktJQXOeTaw1awrBAlZPw==","cpu":["x64"],"dev":True,"libc":["musl"],"license":"MPL-2.0","optional":True,"os":["linux"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
    "node_modules/lightningcss-win32-arm64-msvc": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-win32-arm64-msvc/-/lightningcss-win32-arm64-msvc-1.33.0.tgz","integrity":"sha512-1K+MPfLSFVpphzpdbfkhlWk6wBrTObBzS2T6db10PNOZgR9GoVsAWzwNyuhUYYbTp23j+4RrncfujZ4uAzXvwA==","cpu":["arm64"],"dev":True,"license":"MPL-2.0","optional":True,"os":["win32"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
    "node_modules/lightningcss-win32-x64-msvc": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-win32-x64-msvc/-/lightningcss-win32-x64-msvc-1.33.0.tgz","integrity":"sha512-OlEICDx/Xl0FqSp4bry8zFnCvGpig3Gl4gCquvYwHuqJKEC1+n9NgDniFvqHGmMv1ZkqDJrDqKKSykTDX+ehuA==","cpu":["x64"],"dev":True,"license":"MPL-2.0","optional":True,"os":["win32"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
    "node_modules/nanoid": {"version":"3.3.20","resolved":"https://registry.npmjs.org/nanoid/-/nanoid-3.3.20.tgz","integrity":"sha512-uKdg2G3GNCKQn9byYOpxbGqrT2fGO5KRt5J/8b3pok8rT6qxGWF6hxMyJiEYtAf+FVyYuD9hRaDqX5uPFYJ4ZQ==","dev":True,"funding":[{"type":"github","url":"https://github.com/sponsors/ai"}],"license":"MIT","bin":{"nanoid":"bin/nanoid.cjs"},"engines":{"node":"^10 || ^12 || ^13.7 || ^14 || >=15.0.1"}},
    "node_modules/picocolors": {"version":"1.1.1","resolved":"https://registry.npmjs.org/picocolors/-/picocolors-1.1.1.tgz","integrity":"sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA==","dev":True,"license":"ISC"},
    "node_modules/picomatch": {"version":"4.0.7","resolved":"https://registry.npmjs.org/picomatch/-/picomatch-4.0.7.tgz","integrity":"sha512-qcJu88Q2IWqJsDD529JKMdwGm/dvInW4HvQnRwiH9JtihJvzGOscDtHE3x1pBKeUOTysQ8kVmLnJ2kJu7yhcGA==","dev":True,"license":"MIT","engines":{"node":">=12"},"funding":{"url":"https://github.com/sponsors/jonschlinkert"}},
    "node_modules/postcss": {"version":"8.5.29","resolved":"https://registry.npmjs.org/postcss/-/postcss-8.5.29.tgz","integrity":"sha512-49cGhUbXj8Qenv0iTMxA1cFBzxXoctpC9Ujd77t1WcbJIr6nF/eI7g/8MgxrYldFRuAXvja7xQRwavoW7kgrxQ==","dev":True,"funding":[{"type":"opencollective","url":"https://opencollective.com/postcss/"},{"type":"tidelift","url":"https://tidelift.com/funding/github/npm/postcss"},{"type":"github","url":"https://github.com/sponsors/ai"}],"license":"MIT","dependencies":{"nanoid":"^3.3.19","picocolors":"^1.1.1","source-map-js":"^1.2.2"},"engines":{"node":"^10 || ^12 || >=14"}},
    "node_modules/rolldown": {"version":"1.2.13","resolved":"https://registry.npmjs.org/rolldown/-/rolldown-1.2.13.tgz","integrity":"sha512-/5apOkwWxtACcQtZ5WlrAsKS4JwXVThQPJZ3RqIruRY9UG9M8e0VlXN068xum/JRKA4aIUoJ13ghe/kGCvidiQ==","dev":True,"license":"MIT","dependencies":{"@oxc-project/types":"=0.153.0","@rolldown/pluginutils":"^1.0.0"},"bin":{"rolldown":"bin/cli.mjs"},"engines":{"node":"^20.19.0 || >=22.12.0"},"optionalDependencies":{"@rolldown/binding-android-arm-eabi":"1.2.13","@rolldown/binding-android-arm64":"1.2.13","@rolldown/binding-darwin-arm64":"1.2.13","@rolldown/binding-darwin-x64":"1.2.13","@rolldown/binding-freebsd-x64":"1.2.13","@rolldown/binding-linux-arm-gnueabihf":"1.2.13","@rolldown/binding-linux-arm64-gnu":"1.2.13","@rolldown/binding-linux-arm64-musl":"1.2.13","@rolldown/binding-linux-ppc64-gnu":"1.2.13","@rolldown/binding-linux-s390x-gnu":"1.2.13","@rolldown/binding-linux-x64-gnu":"1.2.13","@rolldown/binding-linux-x64-musl":"1.2.13","@rolldown/binding-openharmony-arm64":"1.2.13","@rolldown/binding-win32-arm64-msvc":"1.2.13","@rolldown/binding-win32-x64-msvc":"1.2.13"}},
    "node_modules/source-map-js": {"version":"1.2.2","resolved":"https://registry.npmjs.org/source-map-js/-/source-map-js-1.2.2.tgz","integrity":"sha512-KGj/8Y43x35aZVDtt+J4mK1hoLGHULMYfSkODJNQjNDC3oW1PqPoxMwo0pLUsWM/UEGzON/NxeHywEfNXNP3Vw==","dev":True,"license":"BSD-3-Clause","engines":{"node":">=0.10.0"}},
    "node_modules/tinyglobby": {"version":"0.2.17","resolved":"https://registry.npmjs.org/tinyglobby/-/tinyglobby-0.2.17.tgz","integrity":"sha512-wXR/dYpcqKmfWpEdZjiKJOwCNFndD0DMnrW/cYjVGttEkBfVgcLFHoNrlj47mjOVic9yyNu65alsgF4NQyTa2g==","dev":True,"license":"MIT","dependencies":{"fdir":"^6.5.0","picomatch":"^4.0.4"},"engines":{"node":">=12.0.0"},"funding":{"url":"https://github.com/sponsors/SuperchupuDev"}},
    "node_modules/vite": {"version":"8.3.4","resolved":"https://registry.npmjs.org/vite/-/vite-8.3.4.tgz","integrity":"sha512-IftLE8phJhdNRIGNEV4JCCvfNScoZQVfcXaN8TQropWGJtOHcu+iAB9pHcuGvmEb/kddw0LBe/jS8ztdC6xdiQ==","dev":True,"license":"MIT","dependencies":{"lightningcss":"^1.33.0","picomatch":"^4.0.7","postcss":"^8.5.29","rolldown":"~1.2.12","tinyglobby":"^0.2.17"},"bin":{"vite":"bin/vite.js"},"engines":{"node":"^20.19.0 || >=22.12.0"},"funding":{"url":"https://github.com/vitejs/vite?sponsor=1"},"optionalDependencies":{"fsevents":"~2.3.3"},"peerDependencies":{"@types/node":"^20.19.0 || >=22.12.0","@vitejs/devtools":"^0.7.1","esbuild":"^0.27.0 || ^0.28.0","jiti":">=1.21.0","less":"^4.0.0","sass":"^1.70.0","sass-embedded":"^1.70.0","stylus":">=0.54.8","sugarss":"^5.0.0","terser":"^5.16.0","tsx":"^4.8.1","yaml":"^2.4.2"},"peerDependenciesMeta":{"@types/node":{"optional":True},"@vitejs/devtools":{"optional":True},"esbuild":{"optional":True},"jiti":{"optional":True},"less":{"optional":True},"sass":{"optional":True},"sass-embedded":{"optional":True},"stylus":{"optional":True},"sugarss":{"optional":True},"terser":{"optional":True},"tsx":{"optional":True},"yaml":{"optional":True}}},
}

TINCTURE = {
    "package.json": """{"name": "smoke-tincture", "private": true, "version": "0.0.1", "type": "module",
 "scripts": {"build": "vite build"}, "devDependencies": {"vite": "^8.3.4"}}""",
    "package-lock.json": json.dumps({
        "name": "smoke-tincture", "version": "0.0.1", "lockfileVersion": 3, "requires": True,
        "packages": {
            "": {"name": "smoke-tincture", "version": "0.0.1", "devDependencies": {"vite": "^8.3.4"}},
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
