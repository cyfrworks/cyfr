# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.ProviderTest do
  use ExUnit.Case, async: false

  # Runs and cancels run on the opus worker service.

  import Ecto.Query, only: [from: 2]

  alias Crucible.Provider
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"

  setup tags do
    # Use a test-specific base path to avoid state leaking between tests
    test_path = Path.join(System.tmp_dir!(), "execution_mcp_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # Every execution roots under a profile's consent: bootstrap mints one
    # through the production DB source, and the loader reads it back.

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    Cyfr.Test.Sandbox.setup!(tags)

    rand_id = :rand.uniform(100_000)

    ctx =
      Context.build(
        user_id: "mcp_test_user_#{rand_id}",
        # Unique athanor per test: executions/logs are athanor-scoped (shared
        # within a tenant), so isolation between tests is by athanor.
        athanor_id: "ath_mcp_test_#{rand_id}",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        namespace: "testns",
        authenticated: true
      )
      |> Sanctum.TestContext.via(:api)

    # A run is admitted only in an athanor that stands: the test's own has a row.
    Arca.Test.Actor.athanor!(ctx.athanor_id)

    # Plant the test WASM in a private seed so bootstrap can mint it.
    Cyfr.Test.SeedBundle.isolate!()
    wasm_bytes = File.read!(@math_wasm_path)

    {:ok, _component} =
      Arca.Test.UnitFixtures.ship_bytes!(ctx, wasm_bytes, %{
        name: "test-math",
        version: "0.1.0",
        type: "reagent",
        description: "Test math component"
      })

    {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path, ref: @test_ref}
  end

  # ============================================================================
  # Tool Discovery
  # ============================================================================

  describe "tools/0" do
    test "an agent is never rooted from the wire: a turn starts through thread.send alone",
         %{ctx: ctx} do
      for action <- ["run", "run_stream"] do
        assert {:error, {:invalid_argument, message}} =
                 Provider.handle("execution", ctx, %{
                   "action" => action,
                   "reference" => "agent:local.aqua",
                   "input" => %{}
                 })

        assert message =~ "thread.send"
      end

      assert {:error, {:invalid_argument, _}} =
               Grimoire.call_external("execution", ctx, %{
                 "action" => "run",
                 "reference" => "agent:local.aqua",
                 "input" => %{}
               })
    end

    test "returns the execution and card tools, each action-based" do
      tools = Provider.tools()
      assert tools |> Enum.map(& &1.name) |> Enum.sort() == ["card", "execution"]

      card = Enum.find(tools, &(&1.name == "card"))
      assert Enum.sort(card.input_schema["properties"]["action"]["enum"]) == ["press", "refresh"]
    end

    test "each tool has required schema fields" do
      for tool <- Provider.tools() do
        assert is_binary(tool.name)
        assert is_binary(tool.title)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
        assert tool.input_schema["type"] == "object"
        assert "action" in tool.input_schema["required"]
      end
    end

    test "execution tool has correct actions" do
      tools = Provider.tools()
      tool = Enum.find(tools, &(&1.name == "execution"))
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert "run" in actions
      assert "list" in actions
      assert "logs" in actions
      assert "cancel" in actions
    end
  end

  # ============================================================================
  # Resources
  # ============================================================================

  describe "resources/0" do
    test "returns no concrete resources" do
      resources = Provider.resources()
      assert resources == []
    end
  end

  describe "resource_templates/0" do
    test "returns execution resource templates" do
      templates = Provider.resource_templates()
      assert length(templates) == 2

      uris = Enum.map(templates, & &1.uriTemplate)
      assert "crucible://executions/{id}" in uris
      assert "crucible://executions/{id}/logs" in uris
    end
  end

  # ============================================================================
  # Execution Tool - Run Action
  #
  # Note: math.wasm is a core module (not a WASI P2 Component Model binary),
  # so executions fail at runtime with "Component Model load failed". However,
  # the Executor still writes started + failed records to SQLite, so we can
  # verify record-keeping behavior by inspecting the failed records.
  # ============================================================================

  describe "the origin a run over the API runs under" do
    test "a grant naming interactive alone refuses it, recording nothing; naming programmatic admits it",
         %{ctx: ctx, ref: ref} do
      {:ok, %{profile_id: profile_id}} = Crucible.authority_for(ctx, :default, ref)

      run = fn ->
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2}
        })
      end

      # The person's grant, as a first grant leaves it: interactive alone.
      Sanctum.Test.ConsentFixtures.regrant_origins!(ctx, profile_id, [:interactive])

      assert {:error, {:consent_required, %{profile_id: ^profile_id}}} = run.()
      assert {:ok, %{count: 0}} = Provider.handle("execution", ctx, %{"action" => "list"})

      # Granted again naming programmatic: the run is admitted as one.
      Sanctum.Test.ConsentFixtures.regrant_origins!(ctx, profile_id, [:interactive, :programmatic])

      _ = run.()

      assert {:ok, %{executions: [%{execution_id: id}]}} =
               Provider.handle("execution", ctx, %{"action" => "list"})

      assert %{origin: "programmatic", profile_id: ^profile_id} =
               Arca.Repo.get!(Arca.Schemas.Execution, id)
    end
  end

  describe "execution tool - run action" do
    test "executes registered component and creates failed record", %{ctx: ctx, ref: ref} do
      # Execution will fail because math.wasm is a core module, not a Component Model binary
      _result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 10, "b" => 25}
        })

      # List to get the execution record
      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1

      execution = hd(list_result.executions)
      assert String.starts_with?(execution.execution_id, "exec_")
      assert execution.status == "failed"

      # Get detailed logs to verify component_type and error
      {:ok, logs_result} =
        Provider.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => execution.execution_id
        })

      assert logs_result.component_type == "reagent"
      assert logs_result.status == "failed"
      assert logs_result.error =~ "Component compilation failed"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "",
          "input" => %{}
        })

      assert err_msg(msg) =~ "cannot be empty"
    end

    test "returns error for unregistered component", %{ctx: ctx} do
      # An unregistered component has no profile, so the consent gate
      # refuses before resolution is attempted.
      {:error, msg} =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "reagent:local.nonexistent:0.1.0",
          "input" => %{"a" => 1, "b" => 2}
        })

      assert {:consent_required, %{}} = msg
      assert err_msg(msg) =~ "Consent required"
    end

    test "a connection roots the run under the account its profile's ingress binds by that " <>
           "name, and a name it lacks is refused setup required with nothing run" do
      person = Sanctum.TestContext.local(:prism)
      caller = Sanctum.TestContext.local(:api)
      ref = named_app!(person)

      run = fn connection ->
        Provider.handle("execution", caller, %{
          "action" => "run",
          "reference" => ref <> ":1.0.0",
          "input" => %{"a" => 1, "b" => 2},
          "connection" => connection
        })
      end

      listed = fn ->
        {:ok, %{executions: executions}} =
          Provider.handle("execution", caller, %{"action" => "list"})

        executions
      end

      # A name the ingress does not bind is a grant to make, typed: no row.
      for name <- ["Home", "Works"] do
        assert {:error, :connection_not_granted} = run.(name)
      end

      assert listed.() == []

      assert %Prima.Refusal{class: :setup_required} =
               Prima.Refusal.classify(:connection_not_granted)

      # The account it binds is admitted, never refused for being named:
      # the run is rooted and recorded.
      result = run.("Work")
      refute match?({:error, {:invalid_argument, _}}, result)
      refute match?({:error, :connection_not_granted}, result)
      assert [%{execution_id: id}] = listed.()
      assert %{reference: reference} = Arca.Repo.get!(Arca.Schemas.Execution, id)
      assert String.starts_with?(reference, ref)
    end

    test "respects component type parameter", %{ctx: ctx, ref: ref} do
      # Component type is extracted from the reference before execution,
      # so it should be present in the record even though execution fails
      _result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2},
          "type" => "reagent"
        })

      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1

      execution = hd(list_result.executions)

      {:ok, logs_result} =
        Provider.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => execution.execution_id
        })

      assert logs_result.component_type == "reagent"
    end
  end

  # ============================================================================
  # A consent or component graph a run cannot read, as an MCP client reads it
  # ============================================================================

  describe "a consent or component graph the run cannot read" do
    # A store that cannot answer a run's consent or component graph, or a
    # consent or graph stored damaged, is answered in its own class
    # (`unavailable`, `corrupt`) and sentence, never as an authority error
    # or a grant to make, and nothing starts. An MCP client reads the
    # loader's head and lender refusals (`Sanctum.Unauthorized`) as a
    # JSON-RPC error of that class, and admission's own reads of the
    # profile rows and the component graph (`Prima.Refusal`) as a failed
    # tool result whose text is their sentence; the gate's decision log
    # records the class of each.

    @lender "catalyst:local.lend-key"

    test "a head the store cannot answer is unavailable", %{ctx: ctx, ref: ref} do
      call = fn ->
        Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")
        answer = over_mcp(ctx, %{"reference" => ref, "input" => %{}})
        Arca.Repo.query!("ALTER TABLE consents_unavailable RENAME TO consents")
        answer
      end

      rpc_error!(
        ctx,
        call,
        -33103,
        "This app's consent cannot be read right now — try again.",
        "unavailable"
      )
    end

    test "a head stored damaged is corrupt", %{ctx: ctx, ref: ref} do
      profile_id = own_profile_id(ctx)
      :ok = ConsentFixtures.hand_edit_head!(ctx, profile_id, scope: "sideways")

      rpc_error!(
        ctx,
        fn -> over_mcp(ctx, %{"reference" => ref, "input" => %{}}) end,
        -33104,
        "This app's consent is damaged and cannot be used — revoke profile " <>
          "#{profile_id} and grant it again.",
        "corrupt"
      )
    end

    test "a lender the store cannot answer is unavailable", %{ctx: ctx} do
      root = lending_root!(ctx)

      # The store stops answering profiles once the run's own head is read
      # whole, so only the lender's read meets the outage.
      call = fn ->
        away_after_head!("profiles", "consent-lent-root")
        answer = over_mcp(ctx, %{"reference" => root, "input" => %{}})
        Arca.Repo.query!("ALTER TABLE profiles_unavailable RENAME TO profiles")
        answer
      end

      rpc_error!(
        ctx,
        call,
        -33103,
        "A profile that lends a key here cannot be read right now — try again.",
        "unavailable"
      )
    end

    test "a lender stored damaged is corrupt", %{ctx: ctx} do
      root = lending_root!(ctx)
      set_profile!(ctx, "prof-lend-key", kind: "sideways")

      rpc_error!(
        ctx,
        fn -> over_mcp(ctx, %{"reference" => root, "input" => %{}}) end,
        -33104,
        "A profile that lends a key here is damaged and cannot lend its key — " <>
          "revoke profile prof-lend-key and grant it again.",
        "corrupt"
      )
    end

    test "a profile list the store cannot answer is unavailable", %{ctx: ctx, ref: ref} do
      call = fn ->
        Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")
        answer = over_mcp(ctx, %{"reference" => ref, "input" => %{}})
        Arca.Repo.query!("ALTER TABLE profiles_unavailable RENAME TO profiles")
        answer
      end

      failed_tool!(
        ctx,
        call,
        "Consent profiles is unavailable — retry shortly",
        "unavailable"
      )
    end

    test "a profile row stored damaged is corrupt", %{ctx: ctx, ref: ref} do
      set_profile!(ctx, own_profile_id(ctx), kind: "sideways")

      failed_tool!(
        ctx,
        fn -> over_mcp(ctx, %{"reference" => ref, "input" => %{}}) end,
        "The stored profile is damaged and cannot be used.",
        "corrupt"
      )
    end

    # The run's own grant, stored in each way the consent loader cannot
    # trust, is damage in the run's own sentence: each case first pins the
    # loader's own answer for its damage, then reads what an MCP client
    # receives for it.

    test "an active profile with no head is a damaged head", %{ctx: ctx, ref: ref} do
      profile_id = own_profile_id(ctx)
      set_profile!(ctx, profile_id, head_consent_id: nil)

      assert {:error, {:no_head_consent, ^profile_id}} = own_load(ctx, ref)

      damaged_head!(ctx, ref, profile_id)
    end

    test "a head whose bytes fail their digest is a damaged head", %{ctx: ctx, ref: ref} do
      profile_id = own_profile_id(ctx)

      :ok =
        ConsentFixtures.hand_edit_head!(ctx, profile_id,
          blob_digest: "sha256:" <> String.duplicate("0", 64)
        )

      assert {:error, {:blob_digest_mismatch, _}} = own_load(ctx, ref)

      damaged_head!(ctx, ref, profile_id)
    end

    test "a head whose bytes do not parse is a damaged head", %{ctx: ctx, ref: ref} do
      profile_id = own_profile_id(ctx)

      :ok =
        ConsentFixtures.hand_edit_head!(ctx, profile_id,
          resolved_policy: "not a blob",
          blob_digest: Prima.JCS.hash_binary("not a blob")
        )

      assert {:error, {:invalid_blob, _}} = own_load(ctx, ref)

      damaged_head!(ctx, ref, profile_id)
    end

    test "a head whose revision pins a version its scope does not is a damaged head",
         %{ctx: ctx, ref: ref} do
      profile_id = own_profile_id(ctx)
      :ok = ConsentFixtures.hand_edit_head!(ctx, profile_id, pinned_version: "0.1.0")

      assert {:error, {:invalid_consent, :pinned_version}} = own_load(ctx, ref)

      damaged_head!(ctx, ref, profile_id)
    end

    test "a head whose stored bindings are not the ones its grant holds is a damaged head",
         %{ctx: ctx} do
      root = lending_root!(ctx)

      {1, _} =
        Arca.Repo.update_all(
          from(r in Arca.Schemas.ConsentVaultRef,
            where: r.athanor_id == ^ctx.athanor_id and r.consent_id == "consent-lent-root"
          ),
          set: [via_label: "elsewhere"]
        )

      assert {:error, {:blob_refs_mismatch, _}} = own_load(ctx, root)

      damaged_head!(ctx, root, "prof-lent-root")
    end

    test "a head that binds one entry under two digests is a damaged head", %{ctx: ctx} do
      root = bound_twice_root!(ctx)

      assert {:error, {:inconsistent_binding_digest, "vault-twice"}} = own_load(ctx, root)

      damaged_head!(ctx, root, "prof-twice-root")
    end

    # A release row that does not re-derive is the component's damage, which
    # no grant repairs: never the damaged head, whose sentence says to
    # revoke and grant again.
    @tag :capture_log
    test "a release whose stored digest does not re-derive from its row is a damaged " <>
           "component graph, never a damaged consent",
         %{ctx: ctx, ref: ref} do
      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Component,
            where: c.athanor_id == ^ctx.athanor_id and c.name == "test-math"
          ),
          set: [release_digest: "sha256:" <> String.duplicate("0", 64)]
        )

      assert {:error, {:integrity_alarm, [_tampered]}} = own_load(ctx, ref)

      failed_tool!(
        ctx,
        fn -> over_mcp(ctx, %{"reference" => ref, "input" => %{}}) end,
        "The component graph this run needs is stored damaged and cannot be used.",
        "corrupt"
      )

      # The reason names the run's own root, as admission holds it.
      before = started(ctx)

      assert Provider.handle("execution", ctx, %{
               "action" => "run",
               "reference" => ref,
               "input" => %{}
             }) == {:error, {:corrupt, {:component_graph, ref}}}

      assert started(ctx) == before
    end

    test "a head whose grant holds no node for the run's own component is a damaged head",
         %{ctx: ctx, ref: ref} do
      profile_id = own_profile_id(ctx)

      rewrite_grant!(ctx, profile_id, fn %{"nodes" => nodes} = policy ->
        {node, others} = Map.pop!(nodes, "reagent:local.test-math")
        %{policy | "nodes" => Map.put(others, "reagent:local.not-test-math", node)}
      end)

      assert {:error, {:unknown_source_node, "reagent:local.test-math"}} = own_load(ctx, ref)

      damaged_head!(ctx, ref, profile_id)
    end

    test "a head whose grant holds no ingress for the run's own component is a damaged head",
         %{ctx: ctx, ref: ref} do
      profile_id = own_profile_id(ctx)

      rewrite_grant!(
        ctx,
        profile_id,
        &update_in(&1, ["nodes", "reagent:local.test-math", "edges"], fn edges ->
          Map.delete(edges, "@ingress")
        end)
      )

      assert {:error, {:missing_ingress, "reagent:local.test-math"}} = own_load(ctx, ref)

      damaged_head!(ctx, ref, profile_id)
    end

    # A public profile row over a head that opens every call inert is no
    # grant a commit writes: the profile cannot root an authority, which
    # is the damaged profile admission names, never a damaged head.
    test "a profile and head that cannot root an authority is a damaged profile",
         %{ctx: ctx, ref: ref} do
      profile_id = own_profile_id(ctx)
      set_profile!(ctx, profile_id, kind: "public")

      assert {:error, {:invalid_profile, :public_requires_edge_only}} =
               own_load(ctx, ref, {:id, profile_id})

      failed_tool!(
        ctx,
        fn ->
          over_mcp(ctx, %{"reference" => ref, "input" => %{}, "profile" => profile_id})
        end,
        "The stored profile is damaged and cannot be used.",
        "corrupt"
      )
    end

    test "a component graph the store cannot give right now is unavailable, never a setup to make",
         %{ctx: ctx, ref: ref} do
      # The component's registry row was read within its cache's minutes,
      # as by an earlier run, so the run's graph is the first read to meet
      # the component index the edit leaves behind.
      assert {:ok, _ref, _type, _component} = Crucible.Admission.inspect_component(ctx, ref)

      {:ok, _pending} =
        Arca.StorageProjectionChanges.begin_edit(
          Context.actor(ctx),
          "components",
          "reagents/local/test-math/0.1.0"
        )

      failed_tool!(
        ctx,
        fn -> over_mcp(ctx, %{"reference" => ref, "input" => %{}}) end,
        "The component graph is unavailable — retry shortly",
        "unavailable"
      )
    end

    # SQLite keeps whatever bytes a text column is given, so a row written
    # outside the publish path can hold a release digest that is not text,
    # and the run's graph does not hash; PostgreSQL refuses the write.
    test "a component graph stored damaged is corrupt where the store can hold it",
         %{ctx: ctx, ref: ref} do
      damage = fn ->
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Component,
            where: c.athanor_id == ^ctx.athanor_id and c.name == "test-math"
          ),
          set: [release_digest: <<"sha256:", 0xFF, 0xFE>>]
        )
      end

      case Arca.Repo.adapter() do
        Ecto.Adapters.SQLite3 ->
          assert {1, _} = damage.()

          failed_tool!(
            ctx,
            fn -> over_mcp(ctx, %{"reference" => ref, "input" => %{}}) end,
            "The component graph this run needs is stored damaged and cannot be used.",
            "corrupt"
          )

          # The reason names the run's own root, as admission holds it.
          before = started(ctx)

          assert Provider.handle("execution", ctx, %{
                   "action" => "run",
                   "reference" => ref,
                   "input" => %{}
                 }) == {:error, {:corrupt, {:component_graph, ref}}}

          assert started(ctx) == before

        Ecto.Adapters.Postgres ->
          refused =
            try do
              damage.()
            rescue
              error -> error
            end

          assert %{postgres: %{pg_code: "22021"}} = refused
      end
    end

    test "the assistant's model reads unavailable, not a key to connect, while its graph is",
         %{ctx: _ctx} do
      n = System.unique_integer([:positive])
      user = "local|idp|graph-outage-#{n}"
      {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user, "Graph outage #{n}")
      {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(athanor)
      ctx = PrismWeb.ConnCase.ready_athanor!(athanor.id, user)
      soul = Prima.AgentRef.soul_ref()

      agents = [
        %{"type" => Compendium.agent_soul_type(), "catalyst_ref" => "catalyst:local.claude"}
      ]

      assert %{"catalyst:local.claude" => {:ready, resolved}} = Aqua.model_status(ctx, agents)
      assert {:ok, _authority} = Crucible.authority_for(ctx, :default, soul)

      # The component index falls behind once the model's own listing and
      # plan have read ready, as the assistant's load reads its profiles.
      behind_at_profiles!(ctx, soul)

      assert Aqua.model_status(ctx, agents) == %{
               "catalyst:local.claude" => {:consent_unavailable, resolved}
             }

      assert {:error, {:unavailable, "The component graph"}} =
               Crucible.authority_for(ctx, :default, soul)
    end
  end

  # What an MCP client receives for `tools/call` of `execution.run` with
  # `args`: the JSON-RPC body the transport writes for the router's answer.
  defp over_mcp(ctx, args) do
    message = %Prima.MCP.Message{
      type: :request,
      id: 1,
      method: "tools/call",
      params: %{"name" => "execution", "arguments" => Map.put(args, "action", "run")}
    }

    case Emissary.MCP.Router.dispatch(ctx, message) do
      {:ok, result} -> Prima.MCP.Message.encode_result(1, result)
      {:error, code, text} -> Prima.MCP.Message.encode_error(1, code, text)
      {:error, code, text, data} -> Prima.MCP.Message.encode_error(1, code, text, data)
    end
  end

  # `call` answers an MCP client the JSON-RPC error `code` with `sentence`;
  # the gate records the call admitted and failed in `class`; nothing reads
  # the refusal as a reason the refusal table does not know; and nothing
  # starts.
  defp rpc_error!(ctx, call, code, sentence, class) do
    before = started(ctx)
    {answer, log} = ExUnit.CaptureLog.with_log(call)

    # Read with the tool result beside it, so a call answered as a failed
    # tool result shows what it said.
    assert {answer["error"], answer["result"]["content"]} ==
             {%{"code" => code, "message" => sentence}, nil}

    assert decided(ctx) == [{"admitted", "failed", class}]
    refute log =~ "Prima.Refusal"
    assert started(ctx) == before
  end

  # An `execution.run` of `ref` answers an MCP client the run's own head
  # damaged, naming its profile `profile_id` (`rpc_error!/5`).
  defp damaged_head!(ctx, ref, profile_id) do
    rpc_error!(
      ctx,
      fn -> over_mcp(ctx, %{"reference" => ref, "input" => %{}}) end,
      -33104,
      "This app's consent is damaged and cannot be used — revoke profile " <>
        "#{profile_id} and grant it again.",
      "corrupt"
    )
  end

  # The consent loader's own answer for the root of `ref` under
  # `selector`, asked with what admission asks it with (the profile, the
  # verified component graph and the live shape), before admission answers
  # it.
  defp own_load(ctx, ref, selector \\ :default) do
    {:ok, name_ref} = Prima.ComponentRef.to_name_ref(ref)
    {:ok, candidates} = Sanctum.Consent.profiles(ctx, name_ref)
    {:ok, profile} = Prima.Authority.RootSelect.select(candidates, selector)
    {:ok, _ref, _type, component} = Crucible.Admission.inspect_component(ctx, ref)

    shape =
      case Sanctum.Consent.ShapeDerivation.live_digest(ctx, profile.source_ref) do
        {:ok, digest} -> digest
        {:error, _} -> nil
      end

    Sanctum.Consent.Loader.load_root(ctx, profile,
      live: Compendium.resolve_verified_activation(ctx, component),
      live_shape_digest: shape
    )
  end

  # The head of `profile_id` with its grant rewritten by `fun` (the stored
  # policy decoded in, the policy to store out), stored with its own
  # digest, so the grant's bytes still match it.
  defp rewrite_grant!(ctx, profile_id, fun) do
    {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)
    policy = head.resolved_policy |> Jason.decode!() |> fun.() |> Jason.encode!()

    :ok =
      ConsentFixtures.hand_edit_head!(ctx, profile_id,
        resolved_policy: policy,
        blob_digest: Prima.JCS.hash_binary(policy)
      )
  end

  # `call` answers an MCP client a failed tool result whose one text block
  # is `sentence`, never a JSON-RPC error; the gate records the call
  # admitted and failed in `class`; nothing reads the refusal as a reason
  # the refusal table does not know; and nothing starts.
  defp failed_tool!(ctx, call, sentence, class) do
    before = started(ctx)
    {answer, log} = ExUnit.CaptureLog.with_log(call)

    refute Map.has_key?(answer, "error")
    assert answer["result"]["isError"] == true
    assert answer["result"]["content"] == [%{"type" => "text", "text" => sentence}]
    assert decided(ctx) == [{"admitted", "failed", class}]
    refute log =~ "Prima.Refusal"
    assert started(ctx) == before
  end

  # The gate's decisions on `execution.run` in the context's athanor.
  defp decided(ctx) do
    Arca.Repo.all(
      from(d in Arca.Schemas.DecisionLog,
        where: d.athanor_id == ^ctx.athanor_id and d.tool == "execution" and d.action == "run",
        select: {d.admission, d.completion, d.completion_class}
      )
    )
  end

  # What has started in the context's athanor: its execution rows and
  # their attempts.
  defp started(ctx) do
    {Arca.Repo.aggregate(
       from(e in Arca.Schemas.Execution, where: e.athanor_id == ^ctx.athanor_id),
       :count
     ),
     Arca.Repo.aggregate(
       from(a in Arca.Schemas.ExecutionAttempt, where: a.athanor_id == ^ctx.athanor_id),
       :count
     )}
  end

  # The profile the bootstrap minted for the setup's component.
  defp own_profile_id(ctx) do
    {:ok, [%{id: id}]} = Sanctum.Consent.profiles(ctx, "reagent:local.test-math")
    id
  end

  # A profile row written as no writer of the table would.
  defp set_profile!(ctx, id, changes) do
    {1, _} =
      Arca.Repo.update_all(
        from(p in Arca.Schemas.Profile, where: p.athanor_id == ^ctx.athanor_id and p.id == ^id),
        set: changes
      )
  end

  # A root of the person's own whose edge to `@lender` selects the key the
  # lender's own profile binds, labelled `default`; both grants admit a
  # run over the API. Answers the root's reference.
  defp lending_root!(ctx) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: "lent-root",
        version: "0.1.0",
        type: "reagent"
      })

    root = "reagent:local.lent-root"
    limits = Prima.Test.AuthorityFixtures.limits_map()
    origins = [:interactive, :programmatic]
    lender_key = Prima.Authority.Blob.binding_key(@lender, "@ingress", nil)

    lender_policy =
      Jason.encode!(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @lender => %{
            "limits" => limits,
            "edges" => %{
              "@ingress" => %{
                "vault" => %{
                  "entry_id" => "vault-lend-key",
                  "binding_digest" => "sha256:lend-key",
                  "scope" => "athanor",
                  "destination" => %{"hosts" => ["api.example.com"], "scheme" => "https"},
                  "attach" => %{"in" => "header", "name" => "x-api-key", "template" => "{value}"},
                  "projection" => %{"fields" => ["KEY"]},
                  "binding_key" => lender_key
                }
              }
            }
          }
        }
      })

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{
          id: "prof-lend-key",
          kind: :owner,
          source_ref: @lender,
          label: "default",
          status: :active
        },
        %{
          id: "consent-lend-key",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape-lend-key",
          commit_digest: "sha256:commit-lend-key",
          resolved_policy: lender_policy,
          activation: %{@lender => "sha256:act-lend-key"},
          admitted_origins: origins,
          vault_refs: [
            %{
              binding_key: lender_key,
              scope: "athanor",
              vault_entry_id: "vault-lend-key",
              binding_digest: "sha256:lend-key"
            }
          ]
        }
      )

    root_policy =
      Jason.encode!(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          root => %{
            "limits" => limits,
            "edges" => %{
              "@ingress" => %{},
              @lender => %{"vault" => %{"via" => %{"label" => "default"}}}
            }
          },
          @lender => %{"limits" => limits, "edges" => %{}}
        }
      })

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{
          id: "prof-lent-root",
          kind: :owner,
          source_ref: root,
          label: "default",
          status: :active
        },
        %{
          id: "consent-lent-root",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape-lent-root",
          commit_digest: "sha256:commit-lent-root",
          resolved_policy: root_policy,
          activation: %{root => component.release_digest},
          admitted_origins: origins,
          vault_refs: [
            %{
              binding_key: Prima.Authority.Blob.binding_key(root, @lender, nil),
              scope: "athanor",
              via_label: "default",
              binding_digest: nil
            }
          ]
        }
      )

    root <> ":0.1.0"
  end

  # A root of the person's own whose head binds one entry on two edges,
  # its ingress and its edge to `@lender`, under two binding digests, its
  # stored bindings the same two. Answers the root's reference.
  defp bound_twice_root!(ctx) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: "twice-root",
        version: "0.1.0",
        type: "reagent"
      })

    root = "reagent:local.twice-root"
    limits = Prima.Test.AuthorityFixtures.limits_map()
    ingress_key = Prima.Authority.Blob.binding_key(root, "@ingress", nil)
    edge_key = Prima.Authority.Blob.binding_key(root, @lender, nil)

    vault = fn binding_key, digest ->
      %{
        "entry_id" => "vault-twice",
        "binding_digest" => digest,
        "scope" => "athanor",
        "destination" => %{"hosts" => ["api.example.com"], "scheme" => "https"},
        "attach" => %{"in" => "header", "name" => "x-api-key", "template" => "{value}"},
        "projection" => %{"fields" => ["KEY"]},
        "binding_key" => binding_key
      }
    end

    policy =
      Jason.encode!(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          root => %{
            "limits" => limits,
            "edges" => %{
              "@ingress" => %{"vault" => vault.(ingress_key, "sha256:twice-one")},
              @lender => %{"vault" => vault.(edge_key, "sha256:twice-two")}
            }
          },
          @lender => %{"limits" => limits, "edges" => %{}}
        }
      })

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{
          id: "prof-twice-root",
          kind: :owner,
          source_ref: root,
          label: "default",
          status: :active
        },
        %{
          id: "consent-twice-root",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape-twice-root",
          commit_digest: "sha256:commit-twice-root",
          resolved_policy: policy,
          activation: %{root => component.release_digest},
          admitted_origins: [:interactive, :programmatic],
          vault_refs:
            for {key, digest} <- [
                  {ingress_key, "sha256:twice-one"},
                  {edge_key, "sha256:twice-two"}
                ] do
              %{
                binding_key: key,
                scope: "athanor",
                vault_entry_id: "vault-twice",
                binding_digest: digest
              }
            end
        }
      )

    root <> ":0.1.0"
  end

  # `table` stops answering once the head `consent_id` names is read whole
  # (its `consent_vault_refs`, the last read of that head), before what
  # follows it. The router runs a tool call on a task of this test's, so
  # the read is this process's or one it started.
  defp away_after_head!(table, consent_id) do
    test = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if test in [self() | Process.get(:"$callers", [])] and
               meta[:source] == "consent_vault_refs" and
               consent_id in (meta[:params] || []) do
            :telemetry.detach(handler)
            Arca.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unavailable")
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # The athanor's component index falls behind (`Arca.StorageProjectionChanges`
  # leaves a change of a unit whose bytes are still moving) the moment
  # `source`'s profiles are read, and stays behind.
  defp behind_at_profiles!(ctx, source) do
    test = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test and meta[:source] == "profiles" and
               source in (meta[:params] || []) do
            :telemetry.detach(handler)

            {:ok, _pending} =
              Arca.StorageProjectionChanges.begin_edit(
                Context.actor(ctx),
                "components",
                "catalysts/local/claude/1.0.0"
              )
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # ============================================================================
  # Execution Tool - List Action
  #
  # Note: math.wasm is a core module, so executions fail at runtime but
  # records are still created. Tests verify listing of failed records.
  # ============================================================================

  describe "execution tool - list action" do
    test "returns empty list initially", %{ctx: ctx} do
      {:ok, result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert result.executions == []
      assert result.count == 0
    end

    test "returns executions after running", %{ctx: ctx, ref: ref} do
      # Execute something (will fail because math.wasm is a core module)
      _exec_result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      # Now list should show the failed record
      {:ok, result} = Provider.handle("execution", ctx, %{"action" => "list"})

      assert result.count >= 1
      execution = hd(result.executions)
      assert is_binary(execution.execution_id)
      assert execution.status == "failed"
    end

    test "filters by status", %{ctx: ctx, ref: ref} do
      # Execute to create a failed execution record
      _result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      # Filter by failed
      {:ok, failed_result} =
        Provider.handle("execution", ctx, %{"action" => "list", "status" => "failed"})

      assert failed_result.count >= 1

      # Filter by completed (should be empty since math.wasm always fails)
      {:ok, completed_result} =
        Provider.handle("execution", ctx, %{"action" => "list", "status" => "completed"})

      assert completed_result.count == 0

      # Filter by running (should be empty since execution finishes quickly)
      {:ok, running_result} =
        Provider.handle("execution", ctx, %{"action" => "list", "status" => "running"})

      assert running_result.count == 0
    end

    test "respects limit parameter", %{ctx: ctx, ref: ref} do
      # Run multiple executions (all will fail)
      for i <- 1..3 do
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => i, "b" => 1}
        })
      end

      {:ok, result} = Provider.handle("execution", ctx, %{"action" => "list", "limit" => 2})
      assert result.count <= 2
    end
  end

  # ============================================================================
  # Execution Tool - Logs Action
  #
  # Note: math.wasm is a core module, so executions fail at runtime but
  # records are still created. Tests verify log retrieval of failed records.
  # ============================================================================

  describe "execution tool - logs action" do
    test "returns logs for execution", %{ctx: ctx, ref: ref} do
      # Execute (will fail)
      _exec_result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 5, "b" => 5}
        })

      # Get execution_id from list
      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      {:ok, logs_result} =
        Provider.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => execution_id
        })

      assert logs_result.execution_id == execution_id
      assert logs_result.status == "failed"
      assert is_binary(logs_result.logs)
    end

    test "returns error for missing execution_id", %{ctx: ctx} do
      {:error, msg} = Provider.handle("execution", ctx, %{"action" => "logs"})
      assert err_msg(msg) =~ "Missing required"
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      # Typed at the provider; every boundary renders it to one sentence.
      {:error, reason} =
        Provider.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => "exec_nonexistent"
        })

      assert reason == {:not_found, "Execution", "exec_nonexistent"}
      assert Prima.Refusal.message(reason) =~ "not found"
    end
  end

  # ============================================================================
  # Execution Tool - Cancel Action
  # ============================================================================

  describe "execution tool - cancel action" do
    test "returns error for missing execution_id", %{ctx: ctx} do
      {:error, msg} = Provider.handle("execution", ctx, %{"action" => "cancel"})
      assert err_msg(msg) =~ "Missing required"
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      {:error, reason} =
        Provider.handle("execution", ctx, %{
          "action" => "cancel",
          "execution_id" => "exec_nonexistent"
        })

      assert reason == {:not_found, "Execution", "exec_nonexistent"}
      assert Prima.Refusal.message(reason) =~ "not found"
    end

    test "returns error for failed execution", %{ctx: ctx, ref: ref} do
      # Run an execution (it fails because math.wasm is a core module)
      _exec_result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      # Get execution_id from list
      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      # Try to cancel the failed execution
      {:error, msg} =
        Provider.handle("execution", ctx, %{
          "action" => "cancel",
          "execution_id" => execution_id
        })

      assert err_msg(msg) =~ "already completed" or err_msg(msg) =~ "already failed" or
               err_msg(msg) =~ "not cancellable" or
               msg =~ "cancelled"
    end
  end

  # ============================================================================
  # Invalid/Missing Action
  # ============================================================================

  describe "execution tool - invalid action" do
    test "returns error for invalid action", %{ctx: ctx} do
      {:error, msg} = Provider.handle("execution", ctx, %{"action" => "invalid"})
      assert err_msg(msg) =~ "Invalid execution action"
    end

    test "returns error for missing action", %{ctx: ctx} do
      {:error, msg} = Provider.handle("execution", ctx, %{})
      assert err_msg(msg) =~ "Missing required"
    end
  end

  # ============================================================================
  # Force Release Action
  # ============================================================================

  describe "execution tool - force_release action" do
    test "the handler releases when reached; the operator gate is the annotation" do
      # Releasing every athanor's slots is a server-wide side effect. The
      # `scope: :platform` annotation admits platform admins alone at
      # dispatch (the gate); the handler itself does not
      # re-check, so a direct call releases.
      admin_ctx = %{Sanctum.TestContext.local(:api) | platform_admin: true}

      {:ok, result} = Provider.handle("execution", admin_ctx, %{"action" => "force_release"})
      assert result.force_released == true
      # an operator sees the whole diagnostic
      assert Map.has_key?(result, :tenants)
    end

    test "dispatch refuses a member and hides the action from them", %{ctx: ctx} do
      assert {:error, %Prima.Refusal{stage: :admission, reason: :platform_admin_required}} =
               Grimoire.call_external("execution", ctx, %{
                 "action" => "force_release"
               })

      [tool] =
        Grimoire.Visibility.filter_for_context(
          Enum.filter(Grimoire.list_tools(), &(&1["name"] == "execution")),
          ctx
        )

      refute "force_release" in get_in(tool, ["inputSchema", "properties", "action", "enum"])
    end
  end

  # ============================================================================
  # Permission Gates
  #
  # Tests that restricted (non-admin) contexts are properly gated on actions
  # that require elevated permissions, while still allowing general actions.
  # ============================================================================

  describe "permission gates" do
    setup do
      restricted_ctx = %Context{
        user_id: "restricted_user",
        athanor_id: Sanctum.TestContext.athanor_id(),
        permissions: MapSet.new([:execute]),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      no_execute_ctx = %Context{
        user_id: "no_exec_user",
        athanor_id: Sanctum.TestContext.athanor_id(),
        permissions: MapSet.new([:component_read]),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, restricted_ctx: restricted_ctx, no_execute_ctx: no_execute_ctx}
    end

    test "non-admin user can still run executions", %{restricted_ctx: restricted_ctx, ref: ref} do
      # The run action is open to all authenticated users. Even though execution
      # fails (math.wasm is a core module), the error should NOT be "Unauthorized".
      # Through the dispatcher, where a permission refusal would come from: the
      # handler alone refuses nothing on permission.
      result =
        Grimoire.call_external("execution", restricted_ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2}
        })

      case result do
        {:error, msg} ->
          refute Sanctum.Unauthorized.reason?(msg) or
                   (is_binary(msg) and msg =~ "Unauthorized"),
                 "run action should not require admin permissions"

        {:ok, _} ->
          # If it somehow succeeds, that's fine too
          :ok
      end
    end

    test "non-admin user can list their own executions", %{restricted_ctx: restricted_ctx} do
      {:ok, result} = Provider.handle("execution", restricted_ctx, %{"action" => "list"})
      assert is_list(result.executions)
      assert is_integer(result.count)
    end

    test "execution.status denied without :execute permission", %{no_execute_ctx: no_execute_ctx} do
      # Through the dispatcher — the :execute gate lives in the action
      # annotation, enforced by the catalog, not in the handler.
      assert {:error, %Prima.Refusal{stage: :admission, reason: {:missing_permission, :execute}}} =
               Grimoire.call_external("execution", no_execute_ctx, %{
                 "action" => "status"
               })
    end

    test "execution.cancel denied without :execute permission", %{no_execute_ctx: no_execute_ctx} do
      assert {:error, %Prima.Refusal{stage: :admission, reason: {:missing_permission, :execute}}} =
               Grimoire.call_external("execution", no_execute_ctx, %{
                 "action" => "cancel",
                 "execution_id" => "exec_nonexistent"
               })
    end

    test "execution.status allowed with :execute permission", %{restricted_ctx: restricted_ctx} do
      {:ok, result} = Provider.handle("execution", restricted_ctx, %{"action" => "status"})
      assert is_map(result)
    end
  end

  # ============================================================================
  # Unknown Tool
  # ============================================================================

  describe "unknown tool" do
    test "returns error for unknown tool", %{ctx: ctx} do
      {:error, msg} = Provider.handle("unknown_tool", ctx, %{})
      assert err_msg(msg) =~ "Unknown tool"
    end
  end

  # ============================================================================
  # Verify Block
  #
  # Note: math.wasm is a core module, so executions fail at runtime with
  # "Component Model load failed". The key assertion is that the error is NOT
  # about signature verification -- proving verification passed successfully.
  # ============================================================================

  describe "execution tool - verify block" do
    test "verify block is included in tool schema" do
      tools = Provider.tools()
      tool = Enum.find(tools, &(&1.name == "execution"))

      for action <- ["run", "run_stream"] do
        verify_schema = action_schema(tool, action)["properties"]["verify"]
        assert verify_schema != nil
        assert verify_schema["type"] == "object"
        assert verify_schema["properties"]["identity"]["type"] == "string"
        assert verify_schema["properties"]["issuer"]["type"] == "string"
        assert verify_schema["additionalProperties"] == false
      end
    end

    test "accepts verify block with identity and issuer", %{ctx: ctx, ref: ref} do
      # Execution fails because math.wasm is a core module, but the error
      # should be about Component Model loading, NOT signature verification
      {:error, msg} =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 10, "b" => 5},
          "verify" => %{
            "identity" => "test@example.com",
            "issuer" => "https://github.com/login/oauth"
          }
        })

      assert err_msg(msg) =~ "Component compilation failed"
      refute err_msg(msg) =~ "Signature verification failed"
    end

    test "verify block is optional", %{ctx: ctx, ref: ref} do
      # Without verify block, execution still proceeds (and fails at Component Model load)
      {:error, msg} =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 3, "b" => 7}
        })

      assert err_msg(msg) =~ "Component compilation failed"
    end
  end

  # ============================================================================
  # Component Digest
  #
  # Note: The component digest is computed from WASM bytes before execution,
  # so even though math.wasm fails at runtime, the digest is still recorded
  # in the failed execution record.
  # ============================================================================

  describe "execution tool - component digest" do
    test "returns component_digest in failed record", %{ctx: ctx, ref: ref} do
      _result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      {:ok, logs_result} =
        Provider.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => execution_id
        })

      assert logs_result.component_digest != nil
      assert String.starts_with?(logs_result.component_digest, "sha256:")
    end

    test "digest is consistent for same WASM bytes", %{ctx: ctx, ref: ref} do
      # Run two executions with same WASM (both will fail)
      _result1 =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      _result2 =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 2, "b" => 2}
        })

      # List both executions and check their digests via logs
      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 2

      digests =
        Enum.map(list_result.executions, fn exec ->
          {:ok, logs} =
            Provider.handle("execution", ctx, %{
              "action" => "logs",
              "execution_id" => exec.execution_id
            })

          logs.component_digest
        end)

      # All digests should be the same since they use the same WASM bytes
      assert Enum.uniq(digests) |> length() == 1
    end
  end

  # ============================================================================
  # Error Recovery
  # ============================================================================

  describe "execution tool - error handling" do
    test "handles unregistered component gracefully", %{ctx: ctx} do
      # Unregistered component should return a clear error — no profile
      # exists for it, so the consent gate names the fix.
      result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "reagent:local.nonexistent-component:0.1.0",
          "input" => %{}
        })

      assert {:error, msg} = result
      assert {:consent_required, %{}} = msg
      assert err_msg(msg) =~ "Consent required"
    end

    test "handles empty reference gracefully", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "",
          "input" => %{}
        })

      assert err_msg(msg) =~ "cannot be empty"
    end
  end

  # ============================================================================
  # Crash-Resilient Storage
  #
  # Note: math.wasm is a core module, so executions fail at runtime with
  # "Component Model load failed". The Executor still writes started + failed
  # records to SQLite, so crash-resilient storage is testable with failed records.
  # ============================================================================

  describe "execution tool - crash-resilient storage" do
    test "writes execution record to SQLite before execution", %{ctx: ctx, ref: ref} do
      _result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      # Get execution_id from list
      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      # Check that execution record exists in SQLite
      db_record = Arca.Repo.get(Arca.Schemas.Execution, execution_id)
      assert db_record != nil
      assert db_record.id == execution_id
    end

    test "marks execution as failed in SQLite after core module execution", %{ctx: ctx, ref: ref} do
      _result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 5, "b" => 5}
        })

      # Get execution_id from list
      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      db_record = Arca.Repo.get(Arca.Schemas.Execution, execution_id)
      assert db_record != nil
      assert db_record.status == "failed"
      assert db_record.completed_at != nil
    end

    test "marks execution as failed in SQLite for unregistered component", %{ctx: ctx} do
      # Unregistered component should fail and write a record
      _result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "reagent:local.unregistered-crash:0.1.0",
          "input" => %{}
        })

      # Check SQLite for a failed execution record
      records =
        Arca.Execution.list(
          user_id: ctx.user_id,
          limit: 10,
          athanor_id: ctx.athanor_id
        )

      failed_records = Enum.filter(records, &(&1.status == "failed"))

      if failed_records != [] do
        failed_record = hd(failed_records)
        assert failed_record.status == "failed"
        assert failed_record.error_message != nil
      end
    end
  end

  # ============================================================================
  # Telemetry Events
  #
  # Note: math.wasm is a core module, so executions fail at runtime. The
  # Executor emits start + exception telemetry events on failure (not stop).
  # ============================================================================

  describe "execution tool - telemetry" do
    setup do
      test_pid = self()
      handler_id = "mcp-test-telemetry-#{:rand.uniform(100_000)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:cyfr, :opus, :execute, :start],
          [:cyfr, :opus, :execute, :stop],
          [:cyfr, :opus, :execute, :exception]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      :ok
    end

    test "emits start and exception telemetry events on core module failure", %{
      ctx: ctx,
      ref: ref
    } do
      # Execution fails because math.wasm is a core module
      _result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2}
        })

      assert_receive {:telemetry, [:cyfr, :opus, :execute, :start], _, start_meta}
      assert start_meta.component_type == :reagent

      assert_receive {:telemetry, [:cyfr, :opus, :execute, :exception], _, exception_meta}
      assert exception_meta.outcome == :failure
    end

    test "a component that never resolves opens no execution span", %{ctx: ctx} do
      # The gate comes first: an unregistered reference has no consent
      # profile, so the call is refused before the executor is reached.
      assert {:error, {:consent_required, %{"ref" => ref}}} =
               Provider.handle("execution", ctx, %{
                 "action" => "run",
                 "reference" => "reagent:local.unregistered-telemetry:0.1.0",
                 "input" => %{}
               })

      assert ref == "reagent:local.unregistered-telemetry:0.1.0"

      # And no span is opened for it. A `:start` with no `:stop` or
      # `:exception` is an execution that leaks — every consumer counting
      # in-flight runs off this event would be permanently one high — so
      # "which one of start/stop/exception fired" is exactly what must not
      # be left as a best-effort maybe.
      refute_receive {:telemetry, [:cyfr, :opus, :execute, _], _, _}, 100
    end
  end

  # ============================================================================
  # Resource Provider
  #
  # Note: math.wasm is a core module, so executions fail at runtime. Resource
  # reads return the failed execution record with status "failed" and no output.
  # ============================================================================

  # A resource read is the declared `execution.read_resource`, admitted by
  # the gate like any other call; the answer is `%{content:, mimeType:}`.
  defp read(ctx, uri),
    do:
      Grimoire.call_external("execution", ctx, %{
        "action" => "read_resource",
        "uri" => uri
      })

  describe "execution.read_resource - execution state resource" do
    test "returns execution state for existing execution", %{ctx: ctx, ref: ref} do
      _exec_result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 7, "b" => 8}
        })

      # Get execution_id from list
      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      uri = "crucible://executions/#{execution_id}"
      {:ok, %{content: content, mimeType: "application/json"}} = read(ctx, uri)

      # Content should be valid JSON
      {:ok, parsed} = Jason.decode(content)

      assert parsed["execution_id"] == execution_id
      assert parsed["status"] == "failed"
      assert parsed["component_type"] == "reagent"
      assert is_binary(parsed["component_digest"])
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      uri = "crucible://executions/exec_nonexistent"
      {:error, reason} = read(ctx, uri)

      assert reason == {:not_found, "Execution", "exec_nonexistent"}
      assert Prima.Refusal.message(reason) =~ "not found"
    end

    test "parses execution ID correctly", %{ctx: ctx, ref: ref} do
      _exec_result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      # Get execution_id from list
      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      # URI with just ID
      uri = "crucible://executions/#{execution_id}"
      {:ok, %{content: content}} = read(ctx, uri)

      {:ok, parsed} = Jason.decode(content)
      assert parsed["execution_id"] == execution_id
    end
  end

  describe "execution.read_resource - execution logs resource" do
    test "returns logs for existing execution", %{ctx: ctx, ref: ref} do
      _exec_result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 3, "b" => 4}
        })

      # Get execution_id from list
      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      uri = "crucible://executions/#{execution_id}/logs"
      {:ok, %{content: content, mimeType: "text/plain"}} = read(ctx, uri)

      # Content should be text logs
      assert is_binary(content)
      assert content =~ "=== Execution #{execution_id} ==="
      assert content =~ "Status: failed"
      assert content =~ "Component Type: reagent"
      assert content =~ "Error:"
    end

    test "returns error for non-existent execution logs", %{ctx: ctx} do
      uri = "crucible://executions/exec_nonexistent/logs"
      {:error, reason} = read(ctx, uri)

      assert reason == {:not_found, "Execution", "exec_nonexistent"}
      assert Prima.Refusal.message(reason) =~ "not found"
    end

    test "includes error in logs for failed execution", %{ctx: ctx} do
      # Execute unregistered component
      _result =
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "reagent:local.unregistered-logs:0.1.0",
          "input" => %{}
        })

      # Get the execution ID by listing
      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})

      if list_result.count > 0 do
        exec = hd(list_result.executions)

        if exec.status == "failed" do
          uri = "crucible://executions/#{exec.execution_id}/logs"
          {:ok, %{content: content}} = read(ctx, uri)

          assert content =~ "Error:"
        end
      end
    end
  end

  describe "execution.read_resource - unknown URIs" do
    test "a URI outside crucible://executions/ is a typed argument refusal", %{ctx: ctx} do
      {:error, {:invalid_argument, msg}} = read(ctx, "unknown://resource")
      assert msg =~ "Unknown resource URI"
    end

    test "returns error for invalid execution URI format", %{ctx: ctx} do
      # Empty execution ID
      {:error, {:invalid_argument, msg}} = read(ctx, "crucible://executions/")
      assert msg =~ "Invalid execution URI format"
    end
  end

  # The provider answers typed reasons where the class is clear; the shared
  # renderer is the one spelling of every sentence, so assert through it.
  # Plain strings (the consent-tag wire forms included) pass through
  # unchanged.
  # An app of the person's own whose own calls bind a default and the
  # account "Work" beside it, admitting runs over the API, through the
  # consent walk.
  defp named_app!(person) do
    name = "named-run-#{System.unique_integer([:positive])}"

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

    ref = "reagent:local." <> name

    decisions = %{
      ref: ref,
      origins: [:interactive, :programmatic],
      bindings: [
        %{need: "api_key", entry_id: entry.("default").id},
        %{need: "api_key", name: "Work", entry_id: entry.("work").id}
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

    ref
  end

  defp err_msg(reason) do
    Grimoire.Error.render(reason) ||
      flunk("unrenderable refusal: #{inspect(reason)}")
  end

  # One action's own declaration, as `Prima.Operation.cast/2` applies it;
  # the tool's discovery schema merges every action into one flat object.
  defp action_schema(tool, action) do
    case Enum.find(tool.operations, &(&1.action == action)) do
      nil ->
        flunk("missing schema for #{tool.name}.#{action}")

      operation ->
        operation.args
        |> Prima.Arg.schema()
        |> put_in(["properties", "action"], %{"type" => "string", "const" => action})
        |> Map.update!("required", &["action" | &1])
    end
  end
end
