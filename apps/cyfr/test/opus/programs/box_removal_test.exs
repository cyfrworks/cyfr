# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.BoxRemovalTest do
  @moduledoc """
  A kept home's change and the homes' list are sent beside the box's one
  call (`Opus.Programs.Box`, "Messages"), against the scripted backends
  service (`Cyfr.Test.ScriptedBackends`): removals the service holds keep
  no renewal back; one overtaken on its way is sent again and applied once;
  an answer held past a restart the box has since greeted settles its
  caller alone; and a second reset beside a first is refused busy at the
  provider while the first succeeds.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Emissary.External.Provider
  alias Opus.Programs

  @root :crypto.strong_rand_bytes(32)
  @generation_key {Arca.ControlPlane, :generation}
  @busy "The program is starting or its folder is being changed. " <>
          "Try again when that has finished."

  setup do
    Cyfr.Test.Sandbox.setup!()
    Arca.Cache.init()

    ctx = Sanctum.TestContext.local()
    fake = Scripted.start(self(), @root)

    on_exit(fn ->
      :persistent_term.erase(@generation_key)
      Arca.ControlPlane.record(:unclaimed)
    end)

    controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "hello", %{"g" => 1}, %{boot: "-"}}, 2_000
    assert_receive {:control, "reconcile", %{"keep" => []}, _fields}, 2_000
    await_idle(controller)
    {:ok, ctx: ctx, fake: fake, controller: controller}
  end

  # Until the controller has nothing in flight, beside it or queued.
  defp await_idle(controller, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    state = :sys.get_state(controller)

    cond do
      state.inflight == nil and state.beside == %{} and :queue.is_empty(state.urgent) and
          :queue.is_empty(state.queue) ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the controller did not settle")

      true ->
        # sleep-ok: poll interval of await_idle's bounded wait (3 s) for the controller to settle
        Process.sleep(10)
        await_idle(controller, deadline)
    end
  end

  # Until the controller has no call in flight, whatever is out beside it.
  defp await_lane(controller, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    state = :sys.get_state(controller)

    cond do
      state.inflight == nil and :queue.is_empty(state.urgent) and :queue.is_empty(state.queue) ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the controller's lane did not settle")

      true ->
        # sleep-ok: poll interval of await_lane's bounded wait (3 s) for the lane to settle
        Process.sleep(10)
        await_lane(controller, deadline)
    end
  end

  # An owner the test process holds: a scratch program with no vault entry.
  defp held_owner(ctx, name) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "mcp",
        url: nil,
        config_json:
          Jason.encode!(%{
            "command" => "npx -y @modelcontextprotocol/server-github",
            "env" => %{"NODE_ENV" => "production"},
            "timeout_ms" => 5_000
          })
      })

    {:ok, grant} =
      Programs.hold(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: row.epoch})

    assert_receive {:control, "sync", _sync, _fields}, 2_000
    {row, grant}
  end

  defp held_message(type) do
    receive do
      {:held, ^type, pid} -> pid
    after
      2_000 -> :waits
    end
  end

  defp flush_control do
    receive do
      {:control, _type, _message, _fields} -> flush_control()
    after
      0 -> :ok
    end
  end

  test "three homes' removals are held, and the owner's renewal goes out within its third of " <>
         "the lease and its grant stands",
       %{ctx: ctx, fake: fake, controller: controller} do
    {row, _grant} = held_owner(ctx, "bee")
    await_idle(controller)
    homes = for i <- 1..3, do: "vlt_removal_#{i}"
    for _home <- homes, do: Scripted.hold(fake, "home", 30_000)

    removals =
      for home <- homes, do: Task.async(fn -> Programs.home(ctx.athanor_id, home, :retire) end)

    held = for _home <- homes, do: held_message("home")
    send(controller, :tick)

    renewed =
      receive do
        {:control, "renew", %{"owners" => owners}, _fields} -> owners
      after
        2_000 -> :waits
      end

    state = await_lane(controller)

    stood_down =
      receive do
        {Opus.Programs, :stand_down, _key} -> true
      after
        0 -> false
      end

    for pid <- held, is_pid(pid), do: send(pid, :go)
    removed = Task.await_many(removals, 15_000)

    assert %{
             held: Enum.count(held, &is_pid/1),
             renewed: renewed,
             live: state.owners[{ctx.athanor_id, row.id}].live?,
             stood_down: stood_down,
             removed: removed
           } == %{
             held: 3,
             renewed: [%{"athanor" => ctx.athanor_id, "server" => row.id, "e" => row.epoch}],
             live: true,
             stood_down: false,
             removed: [:ok, :ok, :ok]
           }

    assert await_idle(controller).homes == %{}
  end

  test "a removal overtaken on its way is sent again under a new sequence and applied once",
       %{ctx: ctx, fake: fake, controller: controller} do
    Scripted.refuse_once(fake, "home", "stale_control")
    answer = Programs.home(ctx.athanor_id, "vlt_overtaken", :retire)

    assert_receive {:control, "home", %{"home_id" => "vlt_overtaken"}, %{seq: first}}, 2_000
    assert_receive {:control, "home", %{"home_id" => "vlt_overtaken"}, %{seq: again}}, 2_000
    refute_receive {:control, "home", _message, _fields}, 300

    assert %{answer: answer, again_later: again > first, homes: await_idle(controller).homes} ==
             %{answer: :ok, again_later: true, homes: %{}}
  end

  for {what, type} <- [retire: "home", reset: "home", list: "homes"] do
    @tag what: what, type: type
    test "a #{what}'s success from the boot before a restart, held until the box greeted the " <>
           "next and renewed an owner, answers its caller and leaves that owner live",
         %{ctx: ctx, fake: fake, controller: controller, what: what, type: type} do
      {row, _grant} = held_owner(ctx, "survivor")
      await_idle(controller)
      Scripted.hold(fake, type, 30_000)

      call =
        Task.async(fn ->
          case what do
            :list -> Programs.homes()
            op -> Programs.home(ctx.athanor_id, "vlt_restart", op)
          end
        end)

      held = held_message(type)
      Scripted.restart(fake, "bb_second")

      # The tick's renewal finds the new boot; the box greets it and syncs
      # its owner again; the next tick renews that owner under it.
      send(controller, :tick)
      assert_receive {:control, "hello", _hello, %{boot: "-"}}, 2_000
      assert_receive {:control, "sync", _sync, %{boot: "bb_second"}}, 2_000
      await_lane(controller)
      send(controller, :tick)
      assert_receive {:control, "renew", _renew, %{boot: "bb_second"}}, 2_000
      await_lane(controller)
      flush_control()

      if is_pid(held), do: send(held, :go)
      answer = Task.await(call, 15_000)
      state = await_idle(controller)

      greeted_again =
        receive do
          {:control, type, _message, _fields} when type in ["hello", "sync"] -> true
        after
          300 -> false
        end

      assert %{
               answer: answer,
               boot: state.boot,
               live: state.owners[{ctx.athanor_id, row.id}].live?,
               greeted_again: greeted_again
             } == %{
               answer: if(what == :list, do: {:ok, []}, else: :ok),
               boot: "bb_second",
               live: true,
               greeted_again: false
             }
    end
  end

  test "a second reset beside a first reads the busy sentence at the provider, and the first " <>
         "succeeds",
       %{ctx: ctx, fake: fake, controller: controller} do
    {:ok, %{id: home}} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "claude",
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        config_json: Jason.encode!(%{"command" => "npx -y @anthropic-ai/claude", "env" => %{}})
      })

    reset = fn ->
      with {:error, reason} <-
             Provider.handle("mcp_servers", ctx, %{"action" => "reset_home", "name" => "claude"}),
           do: {:error, Sanctum.Refusals.render(reason)}
    end

    Scripted.hold(fake, "home", 30_000)
    first = Task.async(reset)
    held = held_message("home")
    second = reset.()
    if is_pid(held), do: send(held, :go)

    assert %{first: Task.await(first, 15_000), second: second} == %{
             first: {:ok, %{reset: "claude"}},
             second: {:error, @busy}
           }

    assert_received {:control, "home", %{"op" => "reset", "home_id" => ^home}, _fields}
    refute_received {:control, "home", _message, _fields}
    await_idle(controller)
  end
end
