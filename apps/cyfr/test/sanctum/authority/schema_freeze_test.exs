# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.SchemaFreezeTest do
  use ExUnit.Case, async: true

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Authority.Blob.Edge
  alias Sanctum.Authority.Blob.Node
  alias Sanctum.Authority.Transition
  alias Sanctum.Limits
  alias Sanctum.Policy.Ceiling

  # The Phase 1 schema freeze, as a machine gate. Every surface pinned here
  # is frozen: changing any of them is a deliberate spec amendment that must
  # edit this test AND docs/capability_schema_freeze.md in the same diff —
  # never an incidental refactor.

  @golden_path Path.join([__DIR__, "../../support/fixtures/authority/resolved_policy_golden.json"])

  test "Limits fields are locked to the ceiling-clamped set" do
    frozen = [
      :batch_timeout,
      :max_concurrent_tasks,
      :max_memory_bytes,
      :max_request_size,
      :max_response_size,
      :rate_limit,
      :timeout
    ]

    assert Enum.sort(Limits.fields()) == frozen
    assert Enum.sort(Ceiling.clamped_fields()) == frozen
    assert Enum.sort(Map.keys(%Limits{}) -- [:__struct__]) == frozen
  end

  test "the Authority struct is exactly the model §3.6 field list" do
    frozen = [
      :activation,
      :chain,
      :consent_id,
      :cursor,
      :depth,
      :invoke_mode,
      :policy,
      :profile_id,
      :profile_kind,
      :resources,
      :root_budget,
      :source_ref
    ]

    assert Enum.sort(Map.keys(%Authority{}) -- [:__struct__]) == frozen
  end

  test "the transition vocabulary is frozen" do
    assert Transition.guest_functions() == [
             :call,
             :spawn,
             :await,
             :await_all,
             :await_any,
             :poll,
             :cancel,
             :emit
           ]

    assert Transition.target_tags() == [:invoke, :tool, :external_tool, :task, :tasks, :event]
    assert Transition.cursor_tags() == [:bound, :unbound]

    assert Transition.outcome_tags() == [
             :child,
             :child_zero,
             :deny,
             :allow_tool,
             :allow_async,
             :allow_emit,
             :invalid
           ]

    assert map_size(Transition.relation()) == 96
  end

  test "the ZeroAuthority constants and depth cap are frozen" do
    assert Authority.zero_limits() == %Limits{
             timeout: "30s",
             max_memory_bytes: 67_108_864,
             max_request_size: 1_048_576,
             max_response_size: 5_242_880,
             rate_limit: %{requests: 100, window: "1m"},
             max_concurrent_tasks: 1,
             batch_timeout: "30s"
           }

    assert Authority.depth_cap() == 8
  end

  test "the Context plane vocabulary is frozen and defaults external" do
    assert %Sanctum.Context{}.plane == :external
    assert Sanctum.Context.enter_guest(%Sanctum.Context{}).plane == :guest
  end

  test "the golden resolved-policy blob parses to the exact pinned structure" do
    {:ok, blob} = @golden_path |> File.read!() |> Blob.parse()

    limits = fn timeout, tasks ->
      %Limits{
        timeout: timeout,
        max_memory_bytes: 67_108_864,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880,
        rate_limit: %{requests: 100, window: "1m"},
        max_concurrent_tasks: tasks,
        batch_timeout: "5m"
      }
    end

    assert blob == %Blob{
             canonical: "jcs-1",
             nodes: %{
               "formula:local.daily-report" => %Node{
                 limits: limits.("15m", 30),
                 edges: %{
                   "@ingress" => %Edge{},
                   "catalyst:supabase.com.database|source" => %Edge{
                     vault: %{
                       entry_id: "vault-entry-my-supabase",
                       binding_digest: "sha256:bind-my-supabase",
                       projection: %{fields: ["url", "anon_key"], scopes: []}
                     },
                     egress: %{
                       domains: ["prod.supabase.co"],
                       methods: ["GET", "POST"],
                       schemes: ["https"],
                       private_ips: []
                     },
                     storage: %{paths: [], actions: []},
                     tools: [],
                     tool_servers: []
                   },
                   "catalyst:supabase.com.database|dest" => %Edge{
                     vault: %{
                       entry_id: "vault-entry-warehouse",
                       binding_digest: "sha256:bind-warehouse",
                       projection: %{fields: ["url", "service_key"], scopes: []}
                     },
                     egress: %{
                       domains: ["warehouse.supabase.co"],
                       methods: ["GET", "POST"],
                       schemes: ["https"],
                       private_ips: []
                     }
                   }
                 }
               },
               "catalyst:supabase.com.database" => %Node{
                 limits: limits.("30s", 10),
                 edges: %{}
               }
             }
           }
  end

  test "the golden blob roots and dispatches as the model §3.11 worked example" do
    {:ok, blob} = @golden_path |> File.read!() |> Blob.parse()

    {:ok, auth} =
      Authority.root(
        %{
          profile_id: "prof-daily-report",
          consent_id: "consent-rev-2",
          source_ref: "formula:local.daily-report",
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{
            "formula:local.daily-report" => "sha256:act-f",
            "catalyst:supabase.com.database" => "sha256:act-c"
          }
        },
        blob
      )

    source_invoke =
      {:invoke,
       %{
         reference: "catalyst:supabase.com.database",
         need: "source",
         activation_digest: "sha256:act-c",
         declared_needs: ["source", "dest"]
       }}

    {:child, source} = Transition.step(auth, :call, source_invoke)
    assert source.resources.vault.entry_id == "vault-entry-my-supabase"
    assert source.resources.egress.domains == ["prod.supabase.co"]
    assert Authority.limits(source).timeout == "30s"

    dest_invoke =
      {:invoke,
       %{
         reference: "catalyst:supabase.com.database",
         need: "dest",
         activation_digest: "sha256:act-c",
         declared_needs: ["source", "dest"]
       }}

    {:child, dest} = Transition.step(auth, :call, dest_invoke)
    assert dest.resources.vault.entry_id == "vault-entry-warehouse"
    assert dest.resources.egress.domains == ["warehouse.supabase.co"]
  end
end
