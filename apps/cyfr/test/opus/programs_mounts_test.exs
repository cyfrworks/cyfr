# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ProgramsMountsTest do
  @moduledoc """
  A kept program's folder is its row's, against a scripted backends
  service (`Cyfr.Test.ScriptedBackends`): its sessions and terminals run in
  the home named by the row's id, with no login entry anywhere; a reset
  names the row; a deleted row ends its terminals at once and then retires
  its home; an archived athanor retires every kept row's home; a terminal
  ends with its program and shows none of its output in its status; and
  the periodic sweep retires every kept home the box holds that no kept
  row of a live athanor holds, while a store that cannot answer retires
  nothing.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Emissary.External.{Provider, Servers}
  alias Opus.Programs

  @root :crypto.strong_rand_bytes(32)

  setup do
    Cyfr.Test.Sandbox.setup!()
    Arca.Cache.init()

    ctx = Sanctum.TestContext.local()
    fake = Scripted.start(self(), @root)
    controller = start_controller(fake)
    on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
    {:ok, ctx: ctx, fake: fake, controller: controller}
  end

  defp start_controller(fake) do
    controller =
      Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)

    assert_receive {:control, "hello", %{"g" => 1}, %{boot: "-"}}, 2_000
    assert_receive {:control, "reconcile", %{"keep" => []}, _fields}, 2_000
    await_idle(controller)
    controller
  end

  defp tick(controller) do
    send(controller, :tick)
    await_idle(controller)
  end

  defp await_idle(controller, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    state = :sys.get_state(controller)

    cond do
      state.inflight == nil and :queue.is_empty(state.urgent) and :queue.is_empty(state.queue) ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the controller did not settle")

      true ->
        # sleep-ok: poll interval of await_idle's bounded wait (3 s) for the controller to settle
        Process.sleep(10)
        await_idle(controller, deadline)
    end
  end

  # A kept mcp program, with no vault reference in its env.
  defp kept_mcp_row(ctx) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "gh",
        transport: "program",
        mark: "mcp",
        url: nil,
        home: "kept",
        config_json:
          Jason.encode!(%{"command" => "gh mcp", "env" => %{"NODE_ENV" => "production"}})
      })

    row
  end

  defp driven_row(ctx, name \\ "claude", home \\ "kept") do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "driven",
        url: nil,
        home: home,
        config_json:
          Jason.encode!(%{"command" => "npx -y @anthropic-ai/claude-code", "env" => %{}})
      })

    row
  end

  defp start_reconciler do
    Prima.Test.Env.put_app_env(:cyfr, :external_server_reconciler_enabled, true)
    start_supervised!(Emissary.External.Reconciler)
  end

  defp admin(ctx), do: %{ctx | permissions: MapSet.new([:*])}

  # The row's terminal, opened as a person opens it, and attached to here.
  defp open!(ctx, row) do
    assert {:ok, %{session: session, program: name}} =
             Provider.handle("mcp_servers", admin(ctx), %{"action" => "open", "name" => row.name})

    assert name == row.name
    assert {:ok, _attached} = Programs.attach(admin(ctx), session)
    session
  end

  describe "a kept row's folder" do
    test "an mcp program's session runs in the home its row's id names, and its tools are " <>
           "the program's own names",
         %{ctx: ctx} do
      row = kept_mcp_row(ctx)
      assert {:ok, [%{"name" => "search"}]} = Servers.ensure_started(row, ctx)

      home_id = row.id

      assert_receive {:session, "open", %{"home_id" => ^home_id, "mode" => "run"} = open, _},
                     2_000

      assert open["program"] == Opus.Programs.Definition.program_name()
    end

    test "a terminal runs in the row's home, and ends with its program", %{
      ctx: ctx,
      fake: fake
    } do
      row = driven_row(ctx)
      session = open!(ctx, row)

      home_id = row.id

      assert_receive {:session, "open", %{"home_id" => ^home_id, "mode" => "terminal"}, _fields},
                     2_000

      Scripted.end_sessions(fake, row.id, 0)
      assert_receive {Programs, ^session, {:ended, :exited}}, 5_000
    end

    test "a reset names the program, and empties its row's home", %{ctx: ctx} do
      row = driven_row(ctx)

      assert {:ok, %{reset: "claude"}} =
               Provider.handle("mcp_servers", admin(ctx), %{
                 "action" => "reset_home",
                 "name" => "claude"
               })

      home_id = row.id
      assert_receive {:control, "home", %{"op" => "reset", "home_id" => ^home_id}, _fields}, 2_000
    end

    test "a renewal keeps a kept row's owner: nothing outside the row decides its folder", %{
      ctx: ctx,
      controller: controller
    } do
      row = kept_mcp_row(ctx)
      assert {:ok, _tools} = Servers.ensure_started(row, ctx)

      tick(controller)
      assert_receive {:control, "renew", %{"owners" => [%{"server" => server}]}, _fields}, 3_000
      assert server == row.id
      refute_receive {:control, "release", _message, _fields}, 300
    end
  end

  describe "a deleted row" do
    test "ends its running terminal at once, then retires its home", %{ctx: ctx} do
      start_reconciler()
      row = driven_row(ctx)
      session = open!(ctx, row)

      assert {:ok, %{deleted: "claude"}} =
               Sanctum.TestContext.confirming(admin(ctx), fn person ->
                 Provider.handle("mcp_servers", person, %{
                   "action" => "delete",
                   "name" => "claude"
                 })
               end)

      assert_receive {Opus.Programs, ^session, {:ended, :row_changed}}, 3_000
      home_id = row.id

      assert_receive {:control, "home", %{"op" => "retire", "home_id" => ^home_id} = retire, _},
                     3_000

      assert retire["athanor"] == ctx.athanor_id
    end

    # A confirmed change to a program's definition ends what runs under
    # the old one at once, as a removal does, and keeps its folder.
    test "a confirmed change ends its running terminal at once and keeps its home",
         %{ctx: ctx} do
      start_reconciler()
      row = driven_row(ctx)
      session = open!(ctx, row)

      assert {:ok, %{epoch: 2}} =
               Sanctum.TestContext.confirming(admin(ctx), fn person ->
                 Provider.handle("mcp_servers", person, %{
                   "action" => "update",
                   "name" => "claude",
                   "epoch" => row.epoch,
                   "config" => %{
                     "transport" => "program",
                     "mark" => "driven",
                     "home" => "kept",
                     "command" => "npx -y @anthropic-ai/claude-code --another",
                     "env" => %{}
                   }
                 })
               end)

      assert_receive {Opus.Programs, ^session, {:ended, :row_changed}}, 3_000
      home_id = row.id
      refute_receive {:control, "home", %{"op" => "retire", "home_id" => ^home_id}, _}, 300
    end

    test "with a scratch home retires nothing", %{ctx: ctx} do
      start_reconciler()
      driven_row(ctx, "scratchy", "scratch")

      assert {:ok, _deleted} =
               Sanctum.TestContext.confirming(admin(ctx), fn person ->
                 Provider.handle("mcp_servers", person, %{
                   "action" => "delete",
                   "name" => "scratchy"
                 })
               end)

      :sys.get_state(Emissary.External.Reconciler)
      refute_receive {:control, "home", _message, _fields}, 300
    end
  end

  test "an archived athanor retires every kept row's home, and no scratch row's", %{ctx: ctx} do
    start_reconciler()
    kept = driven_row(ctx)
    mcp = kept_mcp_row(ctx)
    _scratch = driven_row(ctx, "scratchy", "scratch")

    Cyfr.Bus.broadcast_global(
      Cyfr.Bus.athanor_archived_global(),
      Cyfr.Bus.AthanorArchived.new(ctx.athanor_id)
    )

    retired =
      for _ <- 1..2 do
        assert_receive {:control, "home", %{"op" => "retire", "home_id" => id}, _fields}, 3_000
        id
      end

    assert Enum.sort(retired) == Enum.sort([kept.id, mcp.id])
    refute_receive {:control, "home", _message, _fields}, 300
  end

  describe "a kept row's status" do
    test "names its stderr's length and never its text", %{ctx: ctx, fake: fake} do
      row = kept_mcp_row(ctx)
      assert {:ok, _tools} = Servers.ensure_started(row, ctx)
      Scripted.set(fake, :stderr_bytes, 12)

      assert {:ok, %{"programs" => [program]}} = Programs.status(ctx.athanor_id, row.id)
      assert %{"home" => "kept", "stderr_bytes" => 12} = program
      refute Map.has_key?(program, "stderr_tail")
    end
  end

  describe "a terminal's status" do
    test "shows none of the output it holds or the words its program was started with",
         %{ctx: ctx, fake: fake} do
      row = driven_row(ctx)

      assert {:ok, session} =
               Programs.start(admin(ctx), row.id, %{
                 rows: 24,
                 cols: 80,
                 args: ["--token-word-canary"]
               })

      # Held for whatever attaches later.
      Scripted.write(fake, row.id, "token sk-signin-canary-0123456789")

      [{terminal, _}] = Registry.lookup(Opus.Programs.Registry, {:terminal, session})

      eventually(fn -> :sys.get_state(terminal).tail.bytes != "" end)
      status = inspect(:sys.get_status(terminal), limit: :infinity, printable_limit: :infinity)

      refute status =~ "sk-signin-canary"
      refute status =~ "token-word-canary"
      assert status =~ "#Opus.Programs.Output<"
      assert {:ok, :closed} = Programs.close(admin(ctx), session)
    end
  end

  defp eventually(check, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    cond do
      check.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("timed out")
      # sleep-ok: poll interval of eventually's bounded wait (3 s)
      true -> Process.sleep(10) && eventually(check, deadline)
    end
  end

  describe "the sweep of kept homes" do
    test "retires every home the box holds that no kept row of a live athanor holds, and " <>
           "keeps the rest",
         %{ctx: ctx, fake: fake} do
      kept = driven_row(ctx)
      scratch = driven_row(ctx, "scratchy", "scratch")
      gone = driven_row(ctx, "gone")
      {:ok, _} = Arca.McpServerStorage.delete(Sanctum.Context.actor(ctx), "gone")
      Scripted.set(fake, :homes, MapSet.new([kept.id, scratch.id, gone.id]))

      assert :ok = Emissary.External.Reconciler.sweep_homes()

      retired =
        for _ <- 1..2 do
          assert_receive {:control, "home", %{"op" => "retire", "home_id" => id} = message, _},
                         3_000

          {id, message["athanor"]}
        end

      assert Enum.sort(retired) == Enum.sort([{scratch.id, ctx.athanor_id}, {gone.id, "-"}])
      kept_id = kept.id
      refute_receive {:control, "home", %{"home_id" => ^kept_id}, _fields}, 200
    end

    # A database that ran an adapter catalyst is recreated, not
    # cleaned: the box still holds the homes its rows kept, a catalyst's
    # sessions and its sign-in among them, under ids and an athanor this
    # database never had. The periodic sweep, run while the reconciler
    # holds the control plane, retires each such home whole, under no
    # athanor ("-"), and keeps the home of the new row the recreated
    # install made under the same name.
    test "the periodic sweep retires a recreated database's old home under no athanor, and " <>
           "keeps the new row's of the same name",
         %{ctx: ctx, fake: fake} do
      old_home = "mcp_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      assert {:ok, [{^old_home, nil}]} = Sanctum.Mount.orphaned_homes([old_home])
      live = driven_row(ctx, "claude")
      Scripted.set(fake, :homes, MapSet.new([old_home, live.id]))
      assert Arca.ControlPlane.held?()

      reconciler = start_reconciler()
      send(reconciler, :sweep)

      assert_receive {:control, "home", %{"op" => "retire", "home_id" => ^old_home} = retire, _},
                     3_000

      assert retire["athanor"] == "-"
      live_id = live.id
      refute_receive {:control, "home", %{"home_id" => ^live_id}, _fields}, 300

      assert {:ok, %{id: ^live_id, home: "kept"}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "claude")
    end

    test "a store that cannot answer retires nothing", %{fake: fake} do
      Scripted.set(fake, :homes, MapSet.new(["mcp_no-row-left"]))

      # The programs' table cannot be read: renamed inside the sandbox's
      # transaction, which rolls it back.
      Arca.Repo.query!("ALTER TABLE mcp_servers RENAME TO mcp_servers_unavailable")
      assert :ok = Emissary.External.Reconciler.sweep_homes()

      refute_receive {:control, "home", _message, _fields}, 300
    end
  end
end
