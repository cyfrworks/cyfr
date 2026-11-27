# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/formula_host_helper.exs", __DIR__)
Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Cyfr.FormulaHostCallsTest do
  @moduledoc """
  What CYFR decides of the host calls a formula's host functions make,
  each posted as its runner's worker service posts it, over the suite's
  wire with the keys of an attached formula attempt: a child's admission
  through the catalog's edges, invoke and in-chain plane containment, the
  accounts a child names, the events a formula emits, and setup
  refusals. A child it admits is handed to the runner the attempt
  presents, which is no process and starts nothing, so its admission is
  what is asserted, and the test gives it back.

  A formula's tasks run for real: the `nested-probe` formula, in a runner
  of its own, spawns children that run in its runner, awaits them, polls
  them, cancels them or leaves them to end with it, and answers what each
  host function answered it; and a formula whose calls name accounts its
  dependency's edge binds has each child's request reach a loopback
  upstream with that account's credential.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Cyfr.Test.{AttemptFixtures, FormulaHost, HostCaller, TwoServices}
  alias Locus.Runtime.Test.NestedExecution, as: Probe
  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Consent.{Bootstrap}

  @moduletag :capture_log

  @test_ref "reagent:local.test-math:0.1.0"
  @test_node "reagent:local.test-math"
  @fh_node "formula:local.fh-root"
  @act_fh Prima.Digest.sha256("act-fh")
  @probe_node "formula:local.nested-probe"

  # The hostile probe that sends its input as its one request, naming its
  # need `api_key` as the request's connection (`Locus.Runtime.AttachedFetchTest`).
  @attached_probe Path.expand(
                    "../../../../locus/test/support/runtime/test_wasm/hostile/attached_header_probe.wasm",
                    __DIR__
                  )
  @account_secrets %{
    "default" => "sk-account-default-5e1c",
    "Work" => "sk-account-work-8a3f",
    "Home" => "sk-account-home-2d7b"
  }

  defmodule Upstream do
    @moduledoc """
    A loopback upstream: every request it receives is told to the test,
    with its path and headers, and answered.
    """
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{parent: parent}) do
      send(parent, {:upstream, %{path: conn.request_path, headers: conn.req_headers}})
      send_resp(conn, 200, "hello from upstream")
    end
  end

  setup tags do
    test_path = Path.join(System.tmp_dir!(), "formula_handler_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    ctx = Sanctum.TestContext.local(:api)

    wasm_bytes = Cyfr.Test.Guests.wasm(:reagent)

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, wasm_bytes, %{
        name: "test-math",
        version: "0.1.0",
        type: "reagent",
        description: "Test math component"
      })

    on_exit(fn ->
      Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    Sanctum.TestContext.ready!(ctx.athanor_id)
    {:ok, ctx: ctx, test_path: test_path, ref: @test_ref}
  end

  # A formula's attempt attached under `authority`, whose events go on
  # `stream_id` when given.
  defp host!(ctx, authority, opts \\ []) do
    FormulaHost.attached!(
      [
        ctx: ctx,
        authority: authority,
        component_ref: @fh_node <> ":0.1.0",
        activation_digest: @act_fh
      ] ++ opts
    )
  end

  defp limits_map do
    %{
      "timeout" => "1m",
      "max_memory_bytes" => 67_108_864,
      "max_request_size" => 1_048_576,
      "max_response_size" => 5_242_880,
      "rate_limit" => %{"requests" => 100, "window" => "1m"},
      "max_concurrent_tasks" => 10,
      "batch_timeout" => "5m"
    }
  end

  # A root authority bound at @fh_node. `tools` grants ride the ingress
  # edge; `edges` are the consented invoke targets; `invoke_mode`
  # distinguishes inert dynamic dispatch from edge_only containment.
  defp authority(opts \\ []) do
    edges = Keyword.get(opts, :edges, %{})
    tools = Keyword.get(opts, :tools, [])
    invoke_mode = Keyword.get(opts, :invoke_mode, :open_inert)

    extra_nodes =
      edges
      |> Map.keys()
      |> Map.new(fn target -> {target, %{"limits" => limits_map(), "edges" => %{}}} end)

    blob_map = %{
      "canonical" => "jcs-1",
      "nodes" =>
        Map.merge(
          %{
            @fh_node => %{
              "limits" => limits_map(),
              "edges" => Map.merge(%{"@ingress" => %{"tools" => tools}}, edges)
            }
          },
          extra_nodes
        )
    }

    {:ok, blob} = Blob.parse(blob_map)

    profile = %{
      profile_id: "prof-fh",
      consent_id: "consent-fh",
      source_ref: @fh_node,
      kind: if(invoke_mode == :edge_only, do: :public, else: :owner),
      invoke_mode: invoke_mode,
      activation: %{@fh_node => @act_fh}
    }

    {:ok, auth} =
      Authority.root(profile, blob, ceiling: Sanctum.Policy.Ceiling.platform_ceiling())

    auth
  end

  # A child of `host`'s attempt made with `guest_fn` on `reference`, with
  # `input` and the call's other `args`.
  defp admit(host, guest_fn, reference, input, args \\ %{}),
    do: FormulaHost.admit_child(host, reference, guest_fn, Map.put(args, "input", input))

  # A child CYFR admitted is handed to the runner the attempt presents,
  # which is no process: it gives the child back, as a runner that cannot
  # start one does, which closes it failed and releases what it held.
  defp release!(host, {:ok, admitted}) do
    child = HostCaller.child(host, admitted)

    assert {:ok, true} =
             FormulaHost.call(host, :release_child, %{"execution_id" => child.execution_id})

    assert %{status: "failed"} = Arca.Repo.get!(Arca.Schemas.Execution, child.execution_id)
    child
  end

  # The event `event` (JSON text) emitted by `host`'s attempt, and CYFR's
  # reply to it.
  defp emit(host, event) do
    delta = AttemptFixtures.delta(host, event)
    assert {:ok, [reply]} = FormulaHost.call(host, :push_deltas, %{"deltas" => [delta]})
    Jason.decode!(reply)
  end

  @not_reachable "not reachable from a running chain"

  # The one child CYFR admitted for `host`'s attempt, as the answer to its
  # admission crossed the suite's wire: its execution and the authority
  # handed to the runner that would start it.
  defp admitted!(host) do
    parent_id = host.execution_id

    [token] =
      for %{
            callback: :admit_child,
            fields: %{execution_id: ^parent_id},
            answer: %{"ok" => %{"assignment" => token}}
          } <- TwoServices.calls(),
          do: token

    {:ok, assignment} = Prima.Assignment.read(token)
    {:ok, authority} = Authority.from_wire(assignment.authority)
    %{execution_id: assignment.execution_id, authority: authority}
  end

  # The probe run as a root whose guest takes `steps` in order, in a
  # process of its own that sends `{:root, result}` when it ends.
  defp start_steps(ctx, root_id, steps) do
    test_pid = self()
    input = %{"op" => "steps", "steps" => steps}

    spawn(fn ->
      send(
        test_pid,
        {:root, Opus.run_root(ctx, :default, Probe.probe_ref(), input, execution_id: root_id)}
      )
    end)
  end

  # Run the probe as a root taking `steps`, and answer its execution id and
  # what the host answered each step. With `hold_children: true`, each
  # child it spawns is held at the catalog call it makes, on the suite's
  # wire, until the test ends.
  defp run_steps!(ctx, steps, opts \\ []) do
    root_id = Prima.UUID7.execution_id()
    if Keyword.get(opts, :hold_children, false), do: hold_children!(root_id)
    start_steps(ctx, root_id, steps)
    {root_id, results!(root_id)}
  end

  # What the host answered each step of the root `root_id`, once it ended.
  defp results!(root_id) do
    assert_receive {:root, {:ok, result}}, 60_000
    assert result.status == :completed, "root #{root_id}: #{inspect(result)}"
    assert %{"op" => "steps", "results" => results} = decoded(result.output)
    results
  end

  # Each child of `parent_id` is held at the catalog call it makes: the
  # test receives `{:held, id, conn}` for each.
  defp hold_children!(parent_id) do
    TwoServices.hold!(:tool_call, fn row, _call ->
      row != nil and row.parent_execution_id == parent_id
    end)
  end

  defp probe_request(input) do
    %{
      "tool" => "execution",
      "action" => "run",
      "args" => %{"reference" => Probe.probe_ref(), "input" => input, "type" => "formula"}
    }
  end

  # `ref`'s owner grant through the consent walk, as a person makes it,
  # admitting runs over the API, its own calls binding no account.
  defp grant_programmatic!(ref) do
    person = Sanctum.TestContext.local(:prism)
    decisions = %{ref: ref}
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

    :ok
  end

  defp children(parent_id),
    do:
      Arca.Repo.all(from(e in Arca.Schemas.Execution, where: e.parent_execution_id == ^parent_id))

  defp decoded(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> decoded
      _ -> output
    end
  end

  defp decoded(output), do: output

  # ============================================================================
  # A child of the formula
  # ============================================================================

  describe "a child of the formula" do
    test "is admitted on a consented edge, bound to the target's node", %{ctx: ctx, ref: ref} do
      auth = authority(edges: %{@test_node => %{}})
      host = host!(ctx, auth)

      answer = admit(host, "call", ref, %{"a" => 5, "b" => 3})
      assert {:ok, _admitted} = answer
      assert %{authority: %{cursor: {:bound, @test_node}}} = admitted!(host)
      release!(host, answer)
    end

    test "of a component the registry cannot resolve is refused at its admission", %{ctx: ctx} do
      # Dynamic dispatch to a ref the registry cannot resolve keeps its
      # error shape: the zero child is refused at its admission.
      host = host!(ctx, authority())

      assert {:error, "guest_error",
              %{
                "type" => "dispatch_error",
                "message" => "Component not found: reagent:local.missing:0.1.0"
              }} = admit(host, "call", "reagent:local.missing:0.1.0", %{"a" => 1})

      assert children(host.execution_id) == []
    end

    test "is no catalog call: execution.run is not reachable from a running chain", %{ctx: ctx} do
      host = host!(ctx, authority(tools: ["execution.run"]))

      assert {:error, "guest_error", %{"type" => "dispatch_error", "message" => message}} =
               FormulaHost.tool_call(host, "execution", "run", %{
                 "reference" => "reagent:local.missing:0.1.0",
                 "input" => %{}
               })

      assert message =~ @not_reachable
    end
  end

  # ============================================================================
  # Invoke containment
  # ============================================================================

  describe "invoke containment" do
    test "an edge_only authority denies an off-edge invoke, called or spawned, holding nothing",
         %{ctx: ctx, ref: ref} do
      auth = authority(invoke_mode: :edge_only)
      host = host!(ctx, auth)
      denied = "Invocation denied: " <> Prima.Authority.Transition.deny_message(:edge_only)

      for guest_fn <- ["call", "spawn"] do
        assert {:error, "guest_error", %{"type" => "tool_denied", "message" => ^denied}} =
                 admit(host, guest_fn, ref, %{"a" => 1, "b" => 2})
      end

      assert Sanctum.TestContext.invoke_budget(auth).in_flight == 0
      assert children(host.execution_id) == []
    end

    test "an open_inert authority admits an off-edge invoke inert, not denied", %{
      ctx: ctx,
      ref: ref
    } do
      host = host!(ctx, authority())

      answer = admit(host, "call", ref, %{"a" => 1})
      assert {:ok, _admitted} = answer

      # The zero child carries nothing but is admitted, not refused.
      assert %{authority: %{cursor: :unbound, policy: :none}} = admitted!(host)
      release!(host, answer)
    end
  end

  # ============================================================================
  # A child naming an account
  # ============================================================================

  describe "a child naming an account" do
    test "a call and a spawn naming an account their edge does not bind are answered " <>
           "connection_not_granted, and no default stands in for it",
         %{ctx: ctx, ref: ref} do
      not_bound = Prima.Refusal.message(:connection_not_granted)

      # The edge to the target binds no account at all, and the formula's
      # dynamic dispatch to a target no edge names has none to pick.
      for {auth, target} <- [
            {authority(edges: %{@test_node => %{}}), ref},
            {authority(), "reagent:local.elsewhere:0.1.0"}
          ] do
        host = host!(ctx, auth)

        for guest_fn <- ["call", "spawn"] do
          assert {:error, "guest_error",
                  %{"type" => "connection_not_granted", "message" => ^not_bound}} =
                   admit(host, guest_fn, target, %{"a" => 1}, %{"connection" => "Work"})
        end

        assert children(host.execution_id) == []
      end
    end

    test "a connection that is no account's name is refused as the request's error", %{
      ctx: ctx,
      ref: ref
    } do
      host = host!(ctx, authority(edges: %{@test_node => %{}}))

      for connection <- ["", "work|home", "line\nbreak"] do
        assert {:error, "guest_error", %{"type" => "invalid_request", "message" => message}} =
                 admit(host, "call", ref, %{}, %{"connection" => connection})

        assert message =~ "connection"
      end

      assert children(host.execution_id) == []
    end
  end

  describe "execution.run from outside a chain" do
    test "a run naming an account its profile's ingress lacks is refused setup required " <>
           "before anything runs, and one with no profile is asked for its consent",
         %{ctx: ctx, ref: ref} do
      # The account a call names is no resource the operation declares.
      assert {:ok, %{resource: nil}} = Sanctum.Catalog.action_declaration("execution.run")

      before = Arca.Repo.aggregate(Arca.Schemas.Execution, :count)
      named = %{"reference" => ref, "input" => %{"a" => 1}, "connection" => "Work"}

      # No profile roots the reference: the consent signal, as a run naming
      # no account meets it.
      assert Sanctum.Gate.call_external("execution", ctx, Map.put(named, "action", "run")) ==
               {:error, {:consent_required, %{cause: :no_grant, ref: "reagent:local.test-math"}}}

      # Granted, for runs over the API, with no account on its own calls:
      # the name is a grant to make, never run under the default.
      grant_programmatic!(@test_node)

      assert {:error, refused} =
               Sanctum.Gate.call_external("execution", ctx, Map.put(named, "action", "run"))

      assert %Prima.Refusal{class: :setup_required, reason: :connection_not_granted} =
               Prima.Refusal.classify(refused)

      # A stream declares no connection, and is refused naming it.
      assert {:error, %Prima.Refusal{class: :invalid_argument, message: message}} =
               Sanctum.Gate.call_external(
                 "execution",
                 ctx,
                 Map.put(named, "action", "run_stream")
               )

      assert message =~ "connection"
      assert Arca.Repo.aggregate(Arca.Schemas.Execution, :count) == before
    end
  end

  # ============================================================================
  # In-chain plane containment
  # ============================================================================

  describe "in-chain plane containment" do
    # session/key/policy mutation actions are external-plane only: the
    # reachability gate refuses them from a running chain before any
    # grant is consulted, so even a consented edge cannot open them.

    test "blocks an external-only tool with no grant", %{ctx: ctx} do
      host = host!(ctx, authority())

      assert {:error, "guest_error", %{"type" => "dispatch_error", "message" => message}} =
               FormulaHost.tool_call(host, "session", "logout")

      assert message =~ @not_reachable
    end

    test "blocks an external-only tool even when the edge grants it", %{ctx: ctx} do
      host = host!(ctx, authority(tools: ["vault.create"]))

      assert {:error, "guest_error", %{"type" => "dispatch_error", "message" => message}} =
               FormulaHost.tool_call(host, "vault", "create", %{"name" => "n", "fields" => %{}})

      assert message =~ @not_reachable
    end

    test "blocks key.create in-chain regardless of grants", %{ctx: ctx} do
      host = host!(ctx, authority(tools: ["key.create"]))

      assert {:error, "guest_error", %{"type" => "dispatch_error", "message" => message}} =
               FormulaHost.tool_call(host, "key", "create")

      assert message =~ @not_reachable
    end

    test "a spawned external-only tool call is refused as a called one is", %{ctx: ctx} do
      # vault.delete is external-plane only: even a consented edge grant
      # cannot make credential mutation reachable from a running chain.
      host = host!(ctx, authority(tools: ["vault.delete"]))

      assert {:error, "guest_error", %{"type" => "dispatch_error", "message" => message}} =
               FormulaHost.tool_call(host, "vault", "delete", %{"id" => "vlt_test"}, "spawn")

      assert message =~ @not_reachable
    end

    test "allows granted in-chain tools through to the catalog", %{ctx: ctx} do
      host = host!(ctx, authority(tools: ["tools.list"]))

      assert {:ok, output} = FormulaHost.tool_call(host, "tools", "list")
      assert is_map(output)
    end
  end

  # ============================================================================
  # A formula's tasks, run in a runner
  # ============================================================================

  describe "a formula's tasks, run in its runner" do
    setup %{ctx: ctx} do
      on_exit(fn ->
        nil
      end)

      :ok = Probe.publish_probe!(ctx)
      {:ok, %{minted: minted}} = Bootstrap.run(ctx)
      assert @probe_node in minted
      :ok
    end

    test "a spawned task is awaited for its child's result, and the hold it took goes back", %{
      ctx: ctx
    } do
      {root_id, [spawned, awaited]} =
        run_steps!(ctx, [%{"spawn" => probe_request(%{"op" => "echo"})}, %{"await" => 0}])

      %{"task_id" => task_id} = Jason.decode!(spawned)

      assert %{"task_id" => ^task_id, "status" => "completed", "output" => output} =
               Jason.decode!(awaited)

      assert %{"op" => "echo"} = decoded(output)

      authority = TwoServices.entered(root_id)
      wait_until(fn -> Sanctum.TestContext.invoke_budget(authority).in_flight == 0 end)
      assert [%{status: "completed"}] = children(root_id)
    end

    test "spawned tasks are awaited all together", %{ctx: ctx} do
      {root_id, [first, second, awaited]} =
        run_steps!(ctx, [
          %{"spawn" => probe_request(%{"op" => "echo", "n" => 1})},
          %{"spawn" => probe_request(%{"op" => "echo", "n" => 2})},
          %{"await_all" => [0, 1]}
        ])

      ids = for raw <- [first, second], do: Jason.decode!(raw)["task_id"]
      assert %{"count" => 2, "results" => results} = Jason.decode!(awaited)
      assert Enum.sort(for(item <- results, do: item["task_id"])) == Enum.sort(ids)
      assert Enum.all?(results, &(&1["status"] == "completed"))
      assert length(children(root_id)) == 2
    end

    test "poll reports a spawned task pending while its child runs", %{ctx: ctx} do
      {root_id, [spawned, polled]} =
        run_steps!(ctx, [%{"spawn" => probe_request(Probe.held_input())}, %{"poll" => 0}],
          hold_children: true
        )

      assert %{"task_id" => _} = Jason.decode!(spawned)
      assert %{"status" => "pending"} = Jason.decode!(polled)

      [child] = children(root_id)
      wait_until(fn -> Arca.Repo.get!(Arca.Schemas.Execution, child.id).status == "failed" end)
    end

    test "cancelling a spawned child's task stops it and gives back what it held", %{ctx: ctx} do
      {root_id, [spawned, cancelled]} =
        run_steps!(ctx, [%{"spawn" => probe_request(Probe.held_input())}, %{"cancel" => 0}],
          hold_children: true
        )

      task_id = Jason.decode!(spawned)["task_id"]
      assert %{"cancelled" => true, "task_id" => ^task_id} = Jason.decode!(cancelled)

      authority = TwoServices.entered(root_id)
      [child] = children(root_id)
      wait_until(fn -> Arca.Repo.get!(Arca.Schemas.Execution, child.id).status == "failed" end)
      wait_until(fn -> Sanctum.TestContext.invoke_budget(authority).in_flight == 0 end)
      wait_until(fn -> Opus.Attempt.whereis(child.id) == nil end)
    end

    test "tasks a formula leaves running end with it, and CYFR reclaims their holds", %{ctx: ctx} do
      root_id = Prima.UUID7.execution_id()
      hold_children!(root_id)
      TwoServices.hold!(:tool_call, root_id, once: true)

      # The formula spawns two children and makes a catalog call of its own,
      # held until both children are held at theirs.
      start_steps(ctx, root_id, [
        %{"spawn" => probe_request(Probe.held_input())},
        %{"spawn" => probe_request(Probe.held_input())},
        %{"call" => Probe.held_input()["request"]}
      ])

      held = for _ <- 1..3, do: assert_receive({:held, _id, _conn}, 30_000)
      [{:held, ^root_id, root_call}] = for {:held, ^root_id, _} = call <- held, do: call

      authority = TwoServices.entered(root_id)
      assert Sanctum.TestContext.invoke_budget(authority).in_flight == 2
      assert length(children(root_id)) == 2

      TwoServices.release!(root_call)
      assert [_first, _second, _called] = results!(root_id)

      for child <- children(root_id) do
        wait_until(fn -> Arca.Repo.get!(Arca.Schemas.Execution, child.id).status == "failed" end)
        wait_until(fn -> Opus.Attempt.whereis(child.id) == nil end)
      end

      wait_until(fn -> Sanctum.TestContext.invoke_budget(authority).in_flight == 0 end)
    end

    @tag timeout: 180_000
    test "a real formula runs two named-account children with distinct upstream credentials" do
      {person, _user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
      port = upstream!()
      probe = publish_attached_probe!(person)
      app = publish_account_app!(person, probe)

      entries =
        Map.new(@account_secrets, fn {name, secret} -> {name, account!(person, port, secret)} end)

      # The accounts are granted through the consent walk: the edge's
      # default and two named accounts beside it, each its own selection.
      selections =
        for {name, entry} <- entries do
          selection = %{dep: probe, entry_id: entry.id}
          if name == "default", do: selection, else: Map.put(selection, :name, name)
        end

      grant_accounts!(person, app, selections)

      call = fn connection ->
        args = %{
          "reference" => probe <> ":1.0.0",
          "input" => %{
            "connection" => "api_key",
            "method" => "GET",
            "url" => "http://127.0.0.1:#{port}/hello",
            "headers" => %{"accept" => "text/plain"}
          }
        }

        args = if connection, do: Map.put(args, "connection", connection), else: args
        %{"call" => %{"tool" => "execution", "action" => "run", "args" => args}}
      end

      input = %{
        "op" => "steps",
        "steps" => [call.("Work"), call.("Home"), call.(nil), call.("Elsewhere")]
      }

      assert {:ok, %{status: :completed, output: output}} =
               Opus.run_root(person, :default, app <> ":1.0.0", input, [])

      assert %{"op" => "steps", "results" => [work, home, default, elsewhere]} = decoded(output)

      for raw <- [work, home, default] do
        assert %{"output" => %{"status" => 200, "body" => "hello from upstream"}} =
                 Jason.decode!(raw)
      end

      # An account the edge does not bind is a grant to make, and no default
      # stands in for it: no fourth request reaches the upstream.
      assert %{"error" => %{"type" => "connection_not_granted", "message" => message}} =
               Jason.decode!(elsewhere)

      assert message == Prima.Refusal.message(:connection_not_granted)

      # Each child's one request reached the upstream with its own account's
      # key, attached by CYFR, in the order the formula called.
      assert for(_ <- 1..3, do: upstream_key!()) ==
               Enum.map(["Work", "Home", "default"], &Map.fetch!(@account_secrets, &1))

      refute_received {:upstream, _request}
    end
  end

  # The loopback upstream's port, for this test.
  defp upstream! do
    upstream =
      start_supervised!(
        {Bandit,
         plug: {Upstream, %{parent: self()}},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(upstream)
    port
  end

  # The `x-api-key` the upstream's next request carried.
  defp upstream_key! do
    receive do
      {:upstream, %{path: "/hello", headers: headers}} ->
        [key] = for {"x-api-key", value} <- headers, do: value
        key
    after
      10_000 -> flunk("the upstream received nothing")
    end
  end

  # The attached probe, published as a component of the person's own whose
  # need `api_key` is attached to its request as an `x-api-key` header.
  defp publish_attached_probe!(ctx) do
    name = "account-probe-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "catalyst",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:upstream.test",
          "reason" => "to call the upstream with your key",
          "fields" => ["KEY"],
          "attach" => %{"in" => "header", "name" => "x-api-key", "template" => "{value}"},
          "hosts" => ["127.0.0.1"]
        }
      },
      "caps" => %{
        "egress" => %{
          "domains" => ["127.0.0.1"],
          "methods" => ["GET"],
          "schemes" => ["http"],
          "private_ips" => ["127.0.0.1"]
        }
      }
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@attached_probe), %{
        name: name,
        version: "1.0.0",
        type: "catalyst",
        manifest: Jason.encode!(manifest)
      })

    "catalyst:local." <> name
  end

  # An app of the person's own whose formula, the nested probe's bytes,
  # calls `probe` as its one dependency.
  defp publish_account_app!(ctx, probe) do
    name = "account-app-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "formula",
      "caps" => %{"tools" => ["execution.run"]},
      "dependencies" => %{"static" => [%{"ref" => probe}]}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(Probe.wasm_path()), %{
        name: name,
        version: "1.0.0",
        type: "formula",
        manifest: Jason.encode!(manifest)
      })

    "formula:local." <> name
  end

  # An attach-only entry of the probe's provider holding `secret`, bound
  # for the upstream.
  defp account!(ctx, port, secret) do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "account-#{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: "upstream.test",
        fields: %{"KEY" => secret},
        destination: %{
          "hosts" => ["127.0.0.1"],
          "scheme" => "http",
          "port" => port,
          "methods" => ["GET"]
        }
      })

    entry
  end

  # `ref`'s owner consent with `selections` on its dependency's edge,
  # through the consent walk.
  defp grant_accounts!(ctx, ref, selections) do
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, selections: selections}
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, %{profile_id: _profile_id}} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })
  end

  # ============================================================================
  # Emit
  # ============================================================================

  describe "emit" do
    test "a reply is ok with its sequence number", %{ctx: ctx} do
      # A stream id of its own: the sequence a stream starts at belongs to the
      # VM, so the expected first sequence holds only for an id no other test takes.
      stream = "exec_emit_test_#{System.unique_integer([:positive])}"
      host = host!(ctx, Authority.zero(), stream_id: stream)

      parsed = emit(host, Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      assert parsed["ok"] == true
      # No durable event yet: the delta rides prefix 0.
      assert parsed["sequence"] == "0.1"
    end

    test "the sequence increments across emits", %{ctx: ctx} do
      stream = "exec_emit_seq_#{System.unique_integer([:positive])}"
      host = host!(ctx, Authority.zero(), stream_id: stream)

      r1 = emit(host, Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))
      r2 = emit(host, Jason.encode!(%{"kind" => "text_delta", "content" => "hi"}))
      r3 = emit(host, Jason.encode!(%{"kind" => "tool_use", "tool" => "read"}))

      assert r1["sequence"] == "0.1"
      assert r2["sequence"] == "0.2"
      assert r3["sequence"] == "0.3"
    end

    test "an event that is not JSON is refused, not swallowed", %{ctx: ctx} do
      host = host!(ctx, Authority.zero(), stream_id: "exec_emit_bad")

      # Under an authority a malformed emit is refused loudly: the guest
      # gets a typed error.
      assert emit(host, "not valid json")["error"]["type"] == "invalid_request"
    end

    test "an event is delivered via PubSub", %{ctx: ctx} do
      execution_id = "exec_emit_pubsub_#{:rand.uniform(100_000)}"
      host = host!(ctx, Authority.zero(), stream_id: execution_id)

      Opus.Events.subscribe(execution_id, ctx)
      emit(host, Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      assert_receive %Cyfr.Bus.ExecutionEvent{} = event, 2000
      assert event.type == "emit"
      assert event.execution_id == execution_id
      assert event.sequence == "0.1"
      assert event.data["kind"] == "turn_start"
      assert event.data["turn"] == 1

      Opus.Events.unsubscribe(execution_id, ctx)
    end

    test "an event is masked of dispensed secrets before it is delivered", %{ctx: ctx} do
      execution_id = "exec_emit_mask_#{:rand.uniform(100_000)}"

      host =
        host!(ctx, Authority.zero(),
          stream_id: execution_id,
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-super-secret-value"}}
        )

      Opus.Events.subscribe(execution_id, ctx)

      emit(
        host,
        Jason.encode!(%{"kind" => "text_delta", "content" => "key is sk-super-secret-value"})
      )

      assert_receive %Cyfr.Bus.ExecutionEvent{} = event, 2000
      assert event.data["content"] == "key is [REDACTED]"
      refute inspect(event) =~ "sk-super-secret-value"

      Opus.Events.unsubscribe(execution_id, ctx)
    end

    test "events are buffered for replay via since/2", %{ctx: ctx} do
      execution_id = "exec_emit_buffer_#{:rand.uniform(100_000)}"
      host = host!(ctx, Authority.zero(), stream_id: execution_id)

      emit(host, Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))
      emit(host, Jason.encode!(%{"kind" => "text_delta", "content" => "hello"}))
      emit(host, Jason.encode!(%{"kind" => "tool_use", "tool" => "read_file"}))

      events = Opus.Events.since(execution_id, {0, 0}, ctx.athanor_id)
      assert length(events) == 3
      assert Enum.map(events, & &1.sequence) == ["0.1", "0.2", "0.3"]
      assert Enum.map(events, & &1.data["kind"]) == ["turn_start", "text_delta", "tool_use"]

      events_after_1 = Opus.Events.since(execution_id, {0, 1}, ctx.athanor_id)
      assert length(events_after_1) == 2
      assert Enum.map(events_after_1, & &1.sequence) == ["0.2", "0.3"]
    end

    # CYFR's own telemetry: the host emits it as it pushes the event to the
    # stream.
    test "telemetry fires on each emit", %{ctx: ctx} do
      test_pid = self()
      execution_id = "exec_emit_telem_#{:rand.uniform(100_000)}"
      handler = "test-formula-emit-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :opus, :emit],
          fn _event, measurements, metadata, _config ->
            send(test_pid, {:emitted, metadata, measurements})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      host = host!(ctx, Authority.zero(), stream_id: execution_id)
      emit(host, Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      assert_receive {:emitted, %{execution_id: ^execution_id}, %{sequence: "0.1"}}, 2000
    end
  end

  # ============================================================================
  # emit routes to the stream its attempt is opened on
  # ============================================================================

  describe "emit routes to the stream its attempt is opened on" do
    test "a formula's attempt on its root delivers there, not to the formula's own stream",
         %{ctx: ctx} do
      root_id = "exec_root_#{:rand.uniform(100_000)}"
      host = host!(ctx, Authority.zero(), stream_id: root_id)

      Opus.Events.subscribe(root_id, ctx)
      Opus.Events.subscribe(host.execution_id, ctx)

      emit(host, Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      assert_receive %Cyfr.Bus.ExecutionEvent{} = event, 2000
      assert event.execution_id == root_id
      assert event.data["kind"] == "turn_start"

      refute_receive %Cyfr.Bus.ExecutionEvent{}, 100

      Opus.Events.unsubscribe(root_id, ctx)
      Opus.Events.unsubscribe(host.execution_id, ctx)
    end
  end

  # ============================================================================
  # Opus.Events durable events
  # ============================================================================

  describe "Opus.Events durable events" do
    test "a published lifecycle row reaches subscribers with its number", %{ctx: ctx} do
      execution_id = "exec_terminal_#{:rand.uniform(100_000)}"

      Opus.Events.subscribe(execution_id, ctx)

      :ok =
        Opus.Events.publish(execution_id, ctx, "execution.completed", 7, %{
          "status" => "completed",
          "duration_ms" => 1234
        })

      assert_receive %Cyfr.Bus.ExecutionEvent{} = event, 2000
      assert event.type == "execution.completed"
      assert event.execution_id == execution_id
      assert event.sequence == "7"
      assert event.durable == 7
      assert event.data["status"] == "completed"
      assert event.data["duration_ms"] == 1234

      Opus.Events.unsubscribe(execution_id, ctx)
    end
  end

  # ============================================================================
  # Setup error remediation
  # ============================================================================

  describe "setup error remediation" do
    test "an unsatisfiable consented dependency is setup_required with remediation", %{ctx: ctx} do
      # The consent names an edge to a component the installed world
      # cannot resolve: the bound invoke refuses with a remediation the
      # surface can act on, instead of a bare dispatch failure.
      host = host!(ctx, authority(edges: %{"catalyst:local.no-policy-test" => %{}}))

      assert {:error, "guest_error", %{"type" => "setup_required", "remediation" => remediation}} =
               admit(host, "call", "catalyst:local.no-policy-test:0.1.0", %{})

      # One remediation shape on the wire, whichever dispatch path failed —
      # Prima.Remediation's, the one component-guide documents.
      assert remediation["component_ref"] == "catalyst:local.no-policy-test:0.1.0"

      assert Enum.sort(Map.keys(remediation)) ==
               ["component_ref", "issues", "message", "profile_id"]

      assert is_list(remediation["issues"])
    end

    test "normal errors carry no remediation when not a setup issue", %{ctx: ctx} do
      host = host!(ctx, authority())

      # A missing component off the consent graph gives dispatch_error,
      # not setup_required.
      assert {:error, "guest_error", %{"type" => "dispatch_error"} = refusal} =
               admit(host, "call", "reagent:local.does-not-exist:0.1.0", %{})

      refute Map.has_key?(refusal, "remediation")
    end
  end
end
