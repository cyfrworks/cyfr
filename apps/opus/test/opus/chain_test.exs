# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.ChainTest do
  # run_root / run_child are dark: no production ingress calls them yet.
  # These tests drive the vertical against the in-memory consent source and
  # a real published component (math.wasm — a core module that fails at
  # component compile, which is irrelevant: every property asserted here is
  # decided before compilation).
  use ExUnit.Case, async: false

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Consent.Source
  alias Sanctum.Context
  alias Sanctum.JCS

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @telemetry_event [:opus, :runtime, :authority_entered]

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    start_supervised!(Source.Memory)

    test_path = Path.join(System.tmp_dir!(), "opus_chain_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    ctx = %Context{
      user_id: "chain_test_user_#{:rand.uniform(100_000)}",
      org_id: "local",
      project_id: "default",
      scope: :project,
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

    {:ok, target_component} =
      Compendium.Registry.publish_bytes(admin_ctx, wasm_bytes, %{
        name: "chain-target",
        version: "0.1.0",
        type: "reagent",
        description: "Chain target test component"
      })

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, root: root_component, target: target_component}
  end

  @root_node "reagent:local.chain-root"
  @target_node "reagent:local.chain-target"

  defp attach_witness do
    handler_id = "chain-witness-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:authority_entered, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
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
    :ok = Source.Memory.put_profile(ctx, profile)
    :ok = Source.Memory.put_head_consent(ctx, profile.id, consent)
  end

  describe "run_root/5" do
    test "roots an execution under the loaded authority, guest-planed", %{
      ctx: ctx,
      root: root
    } do
      attach_witness()
      seed(ctx, profile_summary(), consent(root))
      execution_id = "exec_chain_root_#{System.unique_integer([:positive])}"

      _result =
        Opus.run_root(ctx, nil, "#{@root_node}:0.1.0", %{"a" => 1},
          execution_id: execution_id,
          type: :reagent
        )

      assert_receive {:authority_entered, metadata}, 30_000
      assert %Authority{} = metadata.authority
      assert metadata.authority.profile_id == "prof-chain"
      assert metadata.authority.consent_id == "consent-chain"
      assert metadata.authority.cursor == {:bound, @root_node}
      # The context crossing into guest closures can never again authorize
      # an external-plane call.
      assert metadata.plane == :guest

      row = Arca.Repo.get(Arca.Execution, execution_id)
      assert row.activation_digest != nil
      assert Jason.decode!(row.activation_graph) == %{@root_node => root.release_digest}
      assert JCS.hash_binary(row.activation_graph) == row.activation_digest
    end

    test "no profile refuses instead of guessing", %{ctx: ctx} do
      assert {:error, :no_profile} =
               Opus.run_root(ctx, nil, "#{@root_node}:0.1.0", %{}, type: :reagent)
    end

    test "two active owner profiles are ambiguous without a selector", %{ctx: ctx, root: root} do
      seed(ctx, profile_summary(), consent(root))
      seed(ctx, profile_summary(%{id: "prof-chain-2", label: "work"}), consent(root))

      assert {:error, {:ambiguous, ids}} =
               Opus.run_root(ctx, nil, "#{@root_node}:0.1.0", %{}, type: :reagent)

      assert Enum.sort(ids) == ["prof-chain", "prof-chain-2"]

      # An explicit selector resolves it.
      attach_witness()

      _result =
        Opus.run_root(ctx, "work", "#{@root_node}:0.1.0", %{},
          type: :reagent,
          execution_id: "exec_chain_sel_#{System.unique_integer([:positive])}"
        )

      assert_receive {:authority_entered, metadata}, 30_000
      assert metadata.authority.profile_id == "prof-chain-2"
    end

    test "consent drift refuses with consent_required", %{ctx: ctx, root: root} do
      drifted = consent(root, %{activation: %{@root_node => "sha256:stale-grant"}})
      seed(ctx, profile_summary(), drifted)

      assert {:error, {:consent_required, payload}} =
               Opus.run_root(ctx, nil, "#{@root_node}:0.1.0", %{}, type: :reagent)

      assert payload.profile_id == "prof-chain"
      assert payload.current_revision == 1
    end

    test "a public route selects the public profile even for an authenticated caller", %{
      ctx: ctx,
      root: root
    } do
      attach_witness()
      seed(ctx, profile_summary(), consent(root))

      seed(
        ctx,
        profile_summary(%{id: "prof-chain-pub", kind: :public, label: "public"}),
        consent(root, %{id: "consent-chain-pub", invoke_mode: :edge_only})
      )

      assert ctx.authenticated

      _result =
        Opus.run_root(ctx, nil, "#{@root_node}:0.1.0", %{},
          type: :reagent,
          route: :public,
          execution_id: "exec_chain_pub_#{System.unique_integer([:positive])}"
        )

      assert_receive {:authority_entered, metadata}, 30_000
      assert metadata.authority.profile_id == "prof-chain-pub"
      assert metadata.authority.profile_kind == :public
      assert metadata.authority.invoke_mode == :edge_only
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

      {:ok, auth} = Authority.root(profile, blob)
      auth
    end

    defp child_opts(ctx, overrides \\ []) do
      Keyword.merge(
        [
          ctx: Context.enter_guest(ctx),
          parent_execution_id: "exec_parent_#{System.unique_integer([:positive])}",
          root_execution_id: "exec_root_ref",
          activation_digest: "sha256:root-activation"
        ],
        overrides
      )
    end

    test "a bound child executes under the edge's authority with host lineage", %{
      ctx: ctx,
      target: target
    } do
      attach_witness()
      auth = authority_with_edges(%{@target_node => %{}})
      execution_id = "exec_chain_child_#{System.unique_integer([:positive])}"

      _result =
        Opus.run_child(
          auth,
          "#{@target_node}:0.1.0",
          nil,
          %{"a" => 2},
          child_opts(ctx, execution_id: execution_id)
        )

      assert_receive {:authority_entered, metadata}, 30_000
      assert metadata.authority.cursor == {:bound, @target_node}
      assert metadata.authority.depth == 1
      assert metadata.authority.chain == [@root_node, @target_node]
      assert metadata.plane == :guest
      assert Map.get(target, :release_digest) != nil

      row = Arca.Repo.get(Arca.Execution, execution_id)
      # A child carries its root's activation digest, no graph.
      assert row.activation_digest == "sha256:root-activation"
      assert row.activation_graph == nil
      assert row.parent_execution_id != nil
    end

    test "an off-graph target runs as a zero child, not the caller's authority", %{ctx: ctx} do
      attach_witness()
      auth = authority_with_edges(%{})
      execution_id = "exec_chain_zero_#{System.unique_integer([:positive])}"

      _result =
        Opus.run_child(
          auth,
          "#{@target_node}:0.1.0",
          nil,
          %{},
          child_opts(ctx, execution_id: execution_id)
        )

      assert_receive {:authority_entered, metadata}, 30_000
      assert metadata.authority.cursor == :unbound
      assert metadata.authority.profile_id == nil
      assert metadata.authority.policy == :none
    end

    test "an edge_only authority denies an edge-miss instead of running inert", %{ctx: ctx} do
      {:ok, blob} = Blob.parse(Jason.decode!(blob_json()))

      profile = %{
        profile_id: "prof-pub",
        consent_id: "consent-pub",
        source_ref: @root_node,
        kind: :public,
        invoke_mode: :edge_only,
        activation: %{@root_node => "sha256:act-root"}
      }

      {:ok, auth} = Authority.root(profile, blob)

      assert {:error, {:invoke_denied, :edge_only}} =
               Opus.run_child(auth, "#{@target_node}:0.1.0", nil, %{}, child_opts(ctx))
    end

    test "a bound edge whose target no longer resolves is setup_required", %{ctx: ctx} do
      auth = authority_with_edges(%{"reagent:local.gone" => %{}})

      assert {:error, {:setup_required, payload}} =
               Opus.run_child(auth, "reagent:local.gone:1.0.0", nil, %{}, child_opts(ctx))

      assert payload.profile_id == "prof-chain"
      assert payload.node_ref == "reagent:local.gone:1.0.0"
      assert payload.reason == :unresolvable_target
    end

    test "a need containing the edge separator is rejected before edge lookup", %{ctx: ctx} do
      auth = authority_with_edges(%{@target_node => %{}})

      assert {:error, {:invalid_need, "a|b"}} =
               Opus.run_child(auth, "#{@target_node}:0.1.0", "a|b", %{}, child_opts(ctx))
    end

    test "a spawn charges the root budget and a denied spawn does not", %{ctx: ctx} do
      auth = authority_with_edges(%{@target_node => %{}})
      assert Authority.budget(auth).in_flight == 0

      {:ok, decision} =
        Opus.Chain.step_invoke(
          auth,
          "#{@target_node}:0.1.0",
          nil,
          child_opts(ctx, guest_fn: :spawn)
        )

      assert Authority.budget(decision.authority).in_flight == 1
      :ok = Authority.release_invoke(decision.authority)
      assert Authority.budget(auth).in_flight == 0

      # Depth-capped spawn consumes nothing.
      deep =
        Enum.reduce(1..Authority.depth_cap(), auth, fn _i, a ->
          Authority.unbound_child(a, "reagent:local.deep")
        end)

      assert {:error, {:invoke_denied, :depth_cap}} =
               Opus.Chain.step_invoke(
                 deep,
                 "#{@target_node}:0.1.0",
                 nil,
                 child_opts(ctx, guest_fn: :spawn)
               )

      assert Authority.budget(auth).in_flight == 0
    end
  end
end
