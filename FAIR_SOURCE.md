# CYFR is Fair Source

This document answers common questions about CYFR's mixed-license model.
The authoritative texts are [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt)
and [`LICENSES/FSL-1.1-Apache-2.0.txt`](LICENSES/FSL-1.1-Apache-2.0.txt) — the
latter is the **canonical, unmodified** Functional Source License 1.1
(Apache 2.0 future license). This file is plain-language guidance only; where it
differs from the license texts, the license texts control.

## The boundary

| Where | License | Why |
|-------|---------|-----|
| `apps/cyfr/lib/sanctum/**` and `apps/cyfr/test/sanctum/**` | FSL-1.1-Apache-2.0 | Sanctum — authentication (OIDC/OAuth/API keys), tenancy, policy enforcement, the cipher that encrypts every secret, and audit. It is the security and multi-tenancy spine, threaded through the majority of the control plane, so any hosted offering of CYFR must redistribute it. |
| Everything else (`apps/cyfr/lib/{arca,emissary*,prism*,compendium,cyfr}/`, the tenancy migrations under `apps/cyfr/priv/repo/migrations/`, `apps/{locus,opus}/`, web UIs, docs) | Apache-2.0 | Apache by default; the schema DDL every self-hoster must run is not gated. |

The rule is simply the directory: everything under
`apps/cyfr/lib/sanctum/` and `apps/cyfr/test/sanctum/` is FSL-1.1-Apache-2.0,
and everything else in the repo is Apache-2.0. Elixir files carry an in-band
`SPDX-License-Identifier` header (there is no `REUSE.toml`), and the
[license-lint CI](.github/workflows/license-lint.yml) enforces the boundary
mechanically.

## What's restricted (Competing Use)

The FSL prohibits exactly one thing — a **Competing Use**: making the Software
available to others in a commercial product or service that

1. substitutes for the Software;
2. substitutes for any other product or service CYFR Works Inc. offers using
   the Software; or
3. offers the same or substantially similar functionality as the Software.

In practice: you may not offer "Managed CYFR" / "CYFR-as-a-Service," and you may
not ship a commercial product or service that resells CYFR's functionality or
stands in for it. Everything else is a Permitted Purpose.

## What's allowed (Permitted Purpose)

A Permitted Purpose is any purpose **other than** a Competing Use. The license
calls out specifically:

- **Internal use and access** — running CYFR for yourself or your own
  organization: internal teams, internal automation, internal tooling. Run as
  many instances as you like.
- **Non-commercial education.**
- **Non-commercial research.**
- **Professional services** you provide to a licensee who is using CYFR under
  these terms (e.g. consulting, deployment, customization for that licensee).

You may also copy, modify, create derivative works of, and redistribute the
Software for any Permitted Purpose, provided you keep the license and copyright
notices intact.

## The 2-year conversion to Apache 2.0

The FSL **irrevocably** grants an additional Apache 2.0 license to each version
of an FSL file, effective on the **second anniversary of the date that version
was made available**. The clock is per distributed version: any revision that
was published at least two years ago can be used under Apache 2.0 — concretely,
check out the commit from two years ago and use that snapshot under Apache.

So nothing is locked up forever: every release of the Sanctum subsystem becomes
permissively licensed two years later. CYFR is **Fair Source / source
available** today, with a guaranteed delayed conversion to Apache 2.0 — it is
not "open source" in the present tense.

## Common questions

**Is internal use restricted?** No. Run as many internal instances as you want
for your own organization.

**Can I deploy CYFR for my team / company?** Yes — that's internal use and
access.

**Can I deploy CYFR for my paying customers?** Only if it isn't a Competing
Use. If CYFR (or substantially similar functionality) is effectively what your
customers are paying for, that's restricted. If CYFR is incidental backend
infrastructure inside a larger product that doesn't substitute for or replicate
CYFR, it generally isn't. When in doubt, apply the three-prong Competing Use
test above, or ask us.

**Can I offer "Managed CYFR" as my SaaS?** No — that's a Competing Use.

**Can I contribute to CYFR?** Yes. Contributions to FSL-licensed files are
licensed back under FSL; Apache-licensed files remain Apache.

**Does the FSL "infect" Apache code?** No. FSL is not a copyleft license.
Apache files that call into or use FSL files at runtime do not become FSL.

**Is FSL OSI-approved?** No. FSL is in the "Fair Source" / "source available"
category. The 2-year Apache conversion brings each version into OSI-approved
territory on a delay.

**What about procurement?** Some procurement processes auto-reject non-OSI
licenses. The FSL Permitted Purpose covers internal use explicitly, so the
typical exception ticket is short. See the
[`README.md` License section](README.md) for the standard talking points.

## Precedent

FSL-style "Fair Source" licensing is a category — not just CYFR. Adjacent
precedents include Sentry (FSL), Sourcegraph (FSL), Convex (FSL), HashiCorp
Terraform / Vault (BUSL), Elastic (Elastic License 2.0), MongoDB (SSPL),
MariaDB MaxScale (BUSL). The category exists because traditional open source
licensing left commercial sustainability as a problem; the 2-year change date
gives back what's most valuable about open source — long-term forkability,
auditability, contribution rights — while reserving a short-window commercial
moat against free-riding.

If your organization has existing policy for any of those products, CYFR fits
the same category.
