# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/formula_host_helper.exs", __DIR__)
Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Opus.FormulaHandlerTest do
  @moduledoc """
  What CYFR decides of the host calls a formula's host functions make
  (`Opus.FormulaHandler`, run here as a formula's runner runs it, over the
  suite's wire with the keys of an attached formula attempt): parsing,
  dispatch through the catalog, invoke and in-chain plane containment, the
  events a formula emits, and setup refusals. A child it admits is handed
  to the runner the attempt presents, which is no process and starts
  nothing, so its admission is what is asserted, at the wire.

  A formula's tasks run for real: the `nested-probe` formula, in a runner
  of its own, spawns children that run in its runner, awaits them, polls
  them, cancels them or leaves them to end with it, and answers what each
  host function answered it. What only a runner's VM can see of a
  formula's host functions (their telemetry, their tasks' processes) is
  `Opus.FormulaHandlerRunnerTest`'s, in Opus's own suite.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Opus.FormulaHandler
  alias Opus.Test.FormulaHost
  alias Opus.Test.NestedExecution, as: Probe
  alias Cyfr.Authority
  alias Cyfr.Authority.Blob
  alias Cyfr.Test.TwoServices
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag :capture_log

  @math_wasm_path Path.join(__DIR__, "../../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"
  @test_node "reagent:local.test-math"
  @fh_node "formula:local.fh-root"
  @act_fh Cyfr.Digest.sha256("act-fh")
  @probe_node "formula:local.nested-probe"

  setup tags do
    test_path = Path.join(System.tmp_dir!(), "formula_handler_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    ctx = Sanctum.TestContext.local()

    wasm_bytes = File.read!(@math_wasm_path)

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, wasm_bytes, %{
        name: "test-math",
        version: "0.1.0",
        type: "reagent",
        description: "Test math component"
      })

    on_exit(fn ->
      Cyfr.Slots.forgive_unreaped(Cyfr.Execution.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, ctx: ctx, test_path: test_path, ref: @test_ref}
  end

  # The host client of a formula's attached attempt under `authority`,
  # whose events go on `stream_id` when given.
  defp host!(ctx, authority, opts \\ []) do
    FormulaHost.attached!(
      [
        ctx: ctx,
        authority: authority,
        component_ref: @fh_node <> ":0.1.0",
        activation_digest: @act_fh
      ] ++ opts
    ).host
  end

  # Helper to build MCP-format requests
  defp mcp_request(tool, action, args \\ %{}) do
    Jason.encode!(%{"tool" => tool, "action" => action, "args" => args})
  end

  defp execution_run_request(reference, input, type \\ "reagent") do
    mcp_request("execution", "run", %{
      "reference" => reference,
      "input" => input,
      "type" => type
    })
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

  defp execute(json, host, auth), do: FormulaHandler.execute(json, host, FormulaHost.opts(auth))

  defp imports(host, auth),
    do: FormulaHandler.build_formula_imports(host, FormulaHost.opts(auth))

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

    {:ok, assignment} = Cyfr.Assignment.read(token)
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
        {:root,
         Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), input, execution_id: root_id)}
      )
    end)
  end

  # Run the probe as a root taking `steps`, and answer its execution id and
  # what the host answered each step. With `hold_children: true`, each
  # child it spawns is held at the catalog call it makes, on the suite's
  # wire, until the test ends.
  defp run_steps!(ctx, steps, opts \\ []) do
    root_id = Cyfr.UUID7.execution_id()
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

  defp children(parent_id),
    do: Arca.Repo.all(from(e in Arca.Execution, where: e.parent_execution_id == ^parent_id))

  defp decoded(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> decoded
      _ -> output
    end
  end

  defp decoded(output), do: output

  # ============================================================================
  # build_formula_imports/2
  # ============================================================================

  describe "build_formula_imports/2" do
    test "returns {imports, tracker_pid} tuple with all eight functions", %{ctx: ctx} do
      host = host!(ctx, Authority.zero())

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(host, limits: Cyfr.Limits.defaults(:formula))

      assert is_map(imports)
      assert is_pid(tracker_pid)
      assert Process.alive?(tracker_pid)
      assert Map.has_key?(imports, "cyfr:formula/invoke@0.1.0")

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]

      for func_name <- [
            "call",
            "spawn",
            "await",
            "await-all",
            "await-any",
            "poll",
            "cancel",
            "emit"
          ] do
        assert Map.has_key?(invoke_ns, func_name), "Missing function: #{func_name}"
        assert {:fn, func} = invoke_ns[func_name]
        assert is_function(func, 1), "#{func_name} is not arity-1"
      end

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "works without limits (defaults)", %{ctx: ctx} do
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(host!(ctx, Authority.zero()))

      assert is_map(imports)
      assert is_pid(tracker_pid)

      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # execute/3 - JSON Parsing (MCP format)
  # ============================================================================

  describe "execute/3 - JSON parsing" do
    setup %{ctx: ctx} do
      {:ok, host: host!(ctx, Authority.zero())}
    end

    test "returns error for invalid JSON", %{host: host} do
      parsed = Jason.decode!(FormulaHandler.execute("not json", host))
      assert parsed["error"]["type"] == "invalid_json"
      assert parsed["error"]["message"] =~ "Invalid JSON"
    end

    test "returns error when tool is missing", %{host: host} do
      parsed = Jason.decode!(FormulaHandler.execute(Jason.encode!(%{"action" => "run"}), host))
      assert parsed["error"]["type"] == "invalid_request"
      assert parsed["error"]["message"] =~ "tool"
    end

    test "returns error when action is missing", %{host: host} do
      parsed =
        Jason.decode!(FormulaHandler.execute(Jason.encode!(%{"tool" => "execution"}), host))

      assert parsed["error"]["type"] == "invalid_request"
    end

    test "returns error when args is not a map", %{host: host} do
      json = Jason.encode!(%{"tool" => "execution", "action" => "run", "args" => "string"})
      parsed = Jason.decode!(FormulaHandler.execute(json, host))
      assert parsed["error"]["type"] == "invalid_request"
      assert parsed["error"]["message"] =~ "args"
    end
  end

  # ============================================================================
  # execute/3 - MCP Dispatch
  # ============================================================================

  describe "execute/3 - MCP dispatch" do
    test "dispatches execution.run through the chain on a consented edge", %{ctx: ctx, ref: ref} do
      auth = authority(edges: %{@test_node => %{}})
      host = host!(ctx, auth)

      parsed =
        Jason.decode!(execute(execution_run_request(ref, %{"a" => 5, "b" => 3}), host, auth))

      # The edge decision admitted the child, bound to the target's node;
      # the runner this attempt presents starts nothing, so the call ends
      # as the dispatch error of a child not started, never as a denial.
      assert %{authority: %{cursor: {:bound, @test_node}}} = admitted!(host)
      assert parsed["error"]["type"] == "dispatch_error"
      refute parsed["error"]["type"] == "tool_denied"
    end

    test "dispatches to non-execution tools", %{ctx: ctx} do
      auth = authority(tools: ["tools.list"])
      parsed = Jason.decode!(execute(mcp_request("tools", "list"), host!(ctx, auth), auth))

      assert parsed["status"] == "completed"
      assert is_map(parsed["output"])
    end

    test "returns dispatch error for unregistered component", %{ctx: ctx} do
      # Dynamic dispatch to a ref the registry cannot resolve keeps its
      # error shape: the zero child is refused at its admission.
      auth = authority()
      json = execution_run_request("reagent:local.missing:0.1.0", %{"a" => 1})
      parsed = Jason.decode!(execute(json, host!(ctx, auth), auth))

      assert parsed["error"]["type"] == "dispatch_error"
      assert parsed["error"]["message"] =~ "resolve"
    end

    test "an intercepted action is the host's only when the assignment names it", %{ctx: ctx} do
      auth = authority(tools: ["execution.run"])
      host = host!(ctx, auth)
      json = execution_run_request("reagent:local.missing:0.1.0", %{})

      # Not intercepted, execution.run is a catalog call, which a running
      # chain cannot make.
      parsed =
        Jason.decode!(
          FormulaHandler.execute(json, host, limits: Authority.limits(auth), intercepted: [])
        )

      assert parsed["error"]["type"] == "dispatch_error"
      assert parsed["error"]["message"] =~ "not reachable from a running chain"
    end
  end

  # ============================================================================
  # execute/3 - Invoke containment
  # ============================================================================

  describe "execute/3 - invoke containment" do
    test "an edge_only authority denies an off-edge invoke", %{ctx: ctx, ref: ref} do
      auth = authority(invoke_mode: :edge_only)

      parsed =
        Jason.decode!(execute(execution_run_request(ref, %{"a" => 1}), host!(ctx, auth), auth))

      assert parsed["error"]["type"] == "tool_denied"
      assert parsed["error"]["message"] =~ "edge_only"
    end

    test "an open_inert authority runs an off-edge invoke inert, not denied", %{
      ctx: ctx,
      ref: ref
    } do
      auth = authority()
      host = host!(ctx, auth)

      parsed = Jason.decode!(execute(execution_run_request(ref, %{"a" => 1}), host, auth))

      # The zero child carries nothing but is admitted, not refused.
      assert %{authority: %{cursor: :unbound, policy: :none}} = admitted!(host)
      refute match?(%{"error" => %{"type" => "tool_denied"}}, parsed)
    end
  end

  # ============================================================================
  # execute/3 - In-chain plane containment
  # ============================================================================

  describe "execute/3 - in-chain plane containment" do
    # session/key/policy mutation actions are external-plane only: the
    # reachability gate refuses them from a running chain before any
    # grant is consulted, so even a consented edge cannot open them.

    test "blocks an external-only tool with no grant", %{ctx: ctx} do
      auth = authority()
      json = mcp_request("session", "login", %{"user" => "admin"})
      parsed = Jason.decode!(execute(json, host!(ctx, auth), auth))

      assert parsed["error"]["type"] == "dispatch_error"
      assert parsed["error"]["message"] =~ "not reachable from a running chain"
    end

    test "blocks an external-only tool even when the edge grants it", %{ctx: ctx} do
      auth = authority(tools: ["vault.create"])
      json = mcp_request("vault", "create", %{"name" => "n", "fields" => %{}})
      parsed = Jason.decode!(execute(json, host!(ctx, auth), auth))

      assert parsed["error"]["type"] == "dispatch_error"
      assert parsed["error"]["message"] =~ "not reachable from a running chain"
    end

    test "blocks key.create in-chain regardless of grants", %{ctx: ctx} do
      auth = authority(tools: ["key.create"])
      parsed = Jason.decode!(execute(mcp_request("key", "create", %{}), host!(ctx, auth), auth))

      assert parsed["error"]["type"] == "dispatch_error"
      assert parsed["error"]["message"] =~ "not reachable from a running chain"
    end

    test "allows granted in-chain tools through normally", %{ctx: ctx} do
      auth = authority(tools: ["tools.list"])
      parsed = Jason.decode!(execute(mcp_request("tools", "list"), host!(ctx, auth), auth))

      refute match?(%{"error" => _}, parsed)
      assert parsed["status"] == "completed"
    end
  end

  # ============================================================================
  # spawn - in-chain plane containment
  # ============================================================================

  describe "spawn - in-chain plane containment" do
    test "a spawned external-only tool call is refused in the task result", %{ctx: ctx} do
      # vault.delete is external-plane only: even a consented edge grant
      # cannot make credential mutation reachable from a running chain.
      auth = authority(tools: ["vault.delete"])
      {imports, tracker_pid} = imports(host!(ctx, auth), auth)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)
      await_fn = elem(invoke_ns["await"], 1)

      spawn_result = spawn_fn.(mcp_request("vault", "delete", %{"id" => "vlt_test"}))
      %{"task_id" => task_id} = Jason.decode!(spawn_result)

      awaited = Jason.decode!(await_fn.(task_id))

      assert awaited["status"] == "error"
      assert awaited["error"]["type"] == "dispatch_error"
      assert awaited["error"]["message"] =~ "not reachable from a running chain"

      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # spawn, await-all, poll and cancel: what CYFR decides before any task
  # ============================================================================

  describe "spawn, await-all, poll and cancel before any task" do
    test "spawn returns error when request is invalid", %{ctx: ctx} do
      auth = authority()
      {imports, tracker_pid} = imports(host!(ctx, auth), auth)

      spawn_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["spawn"], 1)

      parsed = Jason.decode!(spawn_fn.("not valid json"))
      assert parsed["error"]["type"] == "invalid_json"

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "spawn denies an off-edge invoke under edge_only, synchronously", %{ctx: ctx, ref: ref} do
      auth = authority(invoke_mode: :edge_only)
      {imports, tracker_pid} = imports(host!(ctx, auth), auth)

      spawn_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["spawn"], 1)

      # CYFR decides before any task exists: a denied spawn consumes no task
      # slot and no budget.
      parsed = Jason.decode!(spawn_fn.(execution_run_request(ref, %{"a" => 1, "b" => 2})))
      assert parsed["error"]["type"] == "tool_denied"
      assert Sanctum.Authority.budget(auth).in_flight == 0
      assert Opus.AsyncTracker.room?(tracker_pid)

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "spawn under a full tracker admits no child", %{ctx: ctx, ref: ref} do
      auth = authority(edges: %{@test_node => %{}})
      host = host!(ctx, auth)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(host,
          limits: %{Authority.limits(auth) | max_concurrent_tasks: 0},
          intercepted: FormulaHost.intercepted()
        )

      spawn_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["spawn"], 1)

      parsed = Jason.decode!(spawn_fn.(execution_run_request(ref, %{})))
      assert parsed["error"]["type"] == "resource_limit"
      assert Sanctum.Authority.budget(auth).in_flight == 0

      assert Arca.Repo.all(
               from(e in Arca.Execution,
                 where: e.parent_execution_id == ^host.execution_id,
                 select: e.id
               )
             ) == []

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "await-all returns error for invalid JSON", %{ctx: ctx} do
      auth = authority()
      {imports, tracker_pid} = imports(host!(ctx, auth), auth)

      await_all_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["await-all"], 1)

      parsed = Jason.decode!(await_all_fn.("not json"))
      assert parsed["error"]["type"] == "invalid_json"

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "poll returns error for unknown task_id", %{ctx: ctx} do
      auth = authority()
      {imports, tracker_pid} = imports(host!(ctx, auth), auth)

      poll_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["poll"], 1)

      parsed = Jason.decode!(poll_fn.("nonexistent_task"))
      assert parsed["error"]["type"] == "invalid_request"
      assert parsed["error"]["message"] =~ "Unknown"

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "cancel returns error for unknown task_id", %{ctx: ctx} do
      auth = authority()
      {imports, tracker_pid} = imports(host!(ctx, auth), auth)

      cancel_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["cancel"], 1)

      parsed = Jason.decode!(cancel_fn.("nonexistent_task"))

      assert parsed["error"]["type"] == "invalid_request"
      assert parsed["error"]["message"] =~ "Unknown"

      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # A formula's tasks, run in a runner
  # ============================================================================

  describe "a formula's tasks, run in its runner" do
    setup %{ctx: ctx} do
      previous = Application.get_env(:cyfr, :consent_source)
      Application.put_env(:cyfr, :consent_source, Source.DB)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:cyfr, :consent_source, previous),
          else: Application.delete_env(:cyfr, :consent_source)
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
      wait_until(fn -> Sanctum.Authority.budget(authority).in_flight == 0 end)
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
      wait_until(fn -> Arca.Repo.get!(Arca.Execution, child.id).status == "failed" end)
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
      wait_until(fn -> Arca.Repo.get!(Arca.Execution, child.id).status == "failed" end)
      wait_until(fn -> Sanctum.Authority.budget(authority).in_flight == 0 end)
      wait_until(fn -> Cyfr.Execution.Attempt.whereis(child.id) == nil end)
    end

    test "tasks a formula leaves running end with it, and CYFR reclaims their holds", %{ctx: ctx} do
      root_id = Cyfr.UUID7.execution_id()
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
      assert Sanctum.Authority.budget(authority).in_flight == 2
      assert length(children(root_id)) == 2

      TwoServices.release!(root_call)
      assert [_first, _second, _called] = results!(root_id)

      for child <- children(root_id) do
        wait_until(fn -> Arca.Repo.get!(Arca.Execution, child.id).status == "failed" end)
        wait_until(fn -> Cyfr.Execution.Attempt.whereis(child.id) == nil end)
      end

      wait_until(fn -> Sanctum.Authority.budget(authority).in_flight == 0 end)
    end
  end

  # ============================================================================
  # cleanup_registry/1
  # ============================================================================

  describe "cleanup_registry/1" do
    test "stops tracker and returns :ok", %{ctx: ctx} do
      {_imports, tracker_pid} =
        FormulaHandler.build_formula_imports(host!(ctx, Authority.zero()),
          limits: Cyfr.Limits.defaults(:formula)
        )

      assert Process.alive?(tracker_pid)
      assert :ok == FormulaHandler.cleanup_registry(tracker_pid)
      refute Process.alive?(tracker_pid)
    end

    test "returns :ok for non-pid values" do
      assert :ok == FormulaHandler.cleanup_registry(nil)
      assert :ok == FormulaHandler.cleanup_registry("some_string")
    end

    test "a tracker that is already gone is not an error" do
      {:ok, pid} = Opus.AsyncTracker.start_link([])
      # Unlink before killing: the tracker is linked to whoever started it,
      # which here is the test process.
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      refute Process.alive?(pid)

      assert FormulaHandler.cleanup_registry(pid) == :ok
    end
  end

  # ============================================================================
  # emit integration
  # ============================================================================

  describe "emit integration" do
    test "emit returns ok with sequence number", %{ctx: ctx} do
      host = host!(ctx, Authority.zero(), stream_id: "exec_emit_test")

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(host, limits: Cyfr.Limits.defaults(:formula))

      emit_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["emit"], 1)

      parsed = Jason.decode!(emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1})))

      assert parsed["ok"] == true
      # No durable event yet: the delta rides prefix 0.
      assert parsed["sequence"] == "0.1"

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit sequence increments across calls", %{ctx: ctx} do
      host = host!(ctx, Authority.zero(), stream_id: "exec_emit_seq")

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(host, limits: Cyfr.Limits.defaults(:formula))

      emit_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["emit"], 1)

      r1 = Jason.decode!(emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1})))
      r2 = Jason.decode!(emit_fn.(Jason.encode!(%{"kind" => "text_delta", "content" => "hi"})))
      r3 = Jason.decode!(emit_fn.(Jason.encode!(%{"kind" => "tool_use", "tool" => "read"})))

      assert r1["sequence"] == "0.1"
      assert r2["sequence"] == "0.2"
      assert r3["sequence"] == "0.3"

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit handles invalid JSON gracefully", %{ctx: ctx} do
      host = host!(ctx, Authority.zero(), stream_id: "exec_emit_bad")

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(host, limits: Cyfr.Limits.defaults(:formula))

      emit_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["emit"], 1)

      parsed = Jason.decode!(emit_fn.("not valid json"))

      # Under an authority a malformed emit is refused loudly, not
      # swallowed: the guest gets a typed error envelope.
      assert parsed["error"]["type"] == "invalid_request"

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit delivers events via PubSub", %{ctx: ctx} do
      execution_id = "exec_emit_pubsub_#{:rand.uniform(100_000)}"
      host = host!(ctx, Authority.zero(), stream_id: execution_id)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(host, limits: Cyfr.Limits.defaults(:formula))

      Cyfr.Execution.Events.subscribe(execution_id, ctx)

      emit_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["emit"], 1)
      emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      assert_receive {:execution_event, event}, 2000
      assert event.type == "emit"
      assert event.execution_id == execution_id
      assert event.sequence == "0.1"
      assert event.data["kind"] == "turn_start"
      assert event.data["turn"] == 1

      Cyfr.Execution.Events.unsubscribe(execution_id, ctx)
      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit masks dispensed secrets before the event leaves the runtime", %{ctx: ctx} do
      execution_id = "exec_emit_mask_#{:rand.uniform(100_000)}"

      host =
        host!(ctx, Authority.zero(),
          stream_id: execution_id,
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-super-secret-value"}}
        )

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(host, limits: Cyfr.Limits.defaults(:formula))

      Cyfr.Execution.Events.subscribe(execution_id, ctx)

      emit_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["emit"], 1)

      emit_fn.(
        Jason.encode!(%{"kind" => "text_delta", "content" => "key is sk-super-secret-value"})
      )

      assert_receive {:execution_event, event}, 2000
      assert event.data["content"] == "key is [REDACTED]"
      refute inspect(event) =~ "sk-super-secret-value"

      Cyfr.Execution.Events.unsubscribe(execution_id, ctx)
      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit buffers events for replay via since/2", %{ctx: ctx} do
      execution_id = "exec_emit_buffer_#{:rand.uniform(100_000)}"
      host = host!(ctx, Authority.zero(), stream_id: execution_id)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(host, limits: Cyfr.Limits.defaults(:formula))

      emit_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["emit"], 1)

      emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))
      emit_fn.(Jason.encode!(%{"kind" => "text_delta", "content" => "hello"}))
      emit_fn.(Jason.encode!(%{"kind" => "tool_use", "tool" => "read_file"}))

      # Flush pending buffer writes before reading
      Cyfr.Execution.Events.flush(execution_id)

      events = Cyfr.Execution.Events.since(execution_id, {0, 0}, ctx.athanor_id)
      assert length(events) == 3
      assert Enum.map(events, & &1.sequence) == ["0.1", "0.2", "0.3"]
      assert Enum.map(events, & &1.data["kind"]) == ["turn_start", "text_delta", "tool_use"]

      events_after_1 = Cyfr.Execution.Events.since(execution_id, {0, 1}, ctx.athanor_id)
      assert length(events_after_1) == 2
      assert Enum.map(events_after_1, & &1.sequence) == ["0.2", "0.3"]

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    # CYFR's own telemetry: the host emits it as it pushes the event to the
    # stream.
    test "emit telemetry fires on each emit", %{ctx: ctx} do
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

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(host, limits: Cyfr.Limits.defaults(:formula))

      emit_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["emit"], 1)
      emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      assert_receive {:emitted, %{execution_id: ^execution_id}, %{sequence: "0.1"}}, 2000

      FormulaHandler.cleanup_registry(tracker_pid)
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

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(host, limits: Cyfr.Limits.defaults(:formula))

      Cyfr.Execution.Events.subscribe(root_id, ctx)
      Cyfr.Execution.Events.subscribe(host.execution_id, ctx)

      emit_fn = elem(imports["cyfr:formula/invoke@0.1.0"]["emit"], 1)
      emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      assert_receive {:execution_event, event}, 2000
      assert event.execution_id == root_id
      assert event.data["kind"] == "turn_start"

      refute_receive {:execution_event, _}, 100

      Cyfr.Execution.Events.unsubscribe(root_id, ctx)
      Cyfr.Execution.Events.unsubscribe(host.execution_id, ctx)
      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # Cyfr.Execution.Events durable events
  # ============================================================================

  describe "Cyfr.Execution.Events durable events" do
    test "a published lifecycle row reaches subscribers with its number", %{ctx: ctx} do
      execution_id = "exec_terminal_#{:rand.uniform(100_000)}"

      Cyfr.Execution.Events.subscribe(execution_id, ctx)

      :ok =
        Cyfr.Execution.Events.publish(execution_id, ctx, "execution.completed", 7, %{
          "status" => "completed",
          "duration_ms" => 1234
        })

      assert_receive {:execution_event, event}, 2000
      assert event.type == "execution.completed"
      assert event.execution_id == execution_id
      assert event.sequence == "7"
      assert event.durable == 7
      assert event.data["status"] == "completed"
      assert event.data["duration_ms"] == 1234

      Cyfr.Execution.Events.unsubscribe(execution_id, ctx)
    end
  end

  # ============================================================================
  # encode_error/2
  # ============================================================================

  describe "encode_error/2" do
    test "encodes error as JSON" do
      parsed = Jason.decode!(FormulaHandler.encode_error(:test_error, "something failed"))

      assert parsed["error"]["type"] == "test_error"
      assert parsed["error"]["message"] == "something failed"
    end
  end

  # ============================================================================
  # execute/3 - Setup error remediation
  # ============================================================================

  describe "execute/3 - setup error remediation" do
    test "an unsatisfiable consented dependency is setup_required with remediation", %{ctx: ctx} do
      # The consent names an edge to a component the installed world
      # cannot resolve: the bound invoke refuses with a remediation the
      # surface can act on, instead of a bare dispatch failure.
      auth = authority(edges: %{"catalyst:local.no-policy-test" => %{}})

      json =
        mcp_request("execution", "run", %{
          "reference" => "catalyst:local.no-policy-test:0.1.0",
          "input" => %{},
          "type" => "catalyst"
        })

      parsed = Jason.decode!(execute(json, host!(ctx, auth), auth))

      assert parsed["error"]["type"] == "setup_required"

      # One remediation shape on the wire, whichever dispatch path failed —
      # Cyfr.Remediation's, the one component-guide documents.
      remediation = parsed["error"]["remediation"]
      assert remediation["component_ref"] == "catalyst:local.no-policy-test:0.1.0"
      assert remediation["setup_command"] =~ "profile grant"
      assert is_list(remediation["issues"])
    end

    test "normal errors remain unchanged when not a setup issue", %{ctx: ctx} do
      auth = authority()

      # A missing component off the consent graph gives dispatch_error,
      # not setup_required
      json =
        mcp_request("execution", "run", %{
          "reference" => "reagent:local.does-not-exist:0.1.0",
          "input" => %{}
        })

      parsed = Jason.decode!(execute(json, host!(ctx, auth), auth))

      assert parsed["error"]["type"] == "dispatch_error"
      refute Map.has_key?(parsed["error"], "remediation")
    end
  end
end
