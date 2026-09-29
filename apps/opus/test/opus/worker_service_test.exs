# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerServiceTest do
  @moduledoc """
  The worker service starts only an assignment addressed to it and its
  boot, with the input its digest binds and keys sealed for it that open
  as its attempt. Its runners are OS processes of their own (the `Direct`
  keeper). A runner that exits leaving its attempt open is reported to
  CYFR at once over the wire, signed with the service's dispatch key; a
  killed runner is reported the same way. A restarted service is a new
  boot that holds none of its predecessor's attempts, and its runners'
  processes are gone. Neither the service, nor a runner's handle holding
  the assign it sent, nor its relay holding the attempt's keys, nor the
  keeper shows a runner's attempt keys or the service's own, raw or as
  the hex the channel carries.

  Over a scripted keeper's runners, whose frames the test writes: a
  report names at most `Prima.WorkerWire.max_report_attempts/0`
  attempts, and at that bound, every identifier at its longest, it fits
  the body CYFR reads and is accepted. A runner starting one child past
  the bound is ended at once, as a kill of its root ends it, the bound
  logged, and its report names what the service held. The ids an `exit`
  lists that the service does not hold follow the held ones, and what is
  past the bound is left out and counted. Kills of what no runner holds
  leave every runner's cancelled children to the ones it said it holds;
  the last ten thousand of them are remembered, and one a runner then
  says it started is a child the service cancelled, only if its
  assignment started before the kill. A child refused at the bound is
  remembered as ended, so a kill of it is `:ok`. A runner the pool hands
  out again before the service has read its clean completion takes the
  new subtree, and its old assignment is forgotten: a kill of the old
  root is `:ok` and leaves the new subtree running.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Opus.Test.Wait

  alias Prima.{HostAPI, RunnerControl, WorkerAuth, WorkerWire}
  alias Opus.Test.{ScriptedHost, ScriptedKeeper}
  alias Opus.{RunnerPool, RunnerProcess, WorkerService}

  # A runner is a VM booting from nothing: its first host call takes seconds.
  @boot_ms 30_000

  setup tags do
    host = ScriptedHost.start!()

    if tags[:scripted],
      do: scripted!(host),
      else: {:ok, host: host, boot: ScriptedHost.serve!(host)}
  end

  # The running service's tree gives way to one whose runners a scripted
  # keeper hands the test, over the real codec, and comes back when the
  # test ends: a test that writes a runner's frames itself.
  defp scripted!(host) do
    previous = Map.new([:keeper, :host_url], &{&1, Application.fetch_env(:opus, &1)})
    :ok = Supervisor.terminate_child(Opus.Supervisor, Opus.WorkerService.Tree)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:opus, key, value)
          :error -> Application.delete_env(:opus, key)
        end
      end

      {:ok, _pid} = Supervisor.restart_child(Opus.Supervisor, Opus.WorkerService.Tree)
    end)

    Application.put_env(:opus, :keeper, :direct)
    Application.put_env(:opus, :host_url, host.url)

    keeper = ScriptedKeeper.start!()
    {:ok, settings} = Opus.Settings.pool([keeper: :direct, pool_size: 1], %{})
    start_supervised!({DynamicSupervisor, name: Opus.RunnerPool.Runners, strategy: :one_for_one})

    start_supervised!(
      {Opus.RunnerPool,
       settings: settings,
       keeper: ScriptedKeeper,
       supervisor: Opus.RunnerPool.Runners,
       command: %{argv: ["runner"], env: %{"KEEPER" => Atom.to_string(keeper)}}}
    )

    start_supervised!(WorkerService)
    {:ok, %{boot: boot}} = WorkerService.status()
    {:ok, host: host, boot: boot, keeper: keeper}
  end

  defp start(attempt, sealed \\ nil),
    do: WorkerService.start(attempt.assignment, attempt.input, sealed || attempt.sealed_keys)

  defp sealed_with(key, attempt) do
    {:ok, sealed} = WorkerAuth.seal_attempt_keys(key, attempt.keys)
    sealed
  end

  defp worker_key(host, service) do
    {:ok, key} = WorkerAuth.worker_key(host.root, service)
    key
  end

  defp attempts, do: elem(WorkerService.status(), 1).attempts

  describe "start/3" do
    test "refuses an assignment addressed to another worker service, or another boot of this one",
         %{host: host, boot: boot} do
      other_service = ScriptedHost.attempt!(host, service: "wrk_other", boot: boot)
      assert {:error, :malformed} = start(other_service)

      other_boot = ScriptedHost.attempt!(host, boot: "boot_other")
      assert {:error, :malformed} = start(other_boot)

      assert attempts() == []
      assert ScriptedHost.requests(host) == []
    end

    test "refuses input its assignment's digest does not bind", %{host: host, boot: boot} do
      attempt = ScriptedHost.attempt!(host, boot: boot)

      assert {:error, :malformed} =
               WorkerService.start(attempt.assignment, ~s({"fixture":false}), attempt.sealed_keys)

      assert attempts() == []
    end

    test "refuses keys that do not open as the assignment's attempt on this worker service", %{
      host: host,
      boot: boot
    } do
      attempt = ScriptedHost.attempt!(host, boot: boot)
      other = ScriptedHost.attempt!(host, boot: boot)
      elsewhere = WorkerAuth.dispatch_seal_key(worker_key(host, "wrk_other"))
      signing = WorkerAuth.dispatch_key(worker_key(host, "wrk_local"))

      for sealed <- [
            other.sealed_keys,
            sealed_with(elsewhere, attempt),
            sealed_with(signing, attempt),
            "not sealed"
          ] do
        assert {:error, :malformed} = start(attempt, sealed)
      end

      assert %{busy: 0} = elem(WorkerService.status(), 1).runners
      assert attempts() == []
    end

    test "refuses an execution this service already runs", %{host: host, boot: boot} do
      ScriptedHost.script(host, "attach", fn _args, _caller ->
        Process.sleep(500)
        {:error, :lost}
      end)

      attempt = ScriptedHost.attempt!(host, boot: boot)
      assert :ok = start(attempt)
      assert {:error, :malformed} = start(attempt)
      assert attempts() == [attempt.attempt]
    end
  end

  test "a runner that exits leaving its attempt open is reported at once, signed by the service",
       %{
         host: host,
         boot: boot
       } do
    ScriptedHost.script(host, "attach", {:error, :lost})
    attempt = ScriptedHost.attempt!(host, boot: boot)

    assert :ok = start(attempt)

    wait_until(fn -> ScriptedHost.requests(host, "runner_exited") != [] end, @boot_ms)

    assert [%{args: args, caller: report, header: header}] =
             ScriptedHost.requests(host, "runner_exited")

    assert args["attempts"] == [attempt.attempt]
    assert [%{caller: %{runner: runner}}] = ScriptedHost.requests(host, "attach")
    assert args["runner"] == runner
    assert %{service: "wrk_local", boot: ^boot} = report
    assert String.starts_with?(header, "v1 kind=report ")
    wait_until(fn -> attempts() == [] end)
  end

  test "a runner that closes its attempt is not reported", %{host: host, boot: boot} do
    attempt = ScriptedHost.attempt!(host, boot: boot)
    assert :ok = start(attempt)

    wait_until(fn -> ScriptedHost.requests(host, "fail") != [] end, @boot_ms)
    wait_until(fn -> attempts() == [] end)
    assert ScriptedHost.requests(host, "runner_exited") == []
  end

  test "a kill stops the runner, its exit is reported, and the kill is idempotent", %{
    host: host,
    boot: boot
  } do
    ScriptedHost.script(host, "attach", fn _args, _caller ->
      Process.sleep(2_000)
      {:ok, %{}}
    end)

    attempt = ScriptedHost.attempt!(host, boot: boot)
    assert :ok = start(attempt)
    wait_until(fn -> attempts() == [attempt.attempt] end)

    assert :ok = WorkerService.kill(attempt.execution_id)

    # The runner ends within its release grace; the service forgets the
    # attempt as it sends the report of that end.
    wait_until(fn -> ScriptedHost.requests(host, "runner_exited") != [] end, @boot_ms)
    assert [%{args: %{"attempts" => [held]}}] = ScriptedHost.requests(host, "runner_exited")
    assert held == attempt.attempt
    assert attempts() == []

    # Again for an execution this boot ended; never for one it never ran.
    assert :ok = WorkerService.kill(attempt.execution_id)
    assert {:error, :not_found} = WorkerService.kill("exec_never_here")
  end

  test "a restarted service is a new boot that holds none of its predecessor's attempts", %{
    host: host,
    boot: boot
  } do
    hold_attach!(host)
    attempt = ScriptedHost.attempt!(host, boot: boot)
    assert :ok = start(attempt)
    assert_receive {:attach_held, held}, @boot_ms
    %{pid: handle} = Enum.find(RunnerPool.runners(RunnerPool), &(&1.state == :busy))
    os_pid = RunnerProcess.info(handle).os_pid

    ScriptedHost.restart_service!()
    send(held, :go)

    assert {:ok, %{boot: new_boot, attempts: []}} = WorkerService.status()
    assert new_boot != boot
    wait_until(fn -> not os_alive?(os_pid) end, 10_000, "the old boot's runner to be gone")

    # The predecessor's assignment is another boot's now.
    assert {:error, :malformed} = start(attempt)
  end

  test "neither the service, nor a runner's handle or relay, nor the keeper shows a key", %{
    host: host,
    boot: boot
  } do
    hold_attach!(host)
    attempt = ScriptedHost.attempt!(host, boot: boot)
    assert :ok = start(attempt)
    assert_receive {:attach_held, held}, @boot_ms

    %Opus.Credentials{} = credentials = Opus.Credentials.current()
    handles = for %{pid: pid} <- RunnerPool.runners(RunnerPool), do: pid

    # Each runner's relay holds the keys of the attempt it is bound to.
    relays = for pid <- handles, relay = :sys.get_state(pid).relay, do: relay
    assert relays != []

    for process <- [WorkerService, Opus.Keeper.Direct | handles ++ relays],
        key <- [
          attempt.keys.call,
          attempt.keys.seal,
          credentials.worker_key,
          credentials.dispatch_key,
          credentials.dispatch_seal_key
        ],
        encoded <- [key, Base.encode16(key, case: :lower)] do
      status = :erlang.term_to_binary(:sys.get_status(process))
      assert :binary.match(status, encoded) == :nomatch
    end

    send(held, :go)
  end

  describe "what a runner's report names" do
    @describetag :scripted

    test "a thousand kills of what no runner holds leave a runner's cancelled children to its own",
         context do
      {root, runner} = started!(context)
      write(runner, [child("exec_child", "att_child")])
      wait_until(fn -> "att_child" in attempts() end)

      for i <- 1..1_000 do
        assert {:error, :not_found} = WorkerService.kill("exec_nobody_ran_#{i}")
      end

      # No runner's cancelled children change; the kills are remembered
      # beside them, in case a runner says it started one.
      assert [%{cancelled: cancelled}] = assignments()
      assert MapSet.size(cancelled) == 0
      assert MapSet.size(offered()) == 1_000

      # A child the runner holds is cancelled in it, once however often.
      for _ <- 1..3, do: assert(:ok = WorkerService.kill("exec_child"))
      assert [%{cancelled: cancelled, children: children}] = assignments()
      assert MapSet.to_list(cancelled) == ["exec_child"]
      assert MapSet.size(cancelled) <= map_size(children)

      # Its unclean completion is still reported, naming the child, and
      # nothing of the runner is kept.
      write(runner, [%{type: :complete, execution_id: root.execution_id, clean: false}])
      assert [%{args: %{"attempts" => held}}] = reports(context)
      assert Enum.sort(held) == Enum.sort([root.attempt, "att_child"])
      assert assignments() == []
    end

    test "the kills offered to every busy runner are remembered up to ten thousand, oldest dropped first",
         context do
      {root, runner} = started!(context)

      for i <- 1..10_001 do
        assert {:error, :not_found} = WorkerService.kill("exec_offered_#{i}")
      end

      assert MapSet.size(offered()) == 10_000
      refute MapSet.member?(offered(), "exec_offered_1")

      # The runner says it started the first, which was dropped, and the
      # last, which is still remembered: only the last is a child the
      # service cancelled, and it leaves the memory.
      write(runner, [
        child("exec_offered_1", "att_first"),
        child("exec_offered_10001", "att_last")
      ])

      wait_until(fn -> "att_last" in attempts() end)
      assert [%{cancelled: cancelled}] = assignments()
      assert MapSet.to_list(cancelled) == ["exec_offered_10001"]
      assert MapSet.size(offered()) == 9_999
      refute MapSet.member?(offered(), "exec_offered_10001")

      write(runner, [%{type: :complete, execution_id: root.execution_id, clean: false}])
      assert [%{args: %{"attempts" => held}}] = reports(context)
      assert Enum.sort(held) == Enum.sort([root.attempt, "att_first", "att_last"])
    end

    test "a runner starting one child past the bound is ended, and its report names what was held",
         context do
      max = WorkerWire.max_report_attempts()
      {root, runner} = started!(context)
      id = runner_id(root)
      {held, [past, ignored]} = Enum.split(worst_ids(max + 1), max - 1)
      write(runner, children(held))
      wait_until(fn -> length(attempts()) == max end)
      assert ScriptedKeeper.releases(context.keeper) == []

      log =
        capture_log(fn ->
          write(runner, children([past, ignored], max))

          # Ended at once, with the grace a kill of its root gives, and its
          # report comes once that grace has run out.
          wait_until(fn -> ScriptedKeeper.releases(context.keeper) != [] end)
          grace = Opus.Settings.pool!().release_grace_ms
          assert [{_runner, ^grace}] = ScriptedKeeper.releases(context.keeper)

          # Neither child it was not given is forgotten: a runner of this
          # boot started each, so a kill of either reached it.
          wait_until(fn -> ended?("exec_child_#{max + 1}") end)

          for i <- [max, max + 1] do
            assert :ok = WorkerService.kill("exec_child_#{i}")
          end

          assert [%{args: %{"attempts" => named}, body: body}] = reports(context, grace + 5_000)

          assert length(named) == max
          assert hd(named) == root.attempt
          assert Enum.sort(tl(named)) == Enum.sort(held)
          refute past in named
          refute ignored in named
          assert byte_size(body) <= HostAPI.max_body_bytes()
        end)

      # The runner is logged once, with the bound.
      assert log =~ "runner #{id} (#{root.execution_id})"
      assert [_, _] = String.split(log, "past the #{max} attempts one report can name")
      assert assignments() == []

      # Once the runner has ended, a kill of either is still `:ok`.
      for i <- [max, max + 1] do
        assert :ok = WorkerService.kill("exec_child_#{i}")
      end
    end

    test "an end report at the bound, every attempt at its longest, fits and is accepted",
         context do
      max = WorkerWire.max_report_attempts()
      {root, runner} = started!(context)
      held = worst_ids(max - 1)
      write(runner, children(held))
      wait_until(fn -> length(attempts()) == max end)

      log =
        capture_log(fn ->
          ScriptedKeeper.exit(runner, 137)
          assert [%{args: args, body: body}] = reports(context)

          root_attempt = root.attempt
          assert %{"attempts" => [^root_attempt | children]} = args

          assert Enum.sort(children) == Enum.sort(held)
          assert byte_size(body) <= HostAPI.max_body_bytes()

          assert {:ok, :runner_exited, %{"attempts" => read}} =
                   WorkerWire.read_request_body(HostAPI, Jason.decode!(body))

          assert length(read) == max
        end)

      # The host verified it and answered it: nothing was refused, and no
      # report went unanswered.
      refute Enum.any?(ScriptedHost.requests(context.host), &match?({:refused, _, _}, &1))
      refute log =~ "was not reported"
      refute log =~ "out of its report"
    end

    test "an exit listing 1 024 ids the service does not hold, past a full held set, is cut at the bound",
         context do
      max = WorkerWire.max_report_attempts()
      open_max = RunnerControl.max_open()
      {root, runner} = started!(context)
      {held, unheld} = Enum.split(worst_ids(max - 1 + open_max), max - 1)
      write(runner, children(held))
      wait_until(fn -> length(attempts()) == max end)

      log =
        capture_log(fn ->
          write(runner, [%{type: :exit, runner: runner_id(root), open: unheld}])
          assert [%{args: %{"attempts" => named}, body: body}] = reports(context)

          assert length(named) == max
          assert hd(named) == root.attempt
          assert Enum.sort(tl(named)) == Enum.sort(held)
          assert byte_size(body) <= HostAPI.max_body_bytes()
        end)

      assert log =~ "leaves #{open_max} attempts out of its report, past the #{max}"
    end

    test "an exit's ids the service does not hold follow the held ones, in order, up to the bound",
         context do
      max = WorkerWire.max_report_attempts()
      open_max = RunnerControl.max_open()
      {root, runner} = started!(context)
      {held, unheld} = Enum.split(worst_ids(1_500 + open_max), 1_500)
      write(runner, children(held))
      wait_until(fn -> length(attempts()) == 1_501 end)

      # The runner lists its root and a child the service holds too: each
      # is named once, where the service names what it holds.
      open = [root.attempt, hd(held) | Enum.take(unheld, open_max - 2)]
      room = max - 1_501

      log =
        capture_log(fn ->
          write(runner, [%{type: :exit, runner: runner_id(root), open: open}])
          assert [%{args: %{"attempts" => named}}] = reports(context)

          {named_held, named_unheld} = Enum.split(named, 1_501)
          assert hd(named_held) == root.attempt
          assert Enum.sort(tl(named_held)) == Enum.sort(held)
          assert named_unheld == Enum.take(unheld, room)
        end)

      assert log =~ "leaves #{open_max - 2 - room} attempts out of its report"
    end
  end

  describe "which runner a kill reaches" do
    @describetag :scripted

    test "a kill offered before a runner was assigned is never that runner's cancelled child",
         context do
      {_first, _first_runner} = started!(context)
      assert {:error, :not_found} = WorkerService.kill("exec_x")

      # A runner assigned after the offer never received its `cancel_child`,
      # so its word of starting that execution does not make it cancelled.
      {later, later_runner} = started!(context)
      write(later_runner, [child("exec_x", "att_x")])
      wait_until(fn -> "att_x" in attempts() end)

      assert %{cancelled: cancelled} = assignment_of(later)
      assert MapSet.size(cancelled) == 0
      assert "exec_x" in offered()

      # Its unclean completion names no child the service cancelled, and is
      # not reported.
      write(later_runner, [%{type: :complete, execution_id: later.execution_id, clean: false}])
      wait_until(fn -> assignment_of(later) == nil end)
      assert :ok = WorkerService.await_reports()
      assert ScriptedHost.requests(context.host, "runner_exited") == []
    end

    test "a runner the pool hands back before its clean completion is read takes the new subtree",
         context do
      {first, runner} = started!(context)
      id = runner_id(first)
      write(runner, [child("exec_first_child", "att_first_child")])
      wait_until(fn -> "att_first_child" in attempts() end)
      next = ScriptedHost.attempt!(context.host, boot: context.boot)
      service = Process.whereis(WorkerService)
      first_id = first.execution_id

      # The next start reaches the service ahead of the first subtree's clean
      # completion. The pool sends that completion to the service before it
      # makes the runner idle for the athanor, so by the time a `take` can
      # hand the runner out again the completion is already queued, behind
      # the start.
      :ok = :sys.suspend(WorkerService)
      starting = Task.async(fn -> start(next) end)
      wait_until(fn -> Process.info(service, :message_queue_len) == {:message_queue_len, 1} end)
      write(runner, [%{type: :complete, execution_id: first_id, clean: true}])

      wait_until(fn ->
        Enum.any?(RunnerPool.runners(RunnerPool), &(&1.id == id and &1.state == :idle))
      end)

      assert {:messages,
              [
                {:"$gen_call", _from, {:start, _token, _input, _sealed, _caller}},
                {RunnerPool, _pid, {:complete, ^first_id, true}}
              ]} = Process.info(service, :messages)

      capture_log(fn ->
        :ok = :sys.resume(WorkerService)
        assert :ok = Task.await(starting)
      end)

      # The late completion is read before this status: it names an
      # execution the runner no longer holds, and the runner holds the next
      # subtree alone.
      assert {:ok, %{attempts: [held]}} = WorkerService.status()
      assert held == next.attempt
      assert %{execution_id: next_id} = assignment_of(next)
      assert next_id == next.execution_id

      # The first root and its child are ended for this boot: a kill of
      # either is `:ok`, and the runner running the next subtree is not
      # ended by it. A clean end reports nothing.
      assert :ok = WorkerService.kill(first_id)
      assert :ok = WorkerService.kill("exec_first_child")
      assert %{state: :busy, execution_id: ^next_id} = pooled(id)
      assert ScriptedKeeper.releases(context.keeper) == []
      assert :ok = WorkerService.await_reports()
      assert ScriptedHost.requests(context.host, "runner_exited") == []

      # The next subtree's own kill ends its runner, which is reported
      # holding its root.
      assert :ok = WorkerService.kill(next_id)
      grace = Opus.Settings.pool!().release_grace_ms
      assert %{state: :tainted} = pooled(id)
      assert [{^id, ^grace}] = ScriptedKeeper.releases(context.keeper)
      assert [%{args: %{"attempts" => [reported]}}] = reports(context, grace + 5_000)
      assert reported == next.attempt
    end

    test "a queued child past the bound of a subtree already completed never ends the reused runner",
         context do
      max = WorkerWire.max_report_attempts()
      {first, runner} = started!(context)
      id = runner_id(first)
      {held, [past]} = Enum.split(worst_ids(max), max - 1)
      write(runner, children(held))
      wait_until(fn -> length(attempts()) == max end)
      next = ScriptedHost.attempt!(context.host, boot: context.boot)
      service = Process.whereis(WorkerService)
      first_id = first.execution_id

      # The previous subtree's child past the bound and its clean completion
      # are both queued behind the next start.
      :ok = :sys.suspend(WorkerService)
      starting = Task.async(fn -> start(next) end)
      wait_until(fn -> Process.info(service, :message_queue_len) == {:message_queue_len, 1} end)

      write(
        runner,
        children([past], max) ++ [%{type: :complete, execution_id: first_id, clean: true}]
      )

      wait_until(fn ->
        Enum.any?(RunnerPool.runners(RunnerPool), &(&1.id == id and &1.state == :idle))
      end)

      capture_log(fn ->
        :ok = :sys.resume(WorkerService)
        assert :ok = Task.await(starting)
      end)

      # The runner the pool took for the next subtree is not ended by the
      # previous subtree's frame: it stays busy on the next subtree, nothing
      # is released or reported, and the child past the bound is ended with
      # the subtree that announced it.
      next_id = next.execution_id
      assert %{state: :busy, execution_id: ^next_id} = pooled(id)
      assert ScriptedKeeper.releases(context.keeper) == []
      assert {:ok, %{attempts: [held_attempt]}} = WorkerService.status()
      assert held_attempt == next.attempt
      assert ended?("exec_child_#{max}")
      assert :ok = WorkerService.kill("exec_child_#{max}")
      assert %{state: :busy, execution_id: ^next_id} = pooled(id)
      assert :ok = WorkerService.await_reports()
      assert ScriptedHost.requests(context.host, "runner_exited") == []
    end

    test "a frame the previous subtree sent before its clean completion never reaches the new one",
         context do
      {first, runner} = started!(context)
      id = runner_id(first)
      next = ScriptedHost.attempt!(context.host, boot: context.boot)
      service = Process.whereis(WorkerService)
      first_id = first.execution_id

      # The previous subtree announces a child and completes cleanly in one
      # write, both behind the next start in the service's mailbox.
      :ok = :sys.suspend(WorkerService)
      starting = Task.async(fn -> start(next) end)
      wait_until(fn -> Process.info(service, :message_queue_len) == {:message_queue_len, 1} end)

      write(runner, [
        child("exec_late_child", "att_late_child"),
        %{type: :complete, execution_id: first_id, clean: true}
      ])

      wait_until(fn ->
        Enum.any?(RunnerPool.runners(RunnerPool), &(&1.id == id and &1.state == :idle))
      end)

      assert {:messages,
              [
                {:"$gen_call", _from, {:start, _token, _input, _sealed, _caller}},
                {RunnerPool, _, {:child, "exec_late_child", "att_late_child"}},
                {RunnerPool, _, {:complete, ^first_id, true}}
              ]} = Process.info(service, :messages)

      capture_log(fn ->
        :ok = :sys.resume(WorkerService)
        assert :ok = Task.await(starting)
      end)

      # The late child was the previous subtree's and ended with it: the new
      # subtree holds its own root alone, and a kill of the late child is
      # `:ok` without reaching the runner now running the new subtree.
      assert {:ok, %{attempts: [held]}} = WorkerService.status()
      assert held == next.attempt
      assert %{children: children, cancelled: cancelled} = assignment_of(next)
      assert children == %{}
      assert MapSet.size(cancelled) == 0
      assert ended?("exec_late_child")

      assert :ok = WorkerService.kill("exec_late_child")
      next_id = next.execution_id
      assert %{state: :busy, execution_id: ^next_id} = pooled(id)
      refute ScriptedKeeper.read(runner) =~ "cancel_child"
      assert ScriptedKeeper.releases(context.keeper) == []
      assert :ok = WorkerService.await_reports()
      assert ScriptedHost.requests(context.host, "runner_exited") == []
    end
  end

  # A subtree started on a runner of the scripted keeper: the attempt and
  # the runner's spawn, whose channel the test writes and reads.
  defp started!(context) do
    attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
    assert :ok = start(attempt)

    spawn =
      Enum.find(ScriptedKeeper.spawns(context.keeper), fn spawn ->
        String.contains?(ScriptedKeeper.read(spawn), attempt.assignment)
      end)

    {attempt, spawn}
  end

  # The runner writes `messages` on its channel, as its frames.
  defp write(spawn, messages),
    do: ScriptedKeeper.write(spawn, Enum.map(messages, &RunnerControl.encode/1))

  defp child(execution_id, attempt),
    do: %{type: :child, execution_id: execution_id, attempt: attempt}

  # A `child` frame for each of `attempts`, numbered from `from`.
  defp children(attempts, from \\ 1) do
    attempts
    |> Enum.with_index(from)
    |> Enum.map(fn {attempt, i} -> child("exec_child_#{i}", attempt) end)
  end

  # `n` distinct identifiers, each the longest the worker protocol carries
  # and every byte of it one JSON escapes to two: the report at its
  # largest.
  defp worst_ids(n) do
    for i <- 1..n//1 do
      bits =
        i
        |> Integer.to_string(2)
        |> String.pad_leading(12, "0")
        |> String.replace("0", "\"")
        |> String.replace("1", "\\")

      String.duplicate("\\", 256 - byte_size(bits)) <> bits
    end
  end

  # What the service holds for each runner of this boot.
  defp assignments, do: Map.values(:sys.get_state(WorkerService).assigned)

  # The pool's runner `id`, as the pool sees it.
  defp pooled(id), do: Enum.find(RunnerPool.runners(RunnerPool), &(&1.id == id))

  # What the service holds for the runner of `attempt`'s subtree, if any.
  defp assignment_of(attempt),
    do: Enum.find(assignments(), &(&1.execution_id == attempt.execution_id))

  # The kills of what no runner held that the service offered every busy
  # runner, and still remembers.
  defp offered, do: :sys.get_state(WorkerService).offered.ids |> ids()

  # Whether the service remembers `execution_id` as ended.
  defp ended?(execution_id), do: execution_id in ids(:sys.get_state(WorkerService).ended.ids)

  defp ids(ids), do: ids |> Map.keys() |> MapSet.new()

  # The id of the pool's runner that took `attempt`'s subtree.
  defp runner_id(attempt) do
    RunnerPool
    |> RunnerPool.runners()
    |> Enum.find_value(&(&1.execution_id == attempt.execution_id && &1.id))
  end

  # The one runner exit report the host received, once it has and the
  # service has seen it answered.
  defp reports(context, timeout \\ 5_000) do
    wait_until(fn -> ScriptedHost.requests(context.host, "runner_exited") != [] end, timeout)
    assert :ok = WorkerService.await_reports()
    ScriptedHost.requests(context.host, "runner_exited")
  end

  # The runner's attach is held until the test lets it go: the runner is
  # busy with its attempt open, and the test hears the attach arrive.
  defp hold_attach!(host) do
    test = self()

    ScriptedHost.script(host, "attach", fn _args, _caller ->
      send(test, {:attach_held, self()})

      receive do
        :go -> {:ok, %{}}
      after
        30_000 -> {:ok, %{}}
      end
    end)
  end

  defp os_alive?(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_none, _status} -> false
    end
  end
end
