# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.AdmissionTest do
  @moduledoc """
  The authority an execution would run under, decided without running it:
  a root selects its profile and loads the consent, refusing an absent,
  ambiguous or drifted one; a routed root selects public-first and steps
  its edge; a child steps its caller's authority, charging a spawn and
  refusing a denied step or a malformed need before any charge.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Cyfr.Execution.Admission
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures

  @math_wasm_path Path.expand("../../support/test_wasm/math.wasm", __DIR__)
  @root_node "reagent:local.chain-root"
  @target_node "reagent:local.chain-target"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path =
      Path.join(System.tmp_dir!(), "admission_test_#{System.unique_integer([:positive])}")

    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    ctx = %Context{
      user_id: "admission_test_user_#{System.unique_integer([:positive])}",
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
    {:ok, _target_component} =
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

    {:ok, ctx: ctx, root: root_component}
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

    Jason.encode!(%{
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
    })
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
        activation: %{@root_node => root_component.release_digest},
        vault_refs: []
      },
      overrides
    )
  end

  defp seed(ctx, profile, consent) do
    :ok = ConsentFixtures.seed_head!(ctx, profile, consent)
  end

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
    Keyword.merge([ctx: Context.enter_guest(ctx)], overrides)
  end

  describe "authority_for/4" do
    test "loads the root authority of the selected profile's consent", %{ctx: ctx, root: root} do
      seed(ctx, profile_summary(), consent(root))

      assert {:ok, %Authority{} = auth} = Admission.authority_for(ctx, :default, @root_node)
      assert auth.profile_id == "prof-chain"
      assert auth.consent_id == "consent-chain"
      assert auth.cursor == {:bound, @root_node}
    end

    test "no profile refuses instead of guessing", %{ctx: ctx} do
      assert {:error, :no_profile} =
               Admission.authority_for(ctx, :default, "#{@root_node}:0.1.0")
    end

    test "two active owner profiles are ambiguous without a selector", %{ctx: ctx, root: root} do
      seed(ctx, profile_summary(), consent(root))

      # Its own consent id: a revision is a row with a primary key, so the
      # second profile's head cannot be the first's.
      seed(
        ctx,
        profile_summary(%{id: "prof-chain-2", label: "work"}),
        consent(root, %{id: "consent-chain-2"})
      )

      assert {:error, {:ambiguous, ids}} =
               Admission.authority_for(ctx, :default, "#{@root_node}:0.1.0")

      assert Enum.sort(ids) == ["prof-chain", "prof-chain-2"]

      # An explicit selector resolves it.
      assert {:ok, %{authority: auth, profile: %{id: "prof-chain-2"}}} =
               Admission.authority_and_stamp_for(ctx, {:label, "work"}, "#{@root_node}:0.1.0")

      assert auth.profile_id == "prof-chain-2"
    end

    test "consent drift refuses with consent_required", %{ctx: ctx, root: root} do
      drifted = consent(root, %{activation: %{@root_node => "sha256:stale-grant"}})
      seed(ctx, profile_summary(), drifted)

      assert {:error, {:consent_required, payload}} =
               Admission.authority_for(ctx, :default, "#{@root_node}:0.1.0")

      assert payload.profile_id == "prof-chain"
      assert payload.current_revision == 1
    end

    test "a public route selects the public profile even for an authenticated caller", %{
      ctx: ctx,
      root: root
    } do
      seed(ctx, profile_summary(), consent(root))

      seed(
        ctx,
        profile_summary(%{id: "prof-chain-pub", kind: :public, label: "public"}),
        consent(root, %{id: "consent-chain-pub", invoke_mode: :edge_only})
      )

      assert ctx.authenticated

      assert {:ok, auth} =
               Admission.authority_for(ctx, :default, "#{@root_node}:0.1.0", route: :public)

      assert auth.profile_id == "prof-chain-pub"
      assert auth.profile_kind == :public
      assert auth.invoke_mode == :edge_only
    end

    test "a profile row that cannot be decoded refuses every selection it could answer", %{
      ctx: ctx,
      root: root
    } do
      seed(ctx, profile_summary(), consent(root))

      seed(
        ctx,
        profile_summary(%{id: "prof-chain-damaged", label: "damaged"}),
        consent(root, %{id: "consent-chain-damaged"})
      )

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(p in Arca.Schemas.Profile,
            where: p.athanor_id == ^ctx.athanor_id and p.id == "prof-chain-damaged"
          ),
          set: [status: "sideways"]
        )

      # A default or routed selection could be the damaged row's: never a guess.
      assert {:error, {:unavailable, "Consent profile prof-chain-damaged"}} =
               Admission.authority_for(ctx, :default, "#{@root_node}:0.1.0")

      assert {:error, {:unavailable, "Consent profile prof-chain-damaged"}} =
               Admission.authority_for(ctx, {:id, "prof-chain-damaged"}, @root_node)

      # A pinned id naming another profile is not about the damaged row.
      assert {:ok, %Authority{profile_id: "prof-chain"}} =
               Admission.authority_for(ctx, {:id, "prof-chain"}, @root_node)
    end

    @tag :capture_log
    test "a profile store that cannot answer is unavailable, not an absent profile", %{
      ctx: ctx,
      root: root
    } do
      seed(ctx, profile_summary(), consent(root))
      Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")

      assert {:error, {:unavailable, "Consent profiles"}} =
               Admission.authority_for(ctx, :default, "#{@root_node}:0.1.0")
    end

    test "the stamp carries the activation graph the loader verified", %{ctx: ctx, root: root} do
      seed(ctx, profile_summary(), consent(root))

      assert {:ok, %{stamp: stamp, profile: %{id: "prof-chain"}}} =
               Admission.authority_and_stamp_for(ctx, :default, "#{@root_node}:0.1.0")

      assert stamp.activation_graph == %{@root_node => root.release_digest}
      assert is_binary(stamp.activation_digest)
    end
  end

  describe "root_edge/4" do
    setup %{ctx: ctx, root: root} do
      blob_with_edge = blob_json(%{@target_node => %{}})

      seed(
        ctx,
        profile_summary(%{id: "prof-route-pub", kind: :public, label: "public"}),
        consent(root, %{
          id: "consent-route-pub",
          invoke_mode: :edge_only,
          resolved_policy: blob_with_edge
        })
      )

      seed(ctx, profile_summary(), consent(root, %{resolved_policy: blob_with_edge}))
      :ok
    end

    test "a public route selects the public profile despite authentication and binds the edge",
         %{ctx: ctx} do
      assert ctx.authenticated

      assert {:ok, %{root: root, decision: decision}} =
               Admission.root_edge(ctx, @root_node, "#{@target_node}:0.1.0", route: :public)

      assert root.profile.id == "prof-route-pub"
      assert decision.bound?
      assert decision.authority.profile_id == "prof-route-pub"
      assert decision.authority.profile_kind == :public
      assert decision.authority.cursor == {:bound, @target_node}
      assert decision.authority.depth == 1
    end

    test "a protected route selects the owner profile", %{ctx: ctx} do
      assert {:ok, %{root: %{profile: %{id: "prof-chain"}}, decision: %{bound?: true}}} =
               Admission.root_edge(ctx, @root_node, "#{@target_node}:0.1.0", route: :protected)
    end

    test "an edge_only public profile denies an off-edge reference", %{ctx: ctx} do
      assert {:error, {:invoke_denied, :edge_only}} =
               Admission.root_edge(ctx, @root_node, "reagent:local.off-edge:1.0.0",
                 route: :public
               )
    end

    test "a call without a route raises rather than falling through to a guess", %{ctx: ctx} do
      assert_raise KeyError, ~r/:route/, fn ->
        Admission.root_edge(ctx, @root_node, "#{@target_node}:0.1.0", [])
      end
    end
  end

  describe "step_invoke/4" do
    test "a consented edge binds the child to it", %{ctx: ctx} do
      auth = authority_with_edges(%{@target_node => %{}})

      assert {:ok, decision} =
               Admission.step_invoke(auth, "#{@target_node}:0.1.0", nil, child_opts(ctx))

      assert decision.bound?
      assert decision.reference == "#{@target_node}:0.1.0"
      assert decision.component["component_ref"] =~ @target_node
      assert decision.authority.cursor == {:bound, @target_node}
      assert decision.authority.chain == [@root_node, @target_node]
    end

    test "an off-graph target steps to a zero child, not the caller's authority", %{ctx: ctx} do
      auth = authority_with_edges(%{})

      assert {:ok, %{bound?: false, authority: zero}} =
               Admission.step_invoke(auth, "#{@target_node}:0.1.0", nil, child_opts(ctx))

      assert zero.cursor == :unbound
      assert zero.profile_id == nil
      assert zero.policy == :none
    end

    test "an edge_only authority denies an edge-miss instead of stepping inert", %{ctx: ctx} do
      {:ok, blob} = Blob.parse(Jason.decode!(blob_json()))

      profile = %{
        profile_id: "prof-pub",
        consent_id: "consent-pub",
        source_ref: @root_node,
        kind: :public,
        invoke_mode: :edge_only,
        activation: %{@root_node => "sha256:act-root"}
      }

      {:ok, auth} =
        Authority.root(profile, blob, ceiling: Sanctum.Policy.Ceiling.platform_ceiling())

      assert {:error, {:invoke_denied, :edge_only}} =
               Admission.step_invoke(auth, "#{@target_node}:0.1.0", nil, child_opts(ctx))
    end

    test "a need containing the edge separator is rejected before edge lookup", %{ctx: ctx} do
      auth = authority_with_edges(%{@target_node => %{}})

      assert {:error, {:invalid_need, "a|b"}} =
               Admission.step_invoke(auth, "#{@target_node}:0.1.0", "a|b", child_opts(ctx))
    end

    test "a spawn charges the root budget and a denied spawn does not", %{ctx: ctx} do
      auth = authority_with_edges(%{@target_node => %{}})
      assert Sanctum.Authority.budget(auth).in_flight == 0

      {:ok, decision} =
        Admission.step_invoke(
          auth,
          "#{@target_node}:0.1.0",
          nil,
          child_opts(ctx, guest_fn: :spawn)
        )

      assert Sanctum.Authority.budget(decision.authority).in_flight == 1
      :ok = Sanctum.Authority.release_invoke(decision.authority)
      assert Sanctum.Authority.budget(auth).in_flight == 0

      # Depth-capped spawn consumes nothing.
      deep =
        Enum.reduce(1..Authority.depth_cap(), auth, fn _i, a ->
          Authority.unbound_child(a, "reagent:local.deep")
        end)

      assert {:error, {:invoke_denied, :depth_cap}} =
               Admission.step_invoke(
                 deep,
                 "#{@target_node}:0.1.0",
                 nil,
                 child_opts(ctx, guest_fn: :spawn)
               )

      assert Sanctum.Authority.budget(auth).in_flight == 0
    end
  end

  describe "inspect_component/2" do
    test "answers the registry row with string keys and serves it from the cache after", %{
      ctx: ctx
    } do
      reference = "#{@target_node}:0.1.0"

      assert {:ok, component_ref, "reagent", component} =
               Admission.inspect_component(ctx, reference)

      assert component_ref == component["component_ref"]
      assert is_binary(component["release_digest"])

      assert {:ok, :cached} = cached?(ctx, reference)

      assert {:ok, ^component_ref, "reagent", ^component} =
               Admission.inspect_component(ctx, reference)
    end

    test "an unresolvable reference answers a sentence", %{ctx: ctx} do
      assert {:error, "Failed to resolve component 'reagent:local.gone:1.0.0': " <> _} =
               Admission.inspect_component(ctx, "reagent:local.gone:1.0.0")
    end
  end

  describe "the cell's standing" do
    test "a member that holds no slot admits nothing, and asking costs no query", %{ctx: ctx} do
      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)

      # Every road into the engine passes here, so the check that refuses
      # is a term read: it must not put a query in front of every start.
      assert {:error, "control plane ownership lost" <> _} =
               Arca.Test.QueryCounter.assert_queries(0, fn ->
                 Admission.admit(ctx, "reagent:local.chain-root:0.1.0", %{}, [])
               end)

      # With the standing back, admission is past this gate and refuses
      # for its own reasons, not the cell's.
      Arca.ControlPlane.record(:unclaimed)

      assert {:error, refusal} = Admission.admit(ctx, "reagent:local.chain-root:0.1.0", %{}, [])
      refute refusal =~ "control plane ownership lost"
    end
  end

  defp cached?(ctx, reference) do
    case Arca.Cache.get(Arca.Cache.Keys.component_meta(Sanctum.Context.actor(ctx), reference)) do
      {:ok, _} -> {:ok, :cached}
      :miss -> :miss
    end
  end
end
