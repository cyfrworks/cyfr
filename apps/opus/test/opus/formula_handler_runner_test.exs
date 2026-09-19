# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.FormulaHandlerRunnerTest do
  @moduledoc """
  What a formula's host functions (`Opus.FormulaHandler`) do inside its
  runner's VM, which only that VM can see: the telemetry each emits, and
  the processes of the tasks a formula spawns. The formula's functions run
  in the test process with the client of a formula attempt on a scripted
  host (`Opus.Test.ScriptedHost`), which admits each child as CYFR would;
  each child runs as an attempt process of the runner registered in this
  VM (`Opus.Runner`, over a control socket the test holds the service's
  end of), which holds a root of its own at its artifact fetch for the
  whole test.

  What CYFR decides of these host calls, and a formula's tasks run for
  real in a runner of the Opus service, are `Opus.FormulaHandlerTest`'s,
  in CYFR's suite.
  """

  use ExUnit.Case, async: false

  import Opus.Test.Wait

  alias Cyfr.WorkerAuth
  alias Opus.FormulaHandler
  alias Opus.Test.ScriptedHost

  @moduletag :capture_log

  @echo File.read!(Path.expand("../support/test_wasm/echo.wasm", __DIR__))
  @boot "boot_formula_handler_test"
  @runner "runner_formula_test"
  @invoke "cyfr:formula/invoke@0.1.0"
  @child_ref "reagent:local.echo-child:0.1.0"

  setup do
    host = ScriptedHost.start!()

    path =
      Path.join(System.tmp_dir!(), "opus_formula_#{System.unique_integer([:positive])}.sock")

    File.rm(path)
    {:ok, listener} = :socket.open(:local, :stream)
    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)
    {:ok, service} = :socket.open(:local, :stream)
    :ok = :socket.connect(service, %{family: :local, path: path})
    {:ok, runner_end} = :socket.accept(listener)
    {:ok, fd} = :socket.getopt(runner_end, {:otp, :fd})

    on_exit(fn ->
      :socket.close(service)
      :socket.close(runner_end)
      :socket.close(listener)
      File.rm(path)
    end)

    test = self()
    supervisor = :"formula_attempts_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, name: supervisor, strategy: :one_for_one})

    settings = %{
      runner_id: @runner,
      service_id: ScriptedHost.service(),
      boot: @boot,
      host_url: host.url,
      control_fd: fd,
      watchdog_grace_ms: 500
    }

    start_supervised!(
      {Opus.Runner,
       settings: settings,
       supervisor: supervisor,
       name: Opus.Runner,
       halt: fn reason -> send(test, {:halted, reason}) end,
       stop: fn status -> send(test, {:stopped, status}) end}
    )

    # The runner's root, held at its artifact fetch: a runner starts a
    # child only while it runs a subtree.
    Opus.Cache.invalidate({:compiled_component, Cyfr.Digest.sha256(@echo)})
    hold_artifacts!(host)
    root = attempt!(host, component_type: :reagent, digest: Cyfr.Digest.sha256(@echo))

    :ok =
      :socket.send(
        service,
        Cyfr.RunnerControl.encode(%{
          type: :assign,
          assignment: root.assignment,
          input: root.input,
          keys: root.keys
        })
      )

    assert_receive {:held_fetch, _root_fetch}, 10_000
    [{_, root_process, _, _}] = DynamicSupervisor.which_children(supervisor)

    formula =
      attempt!(host,
        component_type: :formula,
        intercepted: ["execution.run", "execution.run_stream"]
      )

    {:ok, host: host, formula: formula, attempts: %{supervisor: supervisor, root: root_process}}
  end

  defp attempt!(host, opts),
    do: ScriptedHost.attempt!(host, [boot: @boot, runner: @runner] ++ opts)

  # Every artifact fetch waits until the test sends it `:go`, telling the
  # test `{:held_fetch, pid}`, and is lost when the test ends first, so the
  # host stops with no request open.
  defp hold_artifacts!(host) do
    test = self()

    ScriptedHost.script(host, "fetch_artifact", fn _args, _caller ->
      ref = Process.monitor(test)
      send(test, {:held_fetch, self()})

      receive do
        :go -> {:ok, Base.encode64(@echo)}
        {:DOWN, ^ref, :process, _, _} -> :drop
      end
    end)
  end

  defp serve_artifacts!(host),
    do: ScriptedHost.script(host, "fetch_artifact", {:ok, Base.encode64(@echo)})

  # The host admits each child the formula asks for as CYFR does: an echo
  # reagent's attempt on this runner's boot, its keys sealed under the
  # formula's attempt's seal key. The test hears `{:admitted, id}` for each.
  defp admit_children!(host, formula) do
    test = self()

    ScriptedHost.script(host, "admit_child", fn %{"input" => input}, _caller ->
      child =
        attempt!(host,
          component_type: :reagent,
          component_ref: @child_ref,
          digest: Cyfr.Digest.sha256(@echo),
          input: input
        )

      {:ok, sealed} = WorkerAuth.seal_attempt_keys(formula.keys.seal, child.keys)
      send(test, {:admitted, child.execution_id})

      {:ok,
       %{
         "assignment" => child.assignment,
         "attempt_keys" => sealed,
         "input" => child.input,
         "secrets" => %{}
       }}
    end)
  end

  defp imports(formula) do
    FormulaHandler.build_formula_imports(formula.client,
      limits: Cyfr.Limits.defaults(:formula),
      intercepted: ["execution.run", "execution.run_stream"]
    )
  end

  defp fun(imports, name), do: elem(imports[@invoke][name], 1)

  defp run_request(input) do
    Jason.encode!(%{
      "tool" => "execution",
      "action" => "run",
      "args" => %{"reference" => @child_ref, "input" => input}
    })
  end

  defp attach_telemetry!(event) do
    test = self()
    handler = "formula-runner-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, measurements, metadata, _config ->
          send(test, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # The attempt processes of the runner's children: every one it runs but
  # its root's.
  defp children(%{supervisor: supervisor, root: root}) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid) and pid != root,
        do: pid
  end

  defp abandoned?(host, execution_id) do
    Enum.any?(
      ScriptedHost.requests(host, "fail"),
      &match?(
        %{args: %{"outcome" => %{"abandoned" => true}}, caller: %{execution_id: ^execution_id}},
        &1
      )
    )
  end

  describe "telemetry" do
    test "a called child's execution.run emits mcp_tool telemetry, ok when it completed", %{
      host: host,
      formula: formula
    } do
      attach_telemetry!([:cyfr, :opus, :mcp_tool, :call])
      admit_children!(host, formula)
      serve_artifacts!(host)

      answer =
        FormulaHandler.execute(run_request(%{"a" => 2}), formula.client,
          limits: Cyfr.Limits.defaults(:formula),
          intercepted: ["execution.run"]
        )

      assert %{"status" => "completed", "output" => %{"a" => 2}} = Jason.decode!(answer)

      assert_receive {[:cyfr, :opus, :mcp_tool, :call], _,
                      %{execution_id: parent, tool_action: "execution.run", status: :ok}},
                     5000

      assert parent == formula.execution_id
    end

    test "a refused call emits mcp_tool telemetry with error status", %{
      host: host,
      formula: formula
    } do
      attach_telemetry!([:cyfr, :opus, :mcp_tool, :call])

      ScriptedHost.script(
        host,
        "admit_child",
        {:error, {:guest_error, "tool_denied", "Denied by edge_only"}}
      )

      answer =
        FormulaHandler.execute(run_request(%{}), formula.client,
          limits: Cyfr.Limits.defaults(:formula),
          intercepted: ["execution.run"]
        )

      assert %{"error" => %{"type" => "tool_denied"}} = Jason.decode!(answer)
      assert_receive {[:cyfr, :opus, :mcp_tool, :call], _, %{status: :error}}, 5000
    end

    test "a catalog tool call emits mcp_tool telemetry with its action and duration", %{
      host: host,
      formula: formula
    } do
      attach_telemetry!([:cyfr, :opus, :mcp_tool, :call])
      ScriptedHost.script(host, "tool_call", {:ok, %{"results" => []}})

      request =
        Jason.encode!(%{
          "tool" => "component",
          "action" => "search",
          "args" => %{"query" => "test"}
        })

      answer =
        FormulaHandler.execute(request, formula.client, limits: Cyfr.Limits.defaults(:formula))

      assert %{"status" => "completed", "output" => %{"results" => []}} = Jason.decode!(answer)

      assert [%{args: %{"name" => "component", "args" => %{"action" => "search"}}}] =
               ScriptedHost.requests(host, "tool_call")

      assert_receive {[:cyfr, :opus, :mcp_tool, :call], %{duration_ms: duration},
                      %{execution_id: parent, tool_action: "component.search", status: :ok}},
                     5000

      assert is_integer(duration)
      assert parent == formula.execution_id
    end

    test "a catalog tool call CYFR denies emits mcp_tool telemetry with error status", %{
      host: host,
      formula: formula
    } do
      attach_telemetry!([:cyfr, :opus, :mcp_tool, :call])

      ScriptedHost.script(
        host,
        "tool_call",
        {:error, {:guest_error, "tool_denied", "Denied by chain authority"}}
      )

      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{}})

      answer =
        FormulaHandler.execute(request, formula.client, limits: Cyfr.Limits.defaults(:formula))

      assert %{"error" => %{"type" => "tool_denied"}} = Jason.decode!(answer)

      assert_receive {[:cyfr, :opus, :mcp_tool, :call], _,
                      %{tool_action: "component.search", status: :error}},
                     5000
    end

    test "a spawn emits formula spawn telemetry naming its parent and task", %{
      host: host,
      formula: formula
    } do
      attach_telemetry!([:cyfr, :opus, :formula, :spawn])
      admit_children!(host, formula)
      serve_artifacts!(host)
      {imports, tracker} = imports(formula)

      assert %{"task_id" => "task_1"} =
               Jason.decode!(fun(imports, "spawn").(run_request(%{"a" => 1})))

      assert_receive {[:cyfr, :opus, :formula, :spawn], _, metadata}, 5000
      assert metadata.parent_execution_id == formula.execution_id
      assert metadata.task_id == "task_1"

      FormulaHandler.cleanup_registry(tracker)
    end

    test "a cancel emits formula cancel telemetry naming its parent and task", %{
      host: host,
      formula: formula
    } do
      attach_telemetry!([:cyfr, :opus, :formula, :cancel])
      admit_children!(host, formula)
      {imports, tracker} = imports(formula)

      %{"task_id" => task_id} = Jason.decode!(fun(imports, "spawn").(run_request(%{})))
      assert_receive {:held_fetch, _fetch}, 10_000

      fun(imports, "cancel").(task_id)

      assert_receive {[:cyfr, :opus, :formula, :cancel], _, metadata}, 5000
      assert metadata.parent_execution_id == formula.execution_id
      assert metadata.task_id == task_id

      FormulaHandler.cleanup_registry(tracker)
    end
  end

  describe "a streamed child" do
    test "run_stream starts its child in the runner with nothing waiting, and answers its stream at once",
         %{host: host, formula: formula, attempts: attempts} do
      admit_children!(host, formula)

      request =
        Jason.encode!(%{
          "tool" => "execution",
          "action" => "run_stream",
          "args" => %{"reference" => @child_ref, "input" => %{"streamed" => true}}
        })

      answer =
        FormulaHandler.execute(request, formula.client,
          limits: Cyfr.Limits.defaults(:formula),
          intercepted: ["execution.run_stream"]
        )

      assert_receive {:admitted, child_id}
      assert [%{args: %{"guest_fn" => "spawn"}}] = ScriptedHost.requests(host, "admit_child")

      # Same success envelope the legacy dispatch wraps results in, while
      # the child is still held at its artifact fetch.
      assert %{
               "status" => "completed",
               "output" => %{"execution_id" => ^child_id, "stream_url" => stream_url}
             } = Jason.decode!(answer)

      assert stream_url == "/api/executions/#{child_id}/events"
      assert_receive {:held_fetch, fetch}, 10_000
      assert [_child] = children(attempts)

      send(fetch, :go)
      wait_until(fn -> children(attempts) == [] end, 10_000)

      assert [%{caller: %{execution_id: ^child_id}, args: %{"outcome" => outcome}}] =
               ScriptedHost.requests(host, "complete")

      assert outcome["output"] == %{"streamed" => true}
    end
  end

  describe "a formula's tasks in its runner" do
    test "a spawned task's child runs in the runner and its result is awaited", %{
      host: host,
      formula: formula
    } do
      admit_children!(host, formula)
      serve_artifacts!(host)
      {imports, tracker} = imports(formula)

      %{"task_id" => task_id} = Jason.decode!(fun(imports, "spawn").(run_request(%{"n" => 1})))
      assert_receive {:admitted, child_id}

      assert %{"task_id" => ^task_id, "status" => "completed", "output" => %{"n" => 1}} =
               Jason.decode!(fun(imports, "await").(task_id))

      assert [%{caller: %{execution_id: ^child_id, runner: @runner}}] =
               ScriptedHost.requests(host, "complete")

      FormulaHandler.cleanup_registry(tracker)
    end

    test "spawned tasks are awaited all together", %{host: host, formula: formula} do
      admit_children!(host, formula)
      serve_artifacts!(host)
      {imports, tracker} = imports(formula)

      ids =
        for n <- 1..2,
            do: Jason.decode!(fun(imports, "spawn").(run_request(%{"n" => n})))["task_id"]

      assert %{"count" => 2, "results" => results} =
               Jason.decode!(fun(imports, "await-all").(Jason.encode!(%{"task_ids" => ids})))

      assert Enum.sort(for(item <- results, do: item["task_id"])) == Enum.sort(ids)
      assert Enum.all?(results, &(&1["status"] == "completed"))

      FormulaHandler.cleanup_registry(tracker)
    end

    test "poll reports the spawned task's own terminal status once it ended", %{
      host: host,
      formula: formula
    } do
      admit_children!(host, formula)
      serve_artifacts!(host)
      {imports, tracker} = imports(formula)
      poll = fun(imports, "poll")

      task_id = Jason.decode!(fun(imports, "spawn").(run_request(%{"n" => 1})))["task_id"]

      wait_until(
        fn -> Jason.decode!(poll.(task_id))["status"] != "pending" end,
        30_000,
        "the spawned task to leave 'pending'"
      )

      assert %{"task_id" => ^task_id, "status" => "completed", "output" => %{"n" => 1}} =
               Jason.decode!(poll.(task_id))

      FormulaHandler.cleanup_registry(tracker)
    end

    test "cancelling a task stops its child's attempt process, which closes abandoned", %{
      host: host,
      formula: formula,
      attempts: attempts
    } do
      admit_children!(host, formula)
      {imports, tracker} = imports(formula)

      task_id = Jason.decode!(fun(imports, "spawn").(run_request(%{})))["task_id"]
      assert_receive {:admitted, child_id}
      assert_receive {:held_fetch, _fetch}, 10_000
      assert [_child] = children(attempts)

      assert %{"cancelled" => true, "task_id" => ^task_id} =
               Jason.decode!(fun(imports, "cancel").(task_id))

      wait_until(fn -> children(attempts) == [] end, 10_000)
      wait_until(fn -> abandoned?(host, child_id) end, 10_000)

      FormulaHandler.cleanup_registry(tracker)
    end

    test "stopping the tracker stops every child its tasks wait for, each closing abandoned", %{
      host: host,
      formula: formula,
      attempts: attempts
    } do
      admit_children!(host, formula)
      {imports, tracker} = imports(formula)

      for _ <- 1..2,
          do: assert(%{"task_id" => _} = Jason.decode!(fun(imports, "spawn").(run_request(%{}))))

      child_ids =
        for _ <- 1..2 do
          assert_receive {:admitted, child_id}
          assert_receive {:held_fetch, _fetch}, 10_000
          child_id
        end

      assert length(children(attempts)) == 2

      FormulaHandler.cleanup_registry(tracker)

      wait_until(fn -> children(attempts) == [] end, 10_000)
      for child_id <- child_ids, do: wait_until(fn -> abandoned?(host, child_id) end, 10_000)
    end
  end
end
