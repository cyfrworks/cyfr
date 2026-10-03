# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.SchemaFreezeTest do
  use ExUnit.Case, async: true

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Authority.Blob.Edge
  alias Prima.Authority.Blob.Node
  alias Prima.Authority.Transition
  alias Prima.Limits
  alias Prima.Limits.Ceiling

  # The authority schema freeze, as a machine gate. Every surface pinned
  # here is frozen — the blob shape, the transition relation, the limit and
  # ceiling field sets, and the golden resolved-policy fixture. This test IS
  # the spec: changing any pinned surface is a deliberate amendment made by
  # editing these assertions in the same diff as the change, never an
  # incidental refactor.

  # The blob is a contracts shape (`Prima.Authority.Blob`), so the golden
  # file it is pinned against lives with the contracts and both suites
  # that read it name one copy.
  @golden_path Path.join([
                 __DIR__,
                 "../../../../prima/test/support/fixtures/authority/resolved_policy_golden.json"
               ])

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

  # `budget` names the root-keyed invoke budget by identity (id + cap); the
  # counter behind it is node-local. The struct is plain data end to end.
  test "the Authority struct has exactly the supported fields" do
    frozen = [
      :activation,
      :budget,
      :chain,
      :consent_id,
      :cursor,
      :depth,
      :invoke_mode,
      :policy,
      :profile_id,
      :profile_kind,
      :resources,
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

    egress = fn domain ->
      %{domains: [domain], methods: ["GET", "POST"], schemes: ["https"], private_ips: []}
    end

    destination = fn hosts, extra ->
      struct!(Prima.Destination, [hosts: hosts, scheme: "https"] ++ extra)
    end

    key = fn need, slot ->
      Blob.binding_key(
        "formula:local.daily-report",
        "catalyst:supabase.com.database|" <> need,
        slot
      )
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
                       scope: "athanor",
                       binding_key: key.("source", nil),
                       destination:
                         destination.(["prod.supabase.co"],
                           methods: ["GET", "POST"],
                           paths: ["/rest/v1"]
                         ),
                       attach: %{in: "header", name: "apikey", template: "{value}"},
                       projection: %{fields: ["url", "anon_key"], scopes: []}
                     },
                     egress: egress.("prod.supabase.co"),
                     storage: %{paths: [], actions: []},
                     tools: [],
                     tool_servers: []
                   },
                   "catalyst:supabase.com.database|dest" => %Edge{
                     vault: %{
                       entry_id: "vault-entry-warehouse",
                       binding_digest: "sha256:bind-warehouse",
                       scope: "athanor",
                       binding_key: key.("dest", nil),
                       destination: destination.(["warehouse.supabase.co"], []),
                       attach: nil,
                       projection: %{fields: ["url", "service_key"], scopes: []},
                       named: %{
                         "Archive" => %{
                           entry_id: "vault-entry-archive",
                           binding_digest: "sha256:bind-archive",
                           scope: "instance",
                           binding_key: key.("dest", "Archive"),
                           destination:
                             destination.(["archive.supabase.co"],
                               port: 8443,
                               methods: ["GET"],
                               paths: ["/rest/v1"]
                             ),
                           attach: %{
                             in: "header",
                             name: "Authorization",
                             template: "Bearer {value}"
                           },
                           projection: nil
                         }
                       }
                     },
                     egress: egress.("warehouse.supabase.co")
                   },
                   "catalyst:supabase.com.database|lent" => %Edge{
                     vault: %{
                       entry_id: "vault-entry-lent",
                       binding_digest: "sha256:bind-lent",
                       scope: "athanor",
                       binding_key: key.("lent", nil),
                       destination: destination.(["*.supabase.co"], []),
                       attach: %{in: "query", name: "apikey", template: "{value}"},
                       projection: nil,
                       lender: %{
                         profile_id: "prof-supabase",
                         consent_id: "consent-supabase-3",
                         binding_key: "catalyst:supabase.com.database|@ingress|default"
                       }
                     }
                   },
                   "catalyst:supabase.com.database|public" => %Edge{
                     vault: %{
                       provided: %{
                         destination: destination.(["public.supabase.co"], paths: ["/rest/v1"]),
                         values: %{"anon_key" => "public-anon-key"},
                         attach: %{in: "header", name: "apikey", template: "{value}"}
                       }
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

  test "the golden blob roots and dispatches with the expected authority" do
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
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
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
    refute Map.has_key?(dest.resources.vault, :named)

    # A call naming the edge's second account gets that binding alone; a
    # name the edge lacks is refused.
    {_tag, target} = dest_invoke
    named_invoke = {:invoke, Map.put(target, :connection, "Archive")}
    {:child, archive} = Transition.step(auth, :call, named_invoke)
    assert archive.resources.vault.entry_id == "vault-entry-archive"
    assert archive.resources.vault.scope == "instance"

    assert {:deny, :connection_not_granted} =
             Transition.step(auth, :call, {:invoke, Map.put(target, :connection, "Other")})
  end
end
