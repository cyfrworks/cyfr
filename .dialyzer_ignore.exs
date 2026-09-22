# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Dialyzer warning filters, configured by mix.exs.
# Each entry is {app_relative_file, warning_kind}. Remove an entry when its
# last matching warning is fixed; list_unused_filters fails on unused entries.
# Review the reported warning before adding a filter.
[
  {"lib/arca/adapters/s3.ex", :call_without_opaque},
  {"lib/arca/consent_storage.ex", :call_without_opaque},
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
  {"lib/cyfr/execution/events/sequence.ex", :missing_range},
  {"lib/cyfr/json_formatter.ex", :unknown_type},
  {"lib/cyfr/retention_scheduler.ex", :pattern_match},
  {"lib/emissary/mcp/tools/records_provider.ex", :guard_fail},
  {"lib/emissary/mcp/tools/records_provider.ex", :pattern_match},
  {"lib/emissary/mcp/tools/system_provider.ex", :pattern_match_cov},
  {"lib/emissary_web/controllers/auth_controller.ex", :pattern_match_cov},
  {"lib/emissary_web/plugs/verify_webhook_signature.ex", :pattern_match},
  {"lib/emissary_web/plugs/verify_webhook_signature.ex", :pattern_match_cov},
  {"lib/emissary_web/plugs/webhook_rate_limit.ex", :pattern_match},
  {"lib/emissary_web/sse.ex", :missing_range},
  # The step bench's harness, `Cyfr.Test.StepBench`, is test support: it is
  # compiled only under MIX_ENV=test, the one environment the task runs in.
  {"lib/mix/tasks/cyfr.bench.step.ex", :unknown_function},
  {"lib/opus/component_cache.ex", :unknown_type},
  {"lib/opus/formula_handler.ex", :missing_range},
  {"lib/opus/http_handler.ex", :pattern_match},
  {"lib/opus/http_handler.ex", :pattern_match_cov},
  {"lib/opus/runtime.ex", :call},
  {"lib/opus/runtime.ex", :extra_range},
  {"lib/opus/runtime.ex", :pattern_match},
  {"lib/prism_web/controllers/legal_accept_controller.ex", :pattern_match_cov},
  {"lib/prism_web/minimal_page.ex", :extra_range},
  {"lib/sanctum/auth/device_flow.ex", :pattern_match},
  {"lib/cyfr/cidr.ex", :pattern_match_cov},
  {"lib/sanctum/consent/shape_diff.ex", :guard_fail},
  {"lib/cyfr/jcs.ex", :no_return},
  {"lib/sanctum/mcp/key_tool.ex", :guard_fail},
  {"lib/sanctum/mcp/session_tool.ex", :guard_fail},
  {"lib/sanctum/mcp/webhook_tool.ex", :pattern_match},
  {"lib/sanctum/mcp/webhook_tool.ex", :pattern_match_cov},
  {"lib/sanctum/session.ex", :extra_range},
  {"lib/sanctum/sign_in.ex", :missing_range},
  # Three opaque-term warnings dialyxir cannot classify: its own formatter
  # raises on them (`Dialyxir.WarningHelpers.ordinal/1`) and prints the raw
  # dialyzer text, so a `{file, kind}` filter never sees a kind to match.
  # Matched by regex instead. Every one is a struct built in one module and
  # read in another where the reader's spec re-states the struct's shape —
  # noise from the loose `%__MODULE__{}` schema types, not a defect.
  ~r{lib/arca/adapters/s3\.ex:\d+:\d+:.*opaque},
  ~r{lib/compendium/dependency_resolver\.ex:\d+:\d+:.*opaque},
  ~r{lib/emissary_web/controllers/mcp_controller\.ex:\d+:\d+:.*opaque},
  # `Sanctum.Provisioning.held/3` answers whatever the closure it holds the
  # claim for answers, and the seed sync's closure answers `:ok`. Dialyzer
  # types a private function once, over every caller, so it reads that `:ok`
  # into the two entry points whose closures cannot answer it. Matched by
  # function, so any other missing range in the file still reports.
]
