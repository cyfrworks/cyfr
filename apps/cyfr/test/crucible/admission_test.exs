# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.AdmissionTest do
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
  alias Crucible.Admission
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures

  @math_wasm_path Path.expand("../support/test_wasm/math.wasm", __DIR__)
  @root_node "reagent:local.chain-root"
  @target_node "reagent:local.chain-target"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "admission_test_#{System.unique_integer([:positive])}")

    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    ctx = %Context{
      user_id: "admission_test_user_#{System.unique_integer([:positive])}",
      athanor_id: Sanctum.TestContext.athanor_id(),
      scope: :athanor,
      permissions: MapSet.new([:execute]),
      authenticated: true,
      origin: :interactive
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
      assert {:error, {:corrupt, {:profile, "prof-chain-damaged"}}} =
               Admission.authority_for(ctx, :default, "#{@root_node}:0.1.0")

      assert {:error, {:corrupt, {:profile, "prof-chain-damaged"}}} =
               Admission.authority_for(ctx, {:id, "prof-chain-damaged"}, @root_node)

      # A pinned id naming another profile is not about the damaged row.
      assert {:ok, %Authority{profile_id: "prof-chain"}} =
               Admission.authority_for(ctx, {:id, "prof-chain"}, @root_node)

      # The consent status reads the damaged row as damage, never as an
      # outage or as current.
      assert {:error, :corrupt} = Aqua.ConsentStatus.state(ctx, @root_node)
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

    test "a connection roots under the named binding its ingress holds, with its own key, and " <>
           "a name the ingress lacks is refused with no default in its place",
         %{ctx: ctx} do
      person = Sanctum.TestContext.local(:prism)
      %{ref: ref, default: default, work: work} = named_app!(person)
      {:ok, name_ref} = Prima.ComponentRef.to_name_ref(ref)

      assert {:ok, %Authority{} = picked} =
               Admission.authority_for(ctx, :default, ref, connection: "Work")

      assert picked.resources.vault.entry_id == work.id
      assert picked.resources.vault.binding_key == Blob.binding_key(name_ref, "@ingress", "Work")
      refute Map.has_key?(picked.resources.vault, :named)

      # A run's root is loaded the same way, the pick included.
      assert {:ok, %{authority: rooted}} =
               Admission.authority_and_stamp_for(ctx, :default, ref, connection: "Work")

      assert rooted.resources == picked.resources

      # No account: the ingress's default, as before.
      assert {:ok, %Authority{} = plain} = Admission.authority_for(ctx, :default, ref)
      assert plain.resources.vault.entry_id == default.id
      assert plain.resources.vault.binding_key == Blob.binding_key(name_ref, "@ingress", nil)

      for name <- ["Home", "Works", "default"] do
        assert {:error, :connection_not_granted} =
                 Admission.authority_for(ctx, :default, ref, connection: name),
               "#{inspect(name)} was picked"
      end

      # The account spelled in another case is that account, under the key
      # its stored name spells: a launch's root naming `work` holds Work.
      assert {:ok, %Authority{} = spelled} =
               Admission.authority_for(ctx, :default, ref, connection: "work")

      assert spelled.resources == picked.resources
    end
  end

  # An app of the person's own whose own calls bind a default and the
  # account "Work" beside it, through the consent walk.
  defp named_app!(person) do
    name = "named-root-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "reagent",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => "to call the example API",
          "fields" => ["KEY"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(person, File.read!(@math_wasm_path), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    entry = fn label ->
      {:ok, view} =
        Sanctum.TestContext.create_vault(person, %{
          name: "#{name} #{label}",
          kind: "api_key",
          provider_hint: "example.com",
          fields: %{"KEY" => "k-#{label}"},
          destination: %{"hosts" => ["api.example.com"]},
          disclose: true
        })

      view
    end

    default = entry.("default")
    work = entry.("work")
    ref = "reagent:local." <> name

    decisions = %{
      ref: ref,
      bindings: [
        %{need: "api_key", entry_id: default.id},
        %{need: "api_key", name: "Work", entry_id: work.id}
      ]
    }

    {:ok, plan} = Sanctum.Consent.Plan.plan(person, %{ref: ref})
    {:ok, preview} = Sanctum.Consent.Commit.preview(person, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(person, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    %{ref: ref, default: default, work: work}
  end

  describe "an approved launch's entry" do
    @root_load {Sanctum.Consent.Loader, :load_root, 3}
    @attempt_open {Crucible.Attempt, :open, 1}

    # A context as `Aqua.Launch` hands it to the run it dispatches: the
    # entry its card bound and the name the binding stored it under.
    defp expecting(ctx, entry_id, name),
      do: Map.put(ctx, :approved_entry, %{entry: entry_id, name: name})

    # `fun`'s answer, and the calls this process made to `mfas` while it
    # ran, in order. A process's call trace is not delivered to itself, so
    # a collector takes it; every trace message is delivered before the
    # collector is asked for what it holds.
    defp traced(mfas, fun) do
      test = self()
      collector = spawn_link(fn -> collect(test, []) end)

      on_exit(fn -> for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:global]) end)

      # A pattern applies only to a loaded module, so each is loaded first,
      # and one that matched nothing fails here rather than tracing nothing.
      for {module, _function, _arity} = mfa <- mfas do
        Code.ensure_loaded!(module)
        assert :erlang.trace_pattern(mfa, true, [:global]) == 1
      end

      :erlang.trace(test, true, [:call, {:tracer, collector}])

      answer =
        try do
          fun.()
        after
          :erlang.trace(test, false, [:call])
        end

      delivered = :erlang.trace_delivered(test)
      assert_receive {:trace_delivered, ^test, ^delivered}, 5_000
      send(collector, {:done, delivered})
      assert_receive {:collected, ^delivered, calls}, 5_000
      {answer, calls}
    end

    defp collect(test, calls) do
      receive do
        {:trace, ^test, :call, call} -> collect(test, [call | calls])
        {:done, ref} -> send(test, {:collected, ref, Enum.reverse(calls)})
      end
    end

    defp args_of(calls, {module, function, _arity}),
      do: for({^module, ^function, args} <- calls, do: args)

    test "roots only where the loaded root's binding names the entry under its stored name: " <>
           "another entry, another stored name, a name no longer bound, or none refuses",
         %{ctx: ctx, root: root} do
      person = Sanctum.TestContext.local(:prism)
      %{ref: ref, default: default, work: work} = named_app!(person)

      assert {:ok, %{authority: rooted}} =
               Admission.authority_and_stamp_for(expecting(ctx, work.id, "Work"), :default, ref,
                 connection: "Work"
               )

      assert rooted.resources.vault.entry_id == work.id

      # The name resolves, on the one read that picks it, to another entry
      # than the one approved.
      assert {:error, :approved_entry_moved} =
               Admission.authority_and_stamp_for(
                 expecting(ctx, default.id, "Work"),
                 :default,
                 ref,
                 connection: "Work"
               )

      # The entry approved, under a name its binding does not store: `work`
      # picks the binding stored as `Work`, which is another stored name.
      assert {:error, :approved_entry_moved} =
               Admission.authority_for(expecting(ctx, work.id, "work"), :default, ref,
                 connection: "work"
               )

      # A name the ingress no longer binds: for an approved launch the same
      # stale approval, and an account to grant for anyone else.
      assert {:error, :approved_entry_moved} =
               Admission.authority_for(expecting(ctx, work.id, "Home"), :default, ref,
                 connection: "Home"
               )

      assert {:error, :connection_not_granted} =
               Admission.authority_for(ctx, :default, ref, connection: "Home")

      # No account named: the root holds the default, not the approved one.
      assert {:error, :approved_entry_moved} =
               Admission.authority_for(expecting(ctx, work.id, "Work"), :default, ref)

      # A root whose own calls bind no entry at all.
      seed(ctx, profile_summary(), consent(root))
      assert {:ok, %Authority{}} = Admission.authority_for(ctx, :default, @root_node)

      assert {:error, :approved_entry_moved} =
               Admission.authority_for(expecting(ctx, work.id, "Work"), :default, @root_node)
    end

    test "does not outlive the root's admission: the run carries none on" do
      Cyfr.Test.Sandbox.stop_work_on_exit()
      person = Sanctum.TestContext.local(:prism)
      on_exit(fn -> Prima.Slots.forgive_unreaped(Crucible.Slots, person.athanor_id) end)

      %{ref: ref, work: work} = named_app!(person)

      {_ran, calls} =
        traced([@root_load, @attempt_open], fn ->
          Crucible.run_root(expecting(person, work.id, "Work"), :default, ref <> ":1.0.0", %{},
            connection: "Work"
          )
        end)

      # The root is loaded, and compared, with the account in hand ...
      assert [[root_ctx, _profile, _opts]] = args_of(calls, @root_load)
      assert Map.get(root_ctx, :approved_entry) == %{entry: work.id, name: "Work"}

      # ... and the run is admitted under it, every context it carries on
      # holding none: its attempt's (which its chain, its children and its
      # in-chain calls are given), its close's and its assignment's.
      assert [[opened]] = args_of(calls, @attempt_open)
      assert opened[:authority].resources.vault.entry_id == work.id

      for carried <- [opened[:ctx], opened[:close].ctx, opened[:assignment].ctx] do
        assert Map.get(carried, :approved_entry) == nil
      end
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

    test "a call's connection picks the account its edge binds by that name, and one the edge " <>
           "lacks is denied with no default in its place",
         %{ctx: ctx} do
      bound = fn entry_id, opts ->
        Prima.Test.AuthorityFixtures.bound_vault(
          @root_node,
          @target_node,
          entry_id,
          "sha256:bind-" <> entry_id,
          [projection: %{"fields" => ["KEY"]}] ++ opts
        )
      end

      work = bound.("vlt_work", name: "Work")

      named =
        authority_with_edges(%{
          @target_node => %{"vault" => bound.("vlt_default", named: %{"Work" => work})}
        })

      only_default =
        authority_with_edges(%{@target_node => %{"vault" => bound.("vlt_default", [])}})

      ref = "#{@target_node}:0.1.0"

      assert {:ok, %{bound?: true, authority: child}} =
               Admission.step_invoke(named, ref, nil, child_opts(ctx, connection: "Work"))

      assert %{entry_id: "vlt_work", binding_key: work_key} = child.resources.vault
      assert work_key == Blob.binding_key(@root_node, @target_node, "Work")

      for auth <- [named, only_default] do
        assert {:ok, %{authority: default}} =
                 Admission.step_invoke(auth, ref, nil, child_opts(ctx))

        assert default.resources.vault.entry_id == "vlt_default"

        assert {:ok, %{authority: default}} =
                 Admission.step_invoke(auth, ref, nil, child_opts(ctx, connection: nil))

        assert default.resources.vault.entry_id == "vlt_default"
      end

      assert {:error, {:invoke_denied, :connection_not_granted}} =
               Admission.step_invoke(named, ref, nil, child_opts(ctx, connection: "Home"))

      assert {:error, {:invoke_denied, :connection_not_granted}} =
               Admission.step_invoke(only_default, ref, nil, child_opts(ctx, connection: "Work"))

      # A target no edge binds has no account to pick.
      assert {:error, {:invoke_denied, :connection_not_granted}} =
               Admission.step_invoke(
                 authority_with_edges(%{}),
                 ref,
                 nil,
                 child_opts(ctx, connection: "Work")
               )
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

  # A formula's child call, made as its runner makes it: the host call
  # `admit_child` over an attached attempt of the formula, the one entry an
  # in-chain child call takes.
  describe "a child call's account, spelled in any case" do
    @account_root "formula:local.account-root"
    @account_target "formula:local.account-formula"

    setup %{ctx: ctx} do
      api = Sanctum.TestContext.local(:api)
      wasm = File.read!(@math_wasm_path)

      {:ok, _} =
        Compendium.Registry.publish_bytes(api, wasm, %{
          name: "account-formula",
          version: "0.1.0",
          type: "formula"
        })

      # A formula calling the one above, released apart from it: the caps
      # its manifest asks for give it its own release digest, so calling
      # the other is never a self-call.
      {:ok, _} =
        Compendium.Registry.publish_bytes(api, wasm, %{
          name: "account-root",
          version: "0.1.0",
          type: "formula",
          manifest:
            Jason.encode!(%{
              "name" => "account-root",
              "version" => "0.1.0",
              "type" => "formula",
              "description" => "calls account-formula",
              "caps" => %{"tools" => ["execution.run"]}
            })
        })

      on_exit(fn ->
        Arca.Cache.delete_match(Arca.Cache.Keys.match_component_meta(Context.actor(api)))
        Prima.Slots.forgive_unreaped(Crucible.Slots, api.athanor_id)
      end)

      Cyfr.Test.Sandbox.stop_work_on_exit()
      start_supervised!({Cyfr.Test.ScriptedWorker, ref: "reagent:local.unscripted", script: []})
      {:ok, api: api, ctx: ctx}
    end

    # A root authority at the root formula, pinned to a live profile's head,
    # whose edge to the target formula binds a default and, beside it, the
    # account Work. Both name only scopes, so a child holding either is
    # claimed without reading an entry.
    defp work_account_edge!(api) do
      {pinned, _entry} =
        Cyfr.Test.AttemptFixtures.vault_authority!(api, %{
          kind: "api_key",
          fields: %{"KEY" => "k"}
        })

      digests =
        Map.new([@account_root, @account_target], fn node ->
          {:ok, _ref, _type, component} = Admission.inspect_component(api, node <> ":0.1.0")
          {node, component["release_digest"]}
        end)

      bound = fn entry_id, opts ->
        Prima.Test.AuthorityFixtures.bound_vault(
          @account_root,
          @account_target,
          entry_id,
          "sha256:bind-" <> entry_id,
          [projection: %{"scopes" => ["fixture.scope"]}] ++ opts
        )
      end

      vault = bound.("vlt_default", named: %{"Work" => bound.("vlt_work", name: "Work")})
      limits = Prima.Test.AuthorityFixtures.limits_map()

      {:ok, blob} =
        Blob.parse(%{
          "canonical" => "jcs-1",
          "nodes" => %{
            @account_root => %{
              "limits" => limits,
              "edges" => %{"@ingress" => %{}, @account_target => %{"vault" => vault}}
            },
            @account_target => %{"limits" => limits, "edges" => %{}}
          }
        })

      {:ok, authority} =
        Authority.root(
          %{
            profile_id: pinned.profile_id,
            consent_id: pinned.consent_id,
            source_ref: @account_root,
            kind: :owner,
            invoke_mode: :open_inert,
            activation: digests
          },
          blob,
          ceiling: Prima.Test.AuthorityFixtures.ceiling()
        )

      Cyfr.Test.AttemptFixtures.attached!(
        ctx: api,
        authority: authority,
        component_ref: @account_root <> ":0.1.0",
        component_type: :formula,
        worker: Cyfr.Test.ScriptedWorker.endpoint(),
        reservation: true
      )
    end

    defp admit_child(fixture, child_key, connection) do
      args =
        %{
          "reference" => @account_target <> ":0.1.0",
          "input" => %{},
          "guest_fn" => "call",
          "need" => nil,
          "child_key" => child_key
        }
        |> Prima.MapUtil.put_present("connection", connection)

      Cyfr.Test.AttemptFixtures.call(fixture, "admit_child", args)
    end

    defp admitted_child!(answer) do
      assert %{"ok" => %{"assignment" => token}} = answer
      {:ok, admitted} = Prima.Assignment.read(token)
      {:ok, child} = Authority.from_wire(admitted.authority)
      {admitted.execution_id, child}
    end

    defp children_of(fixture) do
      Arca.Repo.all(
        Ecto.Query.from(e in Arca.Schemas.Execution,
          where: e.parent_execution_id == ^fixture.execution_id,
          select: e.id
        )
      )
    end

    @tag :capture_log
    test "a child call naming `work` while `Work` is bound holds Work's binding, under its " <>
           "stored key",
         %{api: api} do
      fixture = work_account_edge!(api)

      {_id, child} = admitted_child!(admit_child(fixture, "ck_lower", "work"))
      assert child.resources.vault.entry_id == "vlt_work"

      assert child.resources.vault.binding_key ==
               Blob.binding_key(@account_root, @account_target, "Work")
    end

    @tag :capture_log
    test "a retry spelled `work` after `Work` was admitted is the same call, and a reused key " <>
           "naming another account still refuses",
         %{api: api} do
      fixture = work_account_edge!(api)

      {id, _child} = admitted_child!(admit_child(fixture, "ck_work", "Work"))

      # One account however it is spelled: the same child under its key.
      for spelled <- ["work", "WORK", "Work"] do
        {again, _child} = admitted_child!(admit_child(fixture, "ck_work", spelled))
        assert again == id, "#{spelled} under the key was another child"
      end

      # Another account, or none, under the key is refused before anything
      # of the child is answered.
      for other <- ["Home", nil] do
        assert %{"error" => "guest_error", "type" => "invalid_request", "message" => message} =
                 admit_child(fixture, "ck_work", other)

        assert message =~ "child_key"
      end

      assert children_of(fixture) == [id]
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

    test "an unresolvable reference answers Compendium's own refusal", %{ctx: ctx} do
      assert {:error, {:not_found, {:component, "reagent:local.gone:1.0.0"}}} =
               Admission.inspect_component(ctx, "reagent:local.gone:1.0.0")
    end
  end

  describe "the component's type" do
    # The registry's type decides; a caller's asserted type is checked
    # against it and refused as a rostered reason, before any row exists.
    test "an asserted type that is not the registry's is refused with both types in the reason" do
      ctx = Sanctum.TestContext.local(:prism)

      assert {:error, {:component_type_mismatch, :formula, :reagent} = reason} =
               Admission.admit(ctx, "#{@target_node}:0.1.0", %{}, type: "formula")

      assert %Prima.Refusal{class: :invalid_argument, message: message} =
               Grimoire.Error.classify(reason)

      refute message =~ @target_node
    end

    test "a type outside the executable roster is an invalid argument" do
      ctx = Sanctum.TestContext.local(:prism)

      assert {:error, :invalid_component_type} =
               Admission.admit(ctx, "#{@target_node}:0.1.0", %{}, type: "sk-not-a-type")

      assert %Prima.Refusal{class: :invalid_argument, message: message} =
               Grimoire.Error.classify(:invalid_component_type)

      refute message =~ "sk-not-a-type"
    end
  end

  describe "the component's bytes" do
    test "bytes that do not hash to the recorded digest are corrupt, never unavailable" do
      ctx = Sanctum.TestContext.local(:prism)
      actor = Sanctum.Context.actor(ctx)

      {:ok, row} = Arca.ComponentStorage.get_component(actor, "chain-target", "0.1.0", "local")

      # The row altered outside the publish path: it now records a digest
      # its stored bytes do not hash to.
      digest = Prima.Digest.sha256("not the bytes the row's artifact holds")

      {1, _} =
        Ecto.Query.from(c in Arca.Schemas.Component, where: c.id == ^row.id)
        |> Arca.Repo.update_all(set: [digest: digest])

      assert {:error, {:corrupt, {:artifact, ^digest}} = reason} =
               Crucible.Artifacts.fetch(ctx, digest, "#{@target_node}:0.1.0")

      assert %Prima.Refusal{class: :corrupt} = Grimoire.Error.classify(reason)
    end
  end

  describe "the cell's standing" do
    test "a member that holds no slot admits nothing, and asking costs no query", %{ctx: ctx} do
      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)

      # Every road into the engine passes here, so the check that refuses
      # is a term read: it must not put a query in front of every start.
      assert {:error, :control_plane_lost} =
               Arca.Test.QueryCounter.assert_queries(0, fn ->
                 Admission.admit(ctx, "reagent:local.chain-root:0.1.0", %{}, [])
               end)

      # With the standing back, admission is past this gate and refuses
      # for its own reasons, not the cell's.
      Arca.ControlPlane.record(:unclaimed)

      assert {:error, refusal} = Admission.admit(ctx, "reagent:local.chain-root:0.1.0", %{}, [])
      refute refusal == :control_plane_lost
    end
  end

  describe "the root's own grant read damaged" do
    # Admission cannot read `Aqua`, so its reading of the loader's damage
    # (`Crucible.Admission.root_refusal/2`) is held to the consent
    # status's here, over every member the loader declares
    # (`Sanctum.Consent.Loader.load_error/0`): a member the status reads
    # as damage that admission leaves as it stands, or one admission
    # relabels that the status does not read as damage, fails this.
    test "is typed damage for exactly the loader's answers the consent status reads as damage" do
      members = declared(Sanctum.Consent.Loader, :load_error)
      assert members != []

      # Each member is named in a failure by its type, as the loader spells it.
      for member <- members do
        reason = instance(member)
        answer = Admission.root_refusal("prof_own", reason)

        case Aqua.ConsentStatus.classify_refusal(reason) do
          {:error, :corrupt} ->
            assert {spelled(member), typed_damage?(reason, answer)} == {spelled(member), true}

          _not_damage ->
            assert {spelled(member), answer == reason} == {spelled(member), true}
        end
      end
    end
  end

  # What admission answers for damage, the router answers typed: the damaged
  # head and the damaged profile, naming the root's own profile, and the
  # loader's own typed damage, of the head or a lender, as the loader named
  # it.
  defp typed_damage?({:head_corrupt, _profile_id} = reason, answer), do: answer == reason

  defp typed_damage?({:lender_corrupt, _target, _profile_id} = reason, answer),
    do: answer == reason

  defp typed_damage?({:invalid_profile, _what}, answer),
    do: answer == {:corrupt, {:profile, "prof_own"}}

  defp typed_damage?(_reason, answer), do: answer == {:head_corrupt, "prof_own"}

  # The members of `module`'s type `name`, a union flattened through the
  # types it names, each with the module whose type spells it.
  defp declared(module, name) do
    case type_body(module, name) do
      {:type, _, :union, members} -> Enum.flat_map(members, &flattened(module, &1))
      member -> flattened(module, member)
    end
  end

  defp flattened(_module, {:remote_type, _, [{:atom, _, remote}, {:atom, _, name}, []]}),
    do: declared(remote, name)

  defp flattened(module, {:user_type, _, name, []}), do: declared(module, name)
  defp flattened(module, member), do: [{module, member}]

  defp type_body(module, name) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    case for {kind, {^name, body, []}} <- types, kind in [:type, :typep, :opaque], do: body do
      [body] -> body
      _ -> flunk("#{inspect(module)} declares no type #{name}/0")
    end
  end

  defp spelled({_module, type}) do
    {:"::", _, [_name, quoted]} = Code.Typespec.type_to_quoted({:member, type, []})
    Macro.to_string(quoted)
  end

  # A value of the member's type: each element built from its own type,
  # through the types it names.
  defp instance({module, type}), do: build(module, type)

  defp build(_module, {:atom, _, atom}), do: atom
  defp build(_module, {:integer, _, integer}), do: integer
  defp build(module, {:ann_type, _, [_name, type]}), do: build(module, type)
  defp build(module, {:type, _, :union, [first | _]}), do: build(module, first)
  defp build(_module, {:type, _, :tuple, :any}), do: {}

  defp build(module, {:type, _, :tuple, elements}),
    do: elements |> Enum.map(&build(module, &1)) |> List.to_tuple()

  defp build(_module, {:type, _, :list, _}), do: []
  defp build(module, {:type, _, :nonempty_list, [element]}), do: [build(module, element)]
  defp build(_module, {:type, _, :map, :any}), do: %{}

  defp build(module, {:type, _, :map, fields}) do
    for {:type, _, :map_field_exact, [key, value]} <- fields,
        into: %{},
        do: {build(module, key), build(module, value)}
  end

  defp build(_module, {:type, _, :binary, []}), do: "x"
  defp build(_module, {:type, _, kind, []}) when kind in [:atom, :module, :term, :any], do: :x
  defp build(_module, {:type, _, :boolean, []}), do: true

  defp build(_module, {:type, _, kind, []})
       when kind in [:integer, :non_neg_integer, :pos_integer],
       do: 1

  defp build(_module, {:remote_type, _, [{:atom, _, remote}, {:atom, _, name}, []]}),
    do: build(remote, type_body(remote, name))

  defp build(module, {:user_type, _, name, []}), do: build(module, type_body(module, name))
  defp build(module, type), do: flunk("no value of #{inspect(module)}'s #{inspect(type)}")

  defp cached?(ctx, reference) do
    case Arca.Cache.get(Arca.Cache.Keys.component_meta(Sanctum.Context.actor(ctx), reference)) do
      {:ok, _} -> {:ok, :cached}
      :miss -> :miss
    end
  end
end
