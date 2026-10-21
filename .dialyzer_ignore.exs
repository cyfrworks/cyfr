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
  # The plug's refusal mapping and its telemetry each end in a clause for a
  # reason outside today's closed set of atoms (a tuple clause and two
  # catch-alls), so a reason added later still answers 500 and is counted
  # instead of crashing the plug.
  {"lib/cyfr_web/plugs/verify_webhook_signature.ex", :pattern_match},
  # The two catch-all clauses the entry above names.
  {"lib/cyfr_web/plugs/verify_webhook_signature.ex", :pattern_match_cov},
  # deadline/1 adds a platform setting typed term(), so Dialyzer types the
  # sum as number(); the settings roster parses both lifetimes as integers.
  {"lib/cyfr_web/sse.ex", :missing_range},
  # The step bench's harness, `Cyfr.Test.StepBench`, is test support: it is
  # compiled only under MIX_ENV=test, the one environment the task runs in.
  {"lib/mix/tasks/cyfr.bench.step.ex", :unknown_function},
  # Wasmex.Components.Store declares no t/0 type; the spec names the store
  # struct the cache compiles with, and Dialyzer reads it as any().
  {"lib/locus/runtime/component_cache.ex", :unknown_type},
  # `Prima.GuestError.render(reason) || "The call failed."` never answers
  # nil; Dialyzer does not narrow nil out of the `||`'s other branch.
  {"lib/locus/runtime/formula_handler.ex", :missing_range},
  # The provider is configured as a module atom; the clause for a value of
  # another kind refuses a misconfiguration instead of crashing the
  # callback.
  {"lib/prism_web/controllers/auth_controller.ex", :pattern_match_cov},
  # Every caller passes all_acknowledged?/2 a list of names; its last
  # clause refuses anything else rather than recording an acceptance.
  {"lib/prism_web/controllers/legal_accept_controller.ex", :pattern_match_cov},
  # h/1 answers the binary Plug.HTML.html_escape/1 makes; the spec states
  # iodata(), which is how callers interpolate it into a page.
  {"lib/cyfr_web/minimal_page.ex", :extra_range},
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
