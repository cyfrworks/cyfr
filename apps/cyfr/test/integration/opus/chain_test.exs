# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
Code.require_file("support/formula_host_helper.exs", __DIR__)

defmodule Opus.ChainTest do
  # Runs under the authority `Cyfr.Execution.Admission` decides (whose own
  # cases are `Cyfr.Execution.AdmissionTest`), against the in-memory consent
  # source and a real published component (math.wasm — a core module that
  # fails at component compile, which is irrelevant: every property
  # asserted here is decided before compilation). What a run entered with
  # is the authority its runner was handed, at its attach or at its
  # admission, read on the suite's wire.
  use ExUnit.Case, async: false

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob
  alias Cyfr.Test.TwoServices
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures
  alias Cyfr.JCS

  @math_wasm_path Path.join(__DIR__, "../../support/test_wasm/math.wasm")
  # Activation digests as the resolver spells them; an assignment carries
  # nothing else.
  @root_act Cyfr.Digest.sha256("root-act")
  @root_activation Cyfr.Digest.sha256("root-activation")

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    test_path = Path.join(System.tmp_dir!(), "opus_chain_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    ctx = %Context{
      user_id: "chain_test_user_#{:rand.uniform(100_000)}",
      athanor_id: Sanctum.TestContext.athanor_id(),
      scope: :athanor,
      permissions: MapSet.new([:execute]),
      authenticated: true
    }

    admin_ctx = Sanctum.TestContext.local()
    wasm_bytes = File.read!(@math_wasm_path)

    {:ok, root_component} =
      Compendium.Registry.publish_bytes(admin_ctx, wasm_bytes, %{
        name: "chain-root",
        version: "0.1.0",
        type: "reagent",
        description: "Chain root test component"
      })

    # Give the target a distinct manifest digest so the call cannot match self-invocation.
    {:ok, target_component} =
      Compendium.Registry.publish_bytes(admin_ctx, wasm_bytes, %{
        name: "chain-target",
        version: "0.1.0",
        type: "reagent",
        description: "Chain target test component",
        manifest:
          Jason.encode!(%{
            "name" => "chain-target",
            "version" => "0.1.0",
            "type" => "reagent",
            "caps" => %{"tools" => ["component.search"]}
          })
      })

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, ctx: ctx, root: root_component, target: target_component}
  end

  @root_node "reagent:local.chain-root"
  @target_node "reagent:local.chain-target"

  # The authority the run `execution_id` was handed.
  defp entered!(execution_id) do
    assert %Authority{} = authority = TwoServices.entered(execution_id)
    authority
  end

  # The children admitted for the formula `parent_id`, as the answers to
  # its admissions crossed the suite's wire, oldest first.
  defp admitted(parent_id) do
    for %{
          callback: :admit_child,
          fields: %{execution_id: ^parent_id},
          answer: %{"ok" => %{"assignment" => token}}
        } <- TwoServices.calls(),
        {:ok, %{execution_id: id}} <- [Cyfr.Assignment.read(token)],
        do: id
  end

  defp limits_map do
    %{
      "timeout" => "1m",
      "max_memory_bytes" => 67_108_864,
      "max_request_size" => 1_048_576,
      "max_response_size" => 5_242_880,
      "rate_limit" => %{"requests" => 100, "window" => "1m"},
      "max_concurrent_tasks" => 5,
      "batch_timeout" => "1m"
    }
  end

  defp blob_json(edges \\ %{}) do
    extra_nodes =
      edges
      |> Map.keys()
      |> Map.new(fn target -> {target, %{"limits" => limits_map(), "edges" => %{}}} end)

    map = %{
      "canonical" => "jcs-1",
      "nodes" =>
        Map.merge(
          %{
            @root_node => %{
              "limits" => limits_map(),
              "edges" => Map.merge(%{"@ingress" => %{}}, edges)
            }
          },
          extra_nodes
        )
    }

    Jason.encode!(map)
  end

  defp profile_summary(overrides \\ %{}) do
    Map.merge(
      %{
        id: "prof-chain",
        kind: :owner,
        source_ref: @root_node,
        label: "default",
        status: :active
      },
      overrides
    )
  end

  defp consent(root_component, overrides \\ %{}) do
    activation = %{@root_node => root_component.release_digest}

    Map.merge(
      %{
        id: "consent-chain",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-chain",
        commit_digest: "sha256:commit-chain",
        resolved_policy: blob_json(),
        activation: activation,
        vault_refs: []
      },
      overrides
    )
  end

  defp seed(ctx, profile, consent) do
    :ok = ConsentFixtures.seed_head!(ctx, profile, consent)
  end

  # A formula's attempt under `auth`, attached by a runner of the worker
  # service's group, and the real import closures the runtime builds for
  # it: the node's limits and the actions its assignment intercepts. The
  # transition inputs its children are stepped with are the attempt's.
  defp fork_imports(ctx, auth, opts \\ []) do
    fixture =
      Opus.Test.FormulaHost.attached!(
        [
          ctx: ctx,
          authority: auth,
          component_ref: "formula:local.chain-fork:0.1.0",
          activation_digest: @root_act
        ] ++ opts
      )

    {imports, tracker} =
      Opus.FormulaHandler.build_formula_imports(fixture.host, Opus.Test.FormulaHost.opts(auth))

    {fixture.host, imports, tracker}
  end

  defp wait_until(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :done
        System.monotonic_time(:millisecond) > deadline -> flunk("condition never held")
        true -> Process.sleep(20)
      end
    end)
    |> Enum.find(&(&1 == :done))
  end

  describe "run_root/5" do
    test "roots an execution under the loaded authority, guest-planed", %{
      ctx: ctx,
      root: root
    } do
      seed(ctx, profile_summary(), consent(root))
      execution_id = "exec_chain_root_#{System.unique_integer([:positive])}"

      _result =
        Cyfr.Execution.run_root(ctx, :default, "#{@root_node}:0.1.0", %{"a" => 1},
          execution_id: execution_id,
          type: :reagent
        )

      authority = entered!(execution_id)
      assert authority.profile_id == "prof-chain"
      assert authority.consent_id == "consent-chain"
      assert authority.cursor == {:bound, @root_node}

      row = Arca.Repo.get(Arca.Execution, execution_id)
      assert row.activation_digest != nil
      assert Jason.decode!(row.activation_graph) == %{@root_node => root.release_digest}
      assert JCS.hash_binary(row.activation_graph) == row.activation_digest
    end
  end

  describe "run_root_edge/5" do
    setup %{ctx: ctx, root: root} do
      blob_with_edge = blob_json(%{@target_node => %{}})

      profile = %{
        id: "prof-route-pub",
        kind: :public,
        source_ref: @root_node,
        label: "public",
        status: :active
      }

      :ok =
        ConsentFixtures.seed_head!(ctx, profile, %{
          id: "consent-route-pub",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :edge_only,
          shape_digest: "sha256:shape-route",
          commit_digest: "sha256:commit-route",
          resolved_policy: blob_with_edge,
          activation: %{@root_node => root.release_digest},
          vault_refs: []
        })

      seed(ctx, profile_summary(), consent(root, %{resolved_policy: blob_with_edge}))
      :ok
    end

    test "the routed execution row is root-shaped with the activation graph", %{ctx: ctx} do
      execution_id = "exec_route_row_#{System.unique_integer([:positive])}"

      _result =
        Cyfr.Execution.run_root_edge(ctx, @root_node, "#{@target_node}:0.1.0", %{},
          route: :protected,
          execution_id: execution_id
        )

      row = Arca.Repo.get(Arca.Execution, execution_id)
      assert row.activation_digest
      assert row.activation_graph
      assert row.parent_execution_id == nil
      # The row is the SSOT for which consent the turn ran under, for a
      # routed root exactly as for `run_root/5`.
      assert row.profile_id == "prof-chain"
    end

    test "a public route stamps the public profile on the row", %{ctx: ctx} do
      execution_id = "exec_route_pub_row_#{System.unique_integer([:positive])}"

      _result =
        Cyfr.Execution.run_root_edge(ctx, @root_node, "#{@target_node}:0.1.0", %{},
          route: :public,
          execution_id: execution_id
        )

      assert %{profile_id: "prof-route-pub"} = Arca.Repo.get(Arca.Execution, execution_id)
    end
  end

  describe "run_child/5" do
    defp authority_with_edges(edges) do
      {:ok, blob} = Blob.parse(Jason.decode!(blob_json(edges)))

      profile = %{
        profile_id: "prof-chain",
        consent_id: "consent-chain",
        source_ref: @root_node,
        kind: :owner,
        invoke_mode: :open_inert,
        activation: %{@root_node => "sha256:act-root"}
      }

      {:ok, auth} =
        Authority.root(profile, blob, ceiling: Sanctum.Policy.Ceiling.platform_ceiling())

      auth
    end

    defp child_opts(ctx, overrides \\ []) do
      Keyword.merge(
        [
          ctx: Context.enter_guest(ctx),
          parent_execution_id: "exec_parent_#{System.unique_integer([:positive])}",
          root_execution_id: "exec_root_ref",
          activation_digest: @root_activation
        ],
        overrides
      )
    end

    defp revoked_vault_entry(ctx) do
      id = Cyfr.UUID7.generate_id("vlt")
      aad = Sanctum.CipherAAD.vault_entry(ctx.athanor_id, id, "")
      {:ok, json} = Sanctum.Vault.Payload.encode_material(%{"api_key" => "sk-gone"}, nil)
      {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

      {:ok, entry} =
        Arca.VaultStorage.put(Sanctum.Context.actor(ctx), %{
          id: id,
          name: "chain-revoked-entry",
          provider_hint: "",
          kind: "api_key",
          field_names: Jason.encode!(["api_key"]),
          sealed_payload: sealed
        })

      {:ok, digest} = Sanctum.VaultReader.binding_digest(entry)
      :ok = Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), entry.id, "revoked")
      {entry, digest}
    end

    test "a bound child executes under the edge's authority with host lineage", %{
      ctx: ctx,
      target: target
    } do
      auth = authority_with_edges(%{@target_node => %{}})
      execution_id = "exec_chain_child_#{System.unique_integer([:positive])}"

      _result =
        Cyfr.Execution.run_child(
          auth,
          "#{@target_node}:0.1.0",
          nil,
          %{"a" => 2},
          child_opts(ctx, execution_id: execution_id)
        )

      authority = entered!(execution_id)
      assert authority.cursor == {:bound, @target_node}
      assert authority.depth == 1
      assert authority.chain == [@root_node, @target_node]
      assert Map.get(target, :release_digest) != nil

      row = Arca.Repo.get(Arca.Execution, execution_id)
      # A child carries its root's activation digest, no graph.
      assert row.activation_digest == @root_activation
      assert row.activation_graph == nil
      assert row.parent_execution_id != nil
    end

    test "an off-graph target runs as a zero child, not the caller's authority", %{ctx: ctx} do
      auth = authority_with_edges(%{})
      execution_id = "exec_chain_zero_#{System.unique_integer([:positive])}"

      _result =
        Cyfr.Execution.run_child(
          auth,
          "#{@target_node}:0.1.0",
          nil,
          %{},
          child_opts(ctx, execution_id: execution_id)
        )

      authority = entered!(execution_id)
      assert authority.cursor == :unbound
      assert authority.profile_id == nil
      assert authority.policy == :none
    end

    test "a bound edge whose target no longer resolves is setup_required", %{ctx: ctx} do
      auth = authority_with_edges(%{"reagent:local.gone" => %{}})

      assert {:error, {:setup_required, payload}} =
               Cyfr.Execution.run_child(
                 auth,
                 "reagent:local.gone:1.0.0",
                 nil,
                 %{},
                 child_opts(ctx)
               )

      assert payload.profile_id == "prof-chain"
      assert payload.node_ref == "reagent:local.gone:1.0.0"
      assert payload.reason == :unresolvable_target
    end

    test "a bound edge naming a revoked vault entry is typed setup_required", %{ctx: ctx} do
      # The consented edge is intact but its credential is gone — the
      # "declared need unmet at run" case. The executor must surface the
      # typed term (so the error envelope and the parent-stream event carry
      # the structural cause), never a flattened prose string.
      {entry, digest} = revoked_vault_entry(ctx)

      # The root pin is checked before the vault: the constructed authority
      # needs its profile row, active at the pinned consent, or the run is
      # refused as consent_moved before the entry is looked at.
      {:ok, _} =
        Arca.ProfileStorage.put(%{
          id: "prof-chain",
          athanor_id: ctx.athanor_id,
          source_ref: @root_node,
          kind: "owner",
          label: "default",
          status: "active",
          head_consent_id: "consent-chain"
        })

      auth =
        authority_with_edges(%{
          @target_node => %{
            "vault" => %{
              "entry_id" => entry.id,
              "binding_digest" => digest,
              "projection" => %{"fields" => ["api_key"]}
            }
          }
        })

      assert {:error, {:setup_required, payload}} =
               Cyfr.Execution.run_child(auth, "#{@target_node}:0.1.0", nil, %{}, child_opts(ctx))

      assert payload.profile_id == "prof-chain"
      assert payload.node_ref == "#{@target_node}:0.1.0"
      assert payload.reason == "vault_entry_revoked"
    end

    test "a consented catalyst with no legacy policy rows executes under its blob", %{
      ctx: ctx
    } do
      # No policy rows exist for this catalyst, and the callee-keyed
      # resolver is gone: a direct run without an authority fails closed,
      # while the authority path executes under the blob — the blob is the
      # policy. Reaching the runtime witness proves it.
      admin_ctx = Sanctum.TestContext.local()
      wasm_bytes = File.read!(@math_wasm_path)

      {:ok, cat} =
        Compendium.Registry.publish_bytes(admin_ctx, wasm_bytes, %{
          name: "chain-cat",
          version: "0.1.0",
          type: "catalyst",
          description: "Chain catalyst test component"
        })

      cat_node = "catalyst:local.chain-cat"

      blob =
        Jason.encode!(%{
          "canonical" => "jcs-1",
          "nodes" => %{
            cat_node => %{
              "limits" => limits_map(),
              "edges" => %{
                "@ingress" => %{
                  "egress" => %{
                    "domains" => ["api.example.com"],
                    "methods" => ["GET"],
                    "schemes" => ["https"]
                  }
                }
              }
            }
          }
        })

      profile = profile_summary(%{id: "prof-cat", source_ref: cat_node})

      consent = %{
        id: "consent-cat",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-cat",
        commit_digest: "sha256:commit-cat",
        resolved_policy: blob,
        activation: %{cat_node => cat.release_digest},
        vault_refs: []
      }

      seed(ctx, profile, consent)

      # Authority-less refusal first: without a consent-rooted authority
      # nothing executes, so the blob below is provably the only policy in
      # play.
      assert {:error, no_authority_error} =
               Cyfr.Execution.Dispatch.run(ctx, "#{cat_node}:0.1.0", %{}, type: :catalyst)

      assert no_authority_error =~ "without an authority is not a thing"

      execution_id = "exec_chain_cat_#{System.unique_integer([:positive])}"

      _result =
        Cyfr.Execution.run_root(ctx, :default, "#{cat_node}:0.1.0", %{},
          type: :catalyst,
          execution_id: execution_id
        )

      assert entered!(execution_id).profile_id == "prof-cat"
    end

    test "the formula closures intercept execution dispatch under an authority", %{ctx: ctx} do
      auth = authority_with_edges(%{@target_node => %{}})

      {host, imports, tracker} = fork_imports(ctx, auth)
      parent_id = host.execution_id

      on_exit(fn ->
        if Process.alive?(tracker), do: Opus.FormulaHandler.cleanup_registry(tracker)
      end)

      %{"cyfr:formula/invoke@0.1.0" => fns} = imports
      {:fn, call_fn} = fns["call"]

      # Guest-forged lineage keys ride the args; they must be discarded.
      request =
        Jason.encode!(%{
          "tool" => "execution",
          "action" => "run",
          "args" => %{
            "reference" => "#{@target_node}:0.1.0",
            "input" => %{"a" => 1},
            "parent_execution_id" => "exec_forged",
            "root_execution_id" => "exec_forged_root"
          }
        })

      response = call_fn.(request)

      assert [child_id] = admitted(parent_id)
      authority = entered!(child_id)
      assert authority.cursor == {:bound, @target_node}
      assert authority.depth == 1

      # The child is admitted for a runner this fixture's attempt presents,
      # which is no process: it is closed failed unstarted, after every
      # property under test was decided.
      assert %{"error" => %{"type" => "dispatch_error"}} = Jason.decode!(response)

      import Ecto.Query

      rows =
        Arca.Repo.all(
          from(e in Arca.Execution, where: e.parent_execution_id in [^parent_id, "exec_forged"])
        )

      assert [row] = rows
      assert row.parent_execution_id == parent_id
      assert row.activation_digest == @root_act
    end

    test "an omitted need is rejected when the closure declares needs", %{ctx: ctx} do
      auth = authority_with_edges(%{@target_node => %{}})

      {_host, imports, tracker} = fork_imports(ctx, auth, declared_needs: ["source"])

      on_exit(fn ->
        if Process.alive?(tracker), do: Opus.FormulaHandler.cleanup_registry(tracker)
      end)

      %{"cyfr:formula/invoke@0.1.0" => %{"call" => {:fn, call_fn}}} = imports

      request =
        Jason.encode!(%{
          "tool" => "execution",
          "action" => "run",
          "args" => %{"reference" => "#{@target_node}:0.1.0", "input" => %{}}
        })

      assert %{"error" => %{"type" => "invalid_request"}} = Jason.decode!(call_fn.(request))
    end

    test "the spawn closure charges the budget and releases it on completion", %{ctx: ctx} do
      auth = authority_with_edges(%{@target_node => %{}})

      {host, imports, tracker} = fork_imports(ctx, auth)

      on_exit(fn ->
        if Process.alive?(tracker), do: Opus.FormulaHandler.cleanup_registry(tracker)
      end)

      %{"cyfr:formula/invoke@0.1.0" => %{"spawn" => {:fn, spawn_fn}}} = imports

      request =
        Jason.encode!(%{
          "tool" => "execution",
          "action" => "run",
          "args" => %{"reference" => "#{@target_node}:0.1.0", "input" => %{}}
        })

      assert %{"task_id" => _} = Jason.decode!(spawn_fn.(request))
      assert [_child_id] = admitted(host.execution_id)
      wait_until(fn -> Sanctum.Authority.budget(auth).in_flight == 0 end)
    end

    test "an in-chain run_stream is admitted spawn-shaped under the edge's authority", %{
      ctx: ctx
    } do
      auth = authority_with_edges(%{@target_node => %{}})

      {host, imports, tracker} = fork_imports(ctx, auth)

      on_exit(fn ->
        if Process.alive?(tracker), do: Opus.FormulaHandler.cleanup_registry(tracker)
      end)

      %{"cyfr:formula/invoke@0.1.0" => %{"call" => {:fn, call_fn}}} = imports

      request =
        Jason.encode!(%{
          "tool" => "execution",
          "action" => "run_stream",
          "args" => %{"reference" => "#{@target_node}:0.1.0", "input" => %{}}
        })

      # The runner this fixture's attempt presents starts nothing, so the
      # stream info a started child is answered with is
      # `Opus.FormulaHandlerRunnerTest`'s; what CYFR decides is here.
      _response = call_fn.(request)

      parent_id = host.execution_id

      assert [%{args: %{"guest_fn" => "spawn"}}] =
               for(
                 %{callback: :admit_child, fields: %{execution_id: ^parent_id}} = call <-
                   TwoServices.calls(),
                 do: call
               )

      assert [child_id] = admitted(parent_id)
      assert entered!(child_id).cursor == {:bound, @target_node}
      wait_until(fn -> Sanctum.Authority.budget(auth).in_flight == 0 end)
    end

    test "an oversized emit is refused by the node's own request limit", %{ctx: ctx} do
      auth = authority_with_edges(%{})

      # The formula's attempt answers its emit under the node's limits.
      {_host, imports, tracker} = fork_imports(ctx, auth)

      on_exit(fn ->
        if Process.alive?(tracker), do: Opus.FormulaHandler.cleanup_registry(tracker)
      end)

      %{"cyfr:formula/invoke@0.1.0" => %{"emit" => {:fn, emit_fn}}} = imports

      big = Jason.encode!(%{"blob" => String.duplicate("x", 2_000_000)})
      assert %{"error" => %{"type" => "resource_limit"}} = Jason.decode!(emit_fn.(big))

      ok = Jason.encode!(%{"note" => "small"})
      assert %{"ok" => true} = Jason.decode!(emit_fn.(ok))

      # A non-object event is refused under an authority.
      assert %{"error" => %{"type" => "invalid_request"}} =
               Jason.decode!(emit_fn.(Jason.encode!(["not", "an", "object"])))
    end
  end

  describe "run_child/5 as a spawn" do
    test "a spawn-shaped child holds the slot for the call and releases it on return", %{ctx: ctx} do
      auth = authority_with_edges(%{@target_node => %{}})
      assert Sanctum.Authority.budget(auth).in_flight == 0

      _result =
        Cyfr.Execution.run_child(
          auth,
          "#{@target_node}:0.1.0",
          nil,
          %{},
          child_opts(ctx, guest_fn: :spawn)
        )

      assert Sanctum.Authority.budget(auth).in_flight == 0
    end

    test "with a charge identity the hold is a row, taken before the run and given back after", %{
      ctx: ctx
    } do
      auth = authority_with_edges(%{@target_node => %{}})

      {:ok, %{attempt: root_attempt}} =
        Arca.Execution.admit(
          %{
            id: "exec_charge_root_#{System.unique_integer([:positive])}",
            reference: "formula:local.root:1.0.0",
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            component_type: "formula"
          },
          reservation: %{budget_id: auth.budget.id, cap: 1}
        )

      charge = %{
        id: "call:t:1:c1:g0",
        attempt: root_attempt.attempt,
        generation: 0,
        holder_execution_id: nil
      }

      _result =
        Cyfr.Execution.run_child(
          auth,
          "#{@target_node}:0.1.0",
          nil,
          %{},
          child_opts(ctx, guest_fn: :spawn, charge: charge)
        )

      assert Sanctum.Authority.budget(auth).in_flight == 0

      assert %{charged: 0} =
               Arca.BudgetReservations.lookup(Sanctum.Context.actor(ctx), auth.budget.id)

      assert {:ok, []} =
               Arca.BudgetReservations.charges(Sanctum.Context.actor(ctx), auth.budget.id)

      # A full reservation refuses the run and gives the slot back.
      :ok =
        Arca.BudgetReservations.charge(
          Sanctum.Context.actor(ctx),
          auth.budget.id,
          %{charge | id: "other"},
          1
        )

      assert {:error, {:invoke_denied, :invoke_budget_exhausted}} =
               Cyfr.Execution.run_child(
                 auth,
                 "#{@target_node}:0.1.0",
                 nil,
                 %{},
                 child_opts(ctx, guest_fn: :spawn, charge: charge)
               )

      assert Sanctum.Authority.budget(auth).in_flight == 0
    end

    test "a hold past its admission window refuses the child before it runs", %{ctx: ctx} do
      import Ecto.Query, only: [from: 2]

      auth = authority_with_edges(%{@target_node => %{}})

      {:ok, %{attempt: root_attempt}} =
        Arca.Execution.admit(
          %{
            id: "exec_hold_root_#{System.unique_integer([:positive])}",
            reference: "formula:local.root:1.0.0",
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            component_type: "formula"
          },
          reservation: %{budget_id: auth.budget.id, cap: 2}
        )

      child_id = Cyfr.UUID7.execution_id()

      charge = %{
        id: "call:t:1:c2:g0",
        attempt: root_attempt.attempt,
        generation: 0,
        holder_execution_id: child_id
      }

      :ok = Arca.BudgetReservations.charge(Sanctum.Context.actor(ctx), auth.budget.id, charge, 1)
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {1, _} =
        from(c in Arca.Schemas.BudgetCharge,
          where: c.athanor_id == ^ctx.athanor_id and c.id == ^charge.id
        )
        |> Arca.Repo.update_all(set: [admit_by: past])

      assert {:error, _} =
               Cyfr.Execution.run_child(
                 auth,
                 "#{@target_node}:0.1.0",
                 nil,
                 %{},
                 child_opts(ctx, guest_fn: :spawn, charge: charge, execution_id: child_id)
               )

      assert Arca.Repo.get(Arca.Execution, child_id) == nil
      assert Sanctum.Authority.budget(auth).in_flight == 0
    end
  end
end
