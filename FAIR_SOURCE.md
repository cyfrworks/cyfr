# CYFR is Fair Source

This document answers common questions about CYFR's dual-license model.
The authoritative texts are [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt)
and [`LICENSES/FSL-1.1-Apache-2.0.txt`](LICENSES/FSL-1.1-Apache-2.0.txt);
this file is plain-language guidance only.

## The boundary

| Where | License | Why |
|-------|---------|-----|
| `apps/cyfr/lib/sanctum/**` and `apps/cyfr/test/sanctum/**` | FSL-1.1-Apache-2.0 | Auth / policy / audit / tenancy — the product moat |
| The tenancy migrations under `apps/cyfr/priv/repo/migrations/` | FSL-1.1-Apache-2.0 | Schemas backing Sanctum's tenancy model |
| Everything else (`apps/cyfr/lib/{arca,emissary*,prism*,compendium,cyfr}/`, `apps/{locus,opus}/`, web UIs, docs) | Apache-2.0 | Apache by default |

License determination is **per-file** via the in-band
`SPDX-License-Identifier` header on line 1 of each `.ex`/`.exs` source
file (including tests and migrations — there is no `REUSE.toml`). The
[license-lint CI](.github/workflows/license-lint.yml) enforces the
boundary mechanically over both `.ex` and `.exs`.

## What's allowed (Permitted Purpose)

The FSL allows you to use, copy, modify, create derivative works,
publish, and distribute the Software for **any Permitted Purpose**.
Specifically:

- **Self-hosting for your own use** — internal team, internal SaaS,
  internal automation. Unrestricted.
- **Self-hosting as a service offered to your own customers**, where
  CYFR is part of the platform you sell (not the product). Permitted.
- **Evaluation, research, education**. Permitted.
- **Consulting / professional services** that don't embed CYFR as a
  hosted service of your own. Permitted.
- **Forking the source and shipping a modified binary internally**.
  Permitted.
- **Redistributing the source** under FSL terms. Permitted.

## What's restricted (Competing Use)

The one prohibited use is a **Competing Use**: making CYFR (or
substantially the same product) available to third parties as a hosted
or managed service that competes with products or services offered by
CYFR Works Inc.

In practice this means you cannot rebrand and resell "managed CYFR" or
"CYFR-as-a-Service" to the open market. Internal use, customer-embedded
use, and consulting around CYFR remain unrestricted.

## The 2-year change date

Each FSL-licensed file becomes additionally available under **Apache
2.0** two years after the date CYFR Works Inc. first distributed that
specific file under this license. After the Change Date, recipients can
use the file under FSL *or* Apache 2.0 at their option.

This means CYFR is **Open Source on a 2-year delay**. Every commit
becomes plain Apache 2.0 eventually; the FSL window protects active
commercial momentum without locking content up forever.

## Common questions

**Is internal use restricted?** No. Run as many internal instances as
you want for your own organization or your own customers.

**Can I deploy CYFR for my team / company?** Yes.

**Can I deploy CYFR for my paying customers as part of my platform?**
Yes, as long as CYFR isn't the product they're paying for.

**Can I offer "Managed CYFR" as my SaaS?** No — that's a Competing Use.

**Can I contribute to CYFR?** Yes. Contributions to FSL-licensed files
are licensed back under FSL. Apache-licensed files remain Apache.

**Does the FSL "infect" Apache code?** No. FSL is not a copyleft
license. Apache files that link to or use FSL files at runtime do not
themselves become FSL.

**Is FSL OSI-approved?** No. FSL is in the "Fair Source" / "Source
Available" category. The 2-year Apache conversion brings each file into
OSI-approved territory on a rolling basis.

**What about procurement?** Some procurement processes auto-reject
non-OSI licenses. The FSL Permitted Purpose covers internal use
explicitly, so the typical exception ticket is short. See the
[`README.md` License section](README.md) for the standard talking
points.

## Precedent

FSL-style "Fair Source" licensing is a category — not just CYFR.
Adjacent precedents include Sentry (FSL), Sourcegraph (FSL),
HashiCorp Terraform / Vault (BUSL), Convex (FSL), Elastic (Elastic
License 2.0), MongoDB (SSPL), MariaDB MaxScale (BUSL). The category
exists because traditional Open Source licensing left commercial
sustainability as a problem; the 2-year Change Date gives back exactly
what's most valuable about Open Source (long-term forkability,
auditability, contribution rights) while reserving the short-window
commercial moat.

If your organization has existing policy for any of those products,
CYFR fits the same category.
