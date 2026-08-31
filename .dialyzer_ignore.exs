# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The dialyzer ratchet: every finding standing the day the gate was turned
# on, so the job is green now and red on anything new. `.github/workflows/
# dialyzer.yml` runs it; `mix.exs` points at this file.
#
# An entry is {file, warning_kind}, with the file spelled the way dialyzer
# reports it — app-relative, not umbrella-relative. Fixing a file's last
# finding of a kind means DELETING its line; `list_unused_filters: true`
# fails the build on a line that no longer matches, so the record cannot
# drift away from the tree in either direction. Never add a line without
# reading the finding first: this tail is dead defensive clauses and specs
# narrower than their code, and two of them were real bugs.
[
  {"lib/aqua/actions.ex", :pattern_match},
  {"lib/aqua/actions.ex", :pattern_match_cov},
  {"lib/aqua/mcp_helpers.ex", :missing_range},
  {"lib/arca/adapters/s3.ex", :call_without_opaque},
  {"lib/arca/consent_storage.ex", :call_without_opaque},
  {"lib/arca/overlay.ex", :call_without_opaque},
  {"lib/arca/repo/errors.ex", :pattern_match},
  {"lib/arca/usage.ex", :pattern_match},
  {"lib/compendium/component.ex", :guard_fail},
  {"lib/compendium/dependency_resolver.ex", :call_without_opaque},
  {"lib/compendium/mcp/component_tool.ex", :guard_fail},
  {"lib/compendium/mcp/component_tool.ex", :pattern_match_cov},
  {"lib/compendium/oci/client.ex", :pattern_match_cov},
  {"lib/compendium/provenance.ex", :extra_range},
  {"lib/compendium/registry/client.ex", :pattern_match_cov},
  {"lib/compendium/registry/credential_store.ex", :pattern_match_cov},
  {"lib/cyfr/json_formatter.ex", :unknown_type},
  {"lib/cyfr/network.ex", :pattern_match_cov},
  {"lib/cyfr/retention_scheduler.ex", :pattern_match},
  {"lib/cyfr/runtime_config.ex", :missing_range},
  {"lib/emissary/mcp/tools/records_provider.ex", :guard_fail},
  {"lib/emissary/mcp/tools/records_provider.ex", :pattern_match},
  {"lib/emissary/mcp/tools/system_provider.ex", :pattern_match_cov},
  {"lib/emissary_web/controllers/auth_controller.ex", :pattern_match_cov},
  {"lib/emissary_web/plugs/verify_webhook_signature.ex", :pattern_match},
  {"lib/emissary_web/plugs/verify_webhook_signature.ex", :pattern_match_cov},
  {"lib/emissary_web/plugs/webhook_rate_limit.ex", :pattern_match},
  {"lib/emissary_web/sse.ex", :missing_range},
  {"lib/opus.ex", :extra_range},
  {"lib/opus/component_cache.ex", :unknown_type},
  {"lib/opus/cron_mcp.ex", :pattern_match_cov},
  {"lib/opus/execution_event_buffer/sequence.ex", :missing_range},
  {"lib/opus/execution_record.ex", :extra_range},
  {"lib/opus/executor.ex", :pattern_match_cov},
  {"lib/opus/formula_handler.ex", :missing_range},
  {"lib/opus/http_handler.ex", :pattern_match},
  {"lib/opus/http_handler.ex", :pattern_match_cov},
  {"lib/opus/mcp.ex", :guard_fail},
  {"lib/opus/rate_limiter.ex", :missing_range},
  {"lib/opus/runtime.ex", :call},
  {"lib/opus/runtime.ex", :extra_range},
  {"lib/opus/runtime.ex", :pattern_match},
  {"lib/prism_web/controllers/legal_accept_controller.ex", :pattern_match_cov},
  {"lib/prism_web/minimal_page.ex", :extra_range},
  {"lib/sanctum/auth/device_flow.ex", :pattern_match},
  {"lib/sanctum/cidr.ex", :pattern_match_cov},
  {"lib/sanctum/consent/shape_diff.ex", :guard_fail},
  {"lib/sanctum/jcs.ex", :no_return},
  {"lib/sanctum/mcp/key_tool.ex", :guard_fail},
  {"lib/sanctum/mcp/session_tool.ex", :guard_fail},
  {"lib/sanctum/mcp/webhook_tool.ex", :pattern_match},
  {"lib/sanctum/mcp/webhook_tool.ex", :pattern_match_cov},
  {"lib/sanctum/notify.ex", :missing_range},
  {"lib/sanctum/session.ex", :extra_range},
  {"lib/sanctum/sign_in.ex", :missing_range},
  {"lib/sanctum/sign_in.ex", :pattern_match},
  # Six opaque-term warnings dialyxir cannot classify: its own formatter
  # raises on them (`Dialyxir.WarningHelpers.ordinal/1`) and prints the raw
  # dialyzer text, so a `{file, kind}` filter never sees a kind to match.
  # Matched by regex instead. Every one is a struct built in one module and
  # read in another where the reader's spec re-states the struct's shape —
  # noise from the loose `%__MODULE__{}` schema types, not a defect.
  ~r{lib/arca/adapters/s3\.ex:\d+:\d+:.*opaque},
  ~r{lib/compendium/dependency_resolver\.ex:\d+:\d+:.*opaque},
  ~r{lib/emissary_web/controllers/mcp_controller\.ex:\d+:\d+:.*opaque},
  ~r{lib/opus/executor\.ex:\d+:\d+:.*opaque}
]
