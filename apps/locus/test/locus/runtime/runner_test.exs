# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RunnerTest do
  @moduledoc """
  The runner role's process in this VM, over a control socket the test
  holds the service's end of: an `assign` starts the subtree, whose root
  attaches and closes with the scripted host; a `cancel_child` makes the
  named child's process stop its work and close its attempt as abandoned,
  and the subtree completes unclean; a lost host answer completes it
  unclean too; the channel closing with a subtree running lets it finish,
  then stops the VM; and a subtree still running past its deadline and
  grace is halted, with an `exit` naming what is open.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Prima.{Assignment, RunnerControl}
  alias Locus.Runtime.Test.{ScriptedHost, ScriptedKeeper}

  @echo File.read!(Path.expand("../../support/runtime/test_wasm/echo.wasm", __DIR__))
  @boot "boot_runner_test"

  setup do
    host = ScriptedHost.start!()

    path =
      Path.join(System.tmp_dir!(), "runtime_runner_#{System.unique_integer([:positive])}.sock")

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
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    settings = %{
      runner_id: "runner_under_test",
      service_id: ScriptedHost.service(),
      boot: @boot,
      control_fd: fd,
      relay: {:fd, 4},
      watchdog_grace_ms: 500
    }

    # The runner's relay, whose service end the test binds to each attempt
    # it assigns, as the worker service does.
    %{endpoint: endpoint, relay: relay} = ScriptedKeeper.relay!(settings.runner_id)
    Process.put({__MODULE__, :relay}, {relay, host.url})

    # Registered as the runner, so the subtree's processes find their
    # owner here rather than in the worker service of this VM.
    runner =
      start_supervised!(
        {Locus.Runtime.Runner,
         settings: settings,
         relay: endpoint,
         supervisor: supervisor,
         name: Locus.Runtime.Runner,
         halt: fn reason -> send(test, {:halted, reason}) end,
         stop: fn status -> send(test, {:stopped, status}) end}
      )

    # The runner's control port polls `runner_end`'s descriptor, which it
    # does not own. A port can outlive its owner, writing out what it was
    # given first, and has stopped polling only once it has left the port
    # table: a descriptor closed before then is reused by the next test's
    # sockets, and this port's late release takes the descriptor from them.
    # Registered last, this runs first, once the runner has stopped and
    # before the sockets close.
    [control] =
      for port <- Port.list(), Port.info(port, :connected) == {:connected, runner}, do: port

    on_exit(fn -> wait_until(fn -> control not in Port.list() end, 5_000) end)

    {:ok, host: host, service: service}
  end

  defp assign(service, attempt) do
    {relay, host_url} = Process.get({__MODULE__, :relay})

    :ok =
      Locus.Runtime.Relay.bind(relay, %{
        assignment: attempt.assignment,
        keys: attempt.keys,
        host_url: host_url
      })

    :ok =
      :socket.send(
        service,
        RunnerControl.encode(%{
          type: :assign,
          assignment: attempt.assignment,
          input: attempt.input,
          keys: attempt.keys
        })
      )
  end

  defp cancel_child(service, execution_id),
    do:
      :ok =
        :socket.send(
          service,
          RunnerControl.encode(%{type: :cancel_child, execution_id: execution_id})
        )

  # The next frame the runner writes.
  defp frame(service, timeout \\ 10_000) do
    {:ok, line} = :socket.recv(service, 0, timeout)
    {:ok, message} = RunnerControl.decode(line)
    message
  end

  defp echo!(host, opts \\ []) do
    ScriptedHost.script(host, "fetch_artifact", {:ok, Base.encode64(@echo)})

    ScriptedHost.attempt!(
      host,
      [boot: @boot, component_type: :reagent, digest: Prima.Digest.sha256(@echo)] ++ opts
    )
  end

  # An artifact answer held until the test lets it go: the attempt's
  # component process waits in it, so the subtree stays running. The
  # compiled component is forgotten first, or a run of this VM's cache
  # would never ask for it.
  defp hold_artifact!(host, bytes) do
    test = self()
    Locus.Runtime.Cache.invalidate({:compiled_component, Prima.Digest.sha256(bytes)})

    ScriptedHost.script(host, "fetch_artifact", fn _args, _caller ->
      send(test, {:held, self()})
      held_until_go(test, {:ok, Base.encode64(bytes)})
    end)
  end

  # A held answer, given once the test sends `:go`; the request ends
  # unanswered when the test process ends first, so a failed assertion
  # leaves no connection for the host's shutdown to wait out.
  defp held_until_go(test, answer) do
    monitor = Process.monitor(test)

    receive do
      :go ->
        Process.demonitor(monitor, [:flush])
        answer

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :drop
    end
  end

  defp child!(host, opts) do
    attempt = echo!(host, opts)
    {:ok, assignment} = Assignment.read(attempt.assignment)

    %{
      token: attempt.assignment,
      assignment: assignment,
      input: Jason.decode!(attempt.input),
      client: attempt.client,
      secrets: %{}
    }
  end

  test "an assign runs the subtree, whose root attaches and completes, and the runner completes clean",
       %{
         host: host,
         service: service
       } do
    attempt = echo!(host, input: %{"echoed" => 1})
    assign(service, attempt)

    assert %{type: :complete, execution_id: id, clean: true} = frame(service)
    assert id == attempt.execution_id

    assert [%{caller: %{runner: "runner_under_test", boot: @boot}}] =
             ScriptedHost.requests(host, "attach")

    assert [%{args: %{"outcome" => %{"output" => %{"echoed" => 1}}}}] =
             ScriptedHost.requests(host, "complete")

    # Another assignment follows on the same runner.
    again = echo!(host, input: %{"echoed" => 2})
    assign(service, again)
    assert %{type: :complete, clean: true} = frame(service)
    assert length(ScriptedHost.requests(host, "complete")) == 2
    refute_received {:stopped, _}
    refute_received {:halted, _}
  end

  test "a cancel_child stops the child's work, closes its attempt as abandoned, and the subtree completes unclean",
       %{host: host, service: service} do
    root = echo!(host)
    hold_artifact!(host, @echo)
    assign(service, root)
    assert_receive {:held, root_fetch}, 10_000

    child = child!(host, [])
    hold_artifact!(host, @echo)
    assert {:ok, _pid} = Locus.Runtime.Subtree.start_child(child, nil)

    # The service hears which child this runner holds.
    child_id = child.assignment.execution_id
    child_attempt = child.assignment.attempt
    assert %{type: :child, execution_id: ^child_id, attempt: ^child_attempt} = frame(service)
    assert_receive {:held, _child_fetch}, 10_000

    cancel_child(service, child.assignment.execution_id)

    wait_until(fn -> ScriptedHost.requests(host, "fail") != [] end, 10_000)

    assert [
             %{
               args: %{"outcome" => %{"error" => error, "abandoned" => true}},
               caller: %{execution_id: cancelled}
             }
           ] =
             ScriptedHost.requests(host, "fail")

    assert cancelled == child.assignment.execution_id
    assert error =~ "cancelled"

    # The root goes on, and the subtree ends unclean.
    send(root_fetch, :go)
    assert %{type: :complete, execution_id: root_id, clean: false} = frame(service)
    assert root_id == root.execution_id
    assert [%{caller: %{execution_id: ^root_id}}] = ScriptedHost.requests(host, "complete")
    refute_received {:stopped, _}
  end

  test "a cancel_child naming the root or no child of this subtree is ignored", %{
    host: host,
    service: service
  } do
    root = echo!(host)
    hold_artifact!(host, @echo)
    assign(service, root)
    assert_receive {:held, fetch}, 10_000

    cancel_child(service, root.execution_id)
    cancel_child(service, "exec_elsewhere")
    send(fetch, :go)

    assert %{type: :complete, clean: true} = frame(service)
  end

  test "a lost host answer completes the subtree unclean", %{host: host, service: service} do
    attempt = echo!(host)
    # Asked for afresh: a compiled component of this VM's cache is not fetched.
    Locus.Runtime.Cache.invalidate({:compiled_component, attempt.digest})
    ScriptedHost.script(host, "fetch_artifact", :drop)
    assign(service, attempt)

    assert %{type: :complete, clean: false} = frame(service)
    assert [%{args: %{"outcome" => %{"error" => error}}}] = ScriptedHost.requests(host, "fail")
    assert error =~ "could not be fetched"
  end

  test "the channel closing with a subtree running lets it finish, then stops the VM", %{
    host: host,
    service: service
  } do
    attempt = echo!(host)
    hold_artifact!(host, @echo)
    assign(service, attempt)
    assert_receive {:held, fetch}, 10_000

    :socket.close(service)
    refute_receive {:stopped, _}, 200

    send(fetch, :go)
    wait_until(fn -> ScriptedHost.requests(host, "complete") != [] end, 10_000)
    assert_receive {:stopped, 0}, 5_000
    refute_received {:halted, _}
  end

  test "the channel closing with nothing assigned stops the VM at once", %{service: service} do
    :socket.close(service)
    assert_receive {:stopped, 0}, 2_000
  end

  test "a subtree running past its deadline and the grace is halted, with an exit naming what is open",
       %{
         host: host,
         service: service
       } do
    test = self()

    ScriptedHost.script(host, "fail", fn _args, _caller ->
      send(test, {:fail_held, self()})
      held_until_go(test, {:ok, "held"})
    end)

    # The guest's bytes are held, so its call outlasts the attempt's bound.
    # A guest spinning past it instead would keep its native thread, and
    # the engine worker under it, for the rest of this VM's run: the kill
    # frees only its BEAM process.
    attempt = echo!(host, timeout_ms: 300)
    hold_artifact!(host, @echo)
    assign(service, attempt)
    assert_receive {:held, _fetch}, 5_000

    assert %{type: :exit, runner: "runner_under_test", open: [held]} = frame(service)
    assert held == attempt.attempt
    assert_receive {:halted, {:watchdog, id}}, 5_000
    assert id == attempt.execution_id
    assert_receive {:fail_held, fail}, 5_000
    send(fail, :go)
  end
end
