# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Ensure the Opus application supervisor is running so GenServers
# (RateLimiter, SharedEngine, CronScheduler, etc.) are alive during tests.
{:ok, _} = Application.ensure_all_started(:opus)

# `:requires_locus` marks the tests that dispatch to the build tool. Locus is
# a sibling app, not a dependency of opus, so an app-scoped run
# (`cd apps/opus && mix test`) does not have its provider on the code path and
# the registry skips it — the dispatch would answer nothing, which is the
# registry behaving correctly, not the handler failing. An umbrella-root run
# (local or CI) has it loaded and runs them. Mirrors `:requires_opus` in the
# cyfr suite.
if not Code.ensure_loaded?(Locus.MCP), do: ExUnit.configure(exclude: [:requires_locus])

# The athanor rows the fixtures name by hand, committed once for the run.
Sanctum.TestContext.seed_athanors!()

ExUnit.start()
