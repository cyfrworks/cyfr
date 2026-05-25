# Contributing to CYFR

Thanks for your interest in improving CYFR. Issues and pull requests are
welcome.

## Licensing of contributions (inbound = outbound)

CYFR uses **mixed per-file licensing** (see [`LICENSE`](LICENSE) and
[`FAIR_SOURCE.md`](FAIR_SOURCE.md)). Contributions are accepted under the
license of the **file being changed**:

- Files under `apps/cyfr/lib/sanctum/**` and `apps/cyfr/test/sanctum/**` are
  **FSL-1.1-Apache-2.0**. Contributions to those files are made under
  FSL-1.1-Apache-2.0.
- Every other file is **Apache-2.0**. Contributions to those files are made
  under Apache-2.0.

By submitting a contribution, you agree to license it under the license that
already applies to the file(s) you change. There is no separate CLA and no
sign-off requirement.

## New files

Add the SPDX header on the first line that matches the directory the file lives
in, following the existing convention:

```
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
```

(use `FSL-1.1-Apache-2.0` only for files inside the two Sanctum directories).

The `license-lint` workflow enforces this boundary on every pull request — a
missing or wrong header fails CI.

## Before opening a PR

- Keep changes focused and match the surrounding code style.
- Run the test suite for the apps you touched (`mix test`).
- Don't describe the product as "open source" in user-facing copy — it is
  "Fair Source" / "source available" (see [`FAIR_SOURCE.md`](FAIR_SOURCE.md)).
