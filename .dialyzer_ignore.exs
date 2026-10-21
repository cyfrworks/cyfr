# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Dialyzer warning filters, configured by mix.exs.
# Each entry is {app_relative_file, warning_kind}, or a regex over the raw
# warning text, with the reason the warning is accepted in a comment
# directly above it (apps/cyfr/test/cyfr/dialyzer_ignore_reasons_test.exs
# refuses an entry without one). Remove an entry, with its reason, when its
# last matching warning is fixed; list_unused_filters fails on unused
# entries. Review the reported warning before adding a filter.
[
  # Ecto.Multi.run/3's success typing reaches Erlang's `:sets` through the
  # MapSet calls on the multi's `names`, so Dialyzer expects that field to
  # be the opaque `:sets.set/1`. Ecto.Multi.new/0's struct literal holds the
  # empty map `:sets.new(version: 2)` builds there (MapSet itself types the
  # field as term()), and Dialyzer reports each Ecto.Multi.run/3 on it as a
  # call without the opaque term. The struct and the pipeline are Ecto's
  # public API.
  {"lib/arca/consent_storage.ex", :call_without_opaque},
  # The same Ecto.Multi.new/0 literal handed to Ecto.Multi.run/3, in
  # prepare_transaction/2.
  {"lib/arca/repo.ex", :call_without_opaque},
  # resolve_component/2's `type || component[:component_type] || …` tests
  # for nil two values the specs make binaries (the parsed ref's type and the
  # registry row's component type), so neither nil branch is taken by them.
  {"lib/compendium/component.ex", :guard_fail},
  # Compendium.OCI.Reference's spec makes repository a binary, so the
  # `ref.repository || ""` fallback in do_oci_pull/2 never takes its nil
  # branch by the spec.
  {"lib/compendium/providers/component.ex", :guard_fail},
  # Every result reaching enrich_tincture_media/2 carries a components list,
  # so its pass-through clause for any other shape is covered.
  {"lib/compendium/providers/component.ex", :pattern_match_cov},
  # t() names every provenance; of_status/1 translates an overlay unit state,
  # which yields only :bundled or :user, and its spec states the type.
  {"lib/compendium/provenance.ex", :extra_range},
  # log_token_returning_result/2's four callers each pass {:ok, _} or
  # {:error, _}; its fall-through clause passes on any other shape.
  {"lib/compendium/registry/client.ex", :pattern_match_cov},
  # :inet.gethostname/0's spec answers only {:ok, name}; the "cyfr-host"
  # fallback keeps the device label total.
  {"lib/compendium/registry/credential_store.ex", :pattern_match_cov},
  # :ets.update_counter/4 is specced to return integer() (a list for a list
  # of operations); counting up from 0 by one it answers a positive integer,
  # the type the spec states.
  {"lib/opus/events/sequence.ex", :missing_range},
  # The Finch version locked wraps a transport failure in
  # Finch.TransportError, so the clause for a bare Mint.TransportError no
  # longer matches; the clause after it answers those failures.
  {"lib/sanctum/auth/device_flow.ex", :pattern_match},
  # The edge's spec makes tools a list, so the `edge.tools || []` fallback
  # never takes its nil branch by the spec.
  {"lib/sanctum/consent/shape_diff.ex", :guard_fail},
  # Sanctum.ApiKey.revoke/2 refuses with atoms only today; the clause that
  # passes a readable binary refusal through is the provider convention.
  {"lib/sanctum/providers/key.ex", :guard_fail},
  # session.use's lookups refuse with atoms only today; the clause that
  # passes a readable binary refusal through is the provider convention.
  {"lib/sanctum/providers/session.ex", :guard_fail},
  # `valid_personal_slug?(slug) || {:error, :invalid_slug}` answers the
  # refusal for false; Dialyzer does not narrow false out of the `||`'s
  # other branch, so it sees the `with` fall through on false.
  {"lib/sanctum/sign_in.ex", :missing_range},
  # An opaque-term warning dialyxir cannot classify: its own formatter
  # raises on it (`Dialyxir.WarningHelpers.ordinal/1`) and prints the raw
  # dialyzer text, so a `{file, kind}` filter never sees a kind to match.
  # Matched by regex instead: the opaque Task.ref() a Task carries, passed
  # where Dialyzer reads a plain term.
  # The first entry's kind for mcp_controller.ex: Process.demonitor/2 on the
  # monitor reference a Task carries, an opaque Task.ref().
  ~r{lib/emissary/web/controllers/mcp_controller\.ex:\d+:\d+:.*opaque}
]
