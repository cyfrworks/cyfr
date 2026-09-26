# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.BackendTest do
  @moduledoc """
  One backend over a launcher, end to end with the probe
  (`fixtures/probe.mjs`, a stdio MCP server in Node) through the test
  environment's `Locus.DirectLauncher`: ready once the handshake lists its
  two tools; a call answered; the owner's secret masked in a result and
  in the stderr tail; the backend's own request answered and never taken
  for a call's answer; a stdout line past the frame bound killing the
  process, which is started again after its backoff; crashes past the
  window marking it failed, and a failed backend refusing calls in the
  bridge's words; an idle backend keeping its tools and woken by the next
  call, concurrent calls sharing one start; a stop with a grace. Against
  `Locus.Test.FakeKeeper` through `Locus.Keeper`: the spawn a backend asks
  for is in the pool `backends`, its argv the command under `/bin/sh -c`,
  its environment the definition's block alone. The probe needs `node`
  on PATH; its cases are tagged `:requires_node`.
  """

  use ExUnit.Case, async: false

  alias Locus.Backends.Backend
  alias Locus.Test.FakeKeeper

  @probe Path.expand("fixtures/probe.mjs", __DIR__)
  @token "tok-0123456789abcdef"
  @owner %{athanor: "athanor-1", server: "server-1", g: 1, e: 1}

  setup do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    {:ok, supervisor: supervisor}
  end

  # The node binary itself: a version manager's shim may need an
  # environment the backend's, built from nothing, does not carry.
  defp node! do
    {path, 0} = System.cmd("node", ["-e", "process.stdout.write(process.execPath)"])
    path
  end

  defp probe_command, do: ~s(exec "#{node!()}" "#{@probe}")

  defp start_backend(supervisor, opts) do
    definition =
      Map.merge(
        %{name: "probe", command: probe_command(), env: %{"PROBE_TOKEN" => @token}},
        Map.new(Keyword.get(opts, :definition, []))
      )

    opts =
      [
        owner: @owner,
        definition: definition,
        launcher: Locus.DirectLauncher,
        bounds: [restart_backoff_ms: [50, 100], crash_window_ms: 60_000, max_crashes: 3],
        stop_grace_ms: 500,
        release_timeout_ms: 5_000
      ]
      |> Keyword.merge(Keyword.delete(opts, :definition))

    {:ok, backend} = DynamicSupervisor.start_child(supervisor, {Backend, opts})
    backend
  end

  defp wait_until(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && wait_until(check, attempts - 1)
    end
  end

  defp wait_status(backend, status),
    do: wait_until(fn -> Backend.status(backend).status == status end)

  defp starts(backend) do
    tail = Backend.status(backend).stderr_tail
    length(String.split(tail, "probe started")) - 1
  end

  defp text({:ok, %{"content" => [%{"type" => "text", "text" => text}]}}), do: text

  defp alive?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true)
    status == 0
  end

  describe "the probe through the direct launcher" do
    @describetag :requires_node

    test "is ready once the handshake lists its two tools, and answers a call", %{
      supervisor: supervisor
    } do
      backend = start_backend(supervisor, [])
      wait_status(backend, :ready)

      assert %{status: :ready, restarts: 0, tools: 2, error: nil} = Backend.status(backend)
      assert Enum.map(Backend.list_tools(backend), & &1["name"]) == ["echo", "secret"]

      assert ~s({"said":"hello"}) ==
               backend |> Backend.call_tool("echo", %{"said" => "hello"}) |> text()

      assert {:error, {:tool_error, "unknown tool: nope"}} =
               Backend.call_tool(backend, "nope", %{})
    end

    test "masks the owner's secret in a result and in the stderr tail", %{
      supervisor: supervisor
    } do
      backend = start_backend(supervisor, [])
      wait_status(backend, :ready)

      assert "[REDACTED]" ==
               backend |> Backend.call_tool("secret", %{"name" => "PROBE_TOKEN"}) |> text()

      wait_until(fn -> Backend.status(backend).stderr_tail =~ "secret PROBE_TOKEN" end)
      tail = Backend.status(backend).stderr_tail
      assert tail =~ "secret PROBE_TOKEN=[REDACTED]"
      refute tail =~ @token

      # Nor does a status or crash report of the process show it.
      refute inspect(:sys.get_status(backend), limit: :infinity) =~ @token

      # The owner's secrets are every backend's, handed in whole.
      other = start_backend(supervisor, secrets: ["probe started"])
      wait_status(other, :ready)
      refute Backend.status(other).stderr_tail =~ "probe started"
    end

    test "answers the backend's own request, which never answers the call it names", %{
      supervisor: supervisor
    } do
      backend = start_backend(supervisor, [])
      wait_status(backend, :ready)

      answer = backend |> Backend.call_tool("child_request", %{}) |> text() |> Jason.decode!()

      assert answer == %{
               "child_answer" => %{
                 "code" => -32_601,
                 "message" => "method not supported by bridge: sampling/createMessage"
               }
             }
    end

    test "a stdout line past the frame bound kills the process, which starts again after its backoff",
         %{supervisor: supervisor} do
      backend = start_backend(supervisor, [])
      wait_status(backend, :ready)

      assert {:error, {:tool_error, sentence}} = Backend.call_tool(backend, "flood", %{})
      assert sentence == "backend 'probe' call failed: exited code=null signal=SIGKILL"

      wait_until(fn -> match?(%{status: :ready, restarts: 1}, Backend.status(backend)) end)
      assert starts(backend) == 2
      assert text(Backend.call_tool(backend, "echo", %{})) == "{}"
    end

    test "crashes past the window mark it failed, and a failed backend refuses calls", %{
      supervisor: supervisor
    } do
      backend = start_backend(supervisor, [])

      for restarts <- 0..2 do
        wait_until(fn ->
          match?(%{status: :ready, restarts: ^restarts}, Backend.status(backend))
        end)

        assert {:error, {:tool_error, "backend 'probe' call failed: exited code=3 signal=null"}} =
                 Backend.call_tool(backend, "crash", %{})
      end

      wait_status(backend, :failed)

      assert %{status: :failed, restarts: 2, tools: 0, error: "exited code=3 signal=null"} =
               Backend.status(backend)

      assert Backend.list_tools(backend) == []

      assert {:error, {:tool_error, "backend 'probe' not ready: exited code=3 signal=null"}} =
               Backend.call_tool(backend, "echo", %{})

      assert {:error, :failed} = Backend.retire_idle(backend)
    end

    test "an idle backend keeps its tools, and the next call wakes it", %{supervisor: supervisor} do
      backend = start_backend(supervisor, [])
      wait_status(backend, :ready)
      os_pid = :sys.get_state(backend).handle.pid

      assert :ok = Backend.retire_idle(backend)
      assert %{status: :idle, tools: 2} = Backend.status(backend)
      assert length(Backend.list_tools(backend)) == 2
      wait_until(fn -> not alive?(os_pid) end)

      assert text(Backend.call_tool(backend, "echo", %{"n" => 1})) == ~s({"n":1})
      assert %{status: :ready, restarts: 0} = Backend.status(backend)
      assert starts(backend) == 2
    end

    test "calls that find it idle share one start", %{supervisor: supervisor} do
      backend = start_backend(supervisor, [])
      wait_status(backend, :ready)
      assert :ok = Backend.retire_idle(backend)

      answers =
        1..4
        |> Enum.map(fn n ->
          Task.async(fn -> Backend.call_tool(backend, "echo", %{"n" => n}) end)
        end)
        |> Task.await_many(30_000)
        |> Enum.map(&text/1)

      assert answers == for(n <- 1..4, do: ~s({"n":#{n}}))
      assert starts(backend) == 2
    end

    test "stop releases the process with its grace, and a stopped backend refuses calls", %{
      supervisor: supervisor
    } do
      backend = start_backend(supervisor, [])
      wait_status(backend, :ready)
      os_pid = :sys.get_state(backend).handle.pid

      assert :ok = Backend.stop(backend, 1_000)
      wait_until(fn -> not alive?(os_pid) end)

      assert %{status: :stopped, tools: 0} = Backend.status(backend)

      assert {:error, {:tool_error, "backend 'probe' not ready: stopped"}} =
               Backend.call_tool(backend, "echo", %{})
    end
  end

  describe "through the keeper's client" do
    setup do
      {fake, channel} = FakeKeeper.start()
      attach_dir = FakeKeeper.short_tmp_dir()
      name = :"backend_launcher_#{System.unique_integer([:positive])}"

      {:ok, client} =
        Locus.Keeper.start_link(channel: channel, attach_dir: attach_dir, name: name)

      Process.unlink(client)
      :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)

      on_exit(fn ->
        Process.exit(client, :kill)
        Process.exit(fake, :kill)
        File.rm_rf!(attach_dir)
      end)

      {:ok, fake: fake, keeper: name}
    end

    defp keeper_opts(keeper),
      do: [launcher: Locus.Keeper, launcher_server: keeper, memory_bytes: 268_435_456]

    test "the spawn is in the pool backends, the command under /bin/sh -c, the env block alone",
         %{supervisor: supervisor, fake: fake, keeper: keeper} do
      env = %{"PROBE_TOKEN" => @token, "NODE_ENV" => "test"}

      backend =
        start_backend(
          supervisor,
          [definition: [command: "exec cat >/dev/null", env: env], init_timeout_ms: 60_000] ++
            keeper_opts(keeper)
        )

      wait_until(fn ->
        Enum.any?(FakeKeeper.requests(fake), &(&1["type"] == "spawn"))
      end)

      [spawn] = Enum.filter(FakeKeeper.requests(fake), &(&1["type"] == "spawn"))
      assert spawn["pool"] == "backends"
      assert spawn["argv"] == ["/bin/sh", "-c", "exec cat >/dev/null"]
      assert spawn["env"] == env
      assert spawn["memory_bytes"] == 268_435_456
      refute Map.has_key?(spawn, "control")

      assert :ok = Backend.stop(backend, 0)
      wait_until(fn -> Enum.any?(FakeKeeper.requests(fake), &(&1["type"] == "release")) end)
    end

    @tag :requires_node
    test "the probe is ready and answers through it", %{supervisor: supervisor, keeper: keeper} do
      backend = start_backend(supervisor, keeper_opts(keeper))
      wait_status(backend, :ready)

      assert "[REDACTED]" ==
               backend |> Backend.call_tool("secret", %{"name" => "PROBE_TOKEN"}) |> text()

      assert :ok = Backend.stop(backend, 500)
    end
  end
end
