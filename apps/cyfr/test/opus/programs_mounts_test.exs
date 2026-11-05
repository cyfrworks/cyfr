# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ProgramsMountsTest do
  @moduledoc """
  What a login entry's life does to the programs mounted on it, against a
  scripted backends service (`Cyfr.Test.ScriptedBackends`): a revoked or
  deleted entry stops the kept stdio rows that name it and ends its
  sign-ins at once; a renewal releases the owner of a row whose entry no
  longer stands (a restore's `needs_reauth` among them); every open of a
  kept row asks the entry again; a sign-in shows none of its text in its
  status; and the periodic sweep retires every kept home the box holds
  whose entry is gone, while a store that cannot answer retires nothing.
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
        Process.sleep(10)
        await_idle(controller, deadline)
    end
  end

  defp login_entry(ctx, name, program) do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{name: name, kind: "login", program: program})

    entry.id
  end

  # A kept stdio row naming `entry`, with no vault reference in its env:
  # only its mount ties it to the vault.
  defp kept_stdio_row(ctx, entry) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "gh",
        transport: "stdio",
        url: nil,
        home: "kept",
        login_entry_id: entry,
        login_command: "gh auth login",
        config_json:
          Jason.encode!(%{
            "backends" => [
              %{"name" => "github", "command" => "gh mcp", "env" => %{"NODE_ENV" => "production"}}
            ]
          })
      })

    row
  end

  defp pipe_row(ctx) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "claude",
        transport: "pipe",
        url: nil,
        home: "kept",
        login_command: "claude auth login",
        config_json:
          Jason.encode!(%{
            "backends" => [
              %{"name" => "claude", "command" => "npx -y @anthropic-ai/claude-code", "env" => %{}}
            ]
          })
      })

    row
  end

  defp server_pid(ctx, row) do
    [{pid, _digest}] =
      Registry.lookup(Emissary.External.ServerRegistry, {row.name, ctx.athanor_id})

    pid
  end

  defp start_reconciler do
    Prima.Test.Env.put_app_env(:cyfr, :external_server_reconciler_enabled, true)
    start_supervised!(Emissary.External.Reconciler)
  end

  defp revoked(ctx, entry, name) do
    {:ok, _} = Sanctum.Vault.revoke(ctx, entry)

    # The signal a revoke sends, delivered as the bridge delivers it.
    Cyfr.Bus.broadcast_global(Cyfr.Bus.vault_changed_global(), %Cyfr.Bus.VaultEntryChanged{
      athanor_id: ctx.athanor_id,
      entry_id: entry,
      name: name,
      kind: :revoke
    })
  end

  describe "a login entry's end" do
    test "a revoked entry stops the kept stdio row that mounts it, and the next call is refused",
         %{ctx: ctx} do
      start_reconciler()
      entry = login_entry(ctx, "gh-login", "gh")
      row = kept_stdio_row(ctx, entry)
      assert {:ok, [%{"name" => "github__search"}]} = Servers.ensure_started(row, ctx)
      pid = server_pid(ctx, row)
      ref = Process.monitor(pid)

      revoked(ctx, entry, "gh-login")

      # Stopped, its owner released and its row's epoch raised, though no
      # template of its names the entry.
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 3_000
      assert_receive {:control, "release", %{"owners" => [%{"server" => server}]}, _}, 3_000
      assert server == row.id

      {:ok, row} = Arca.McpServerStorage.get_by_id(Sanctum.Context.actor(ctx), row.id)
      assert {:error, sentence} = Servers.ensure_started(row, ctx)
      assert sentence =~ "login entry"
    end

    test "a revoked entry ends its running sign-in at once", %{ctx: ctx} do
      start_reconciler()
      pipe_row(ctx)
      entry = login_entry(ctx, "claude-login", "claude")
      admin = %{ctx | permissions: MapSet.new([:*])}

      assert {:ok, %{session: token}} =
               Provider.handle("mcp_servers", admin, %{
                 "action" => "sign_in",
                 "name" => "claude",
                 "entry" => entry
               })

      assert :ok = Programs.sign_in_attach(admin, token, self())

      revoked(ctx, entry, "claude-login")

      assert_receive {Opus.Programs, ^token, {:ended, :entry_ended}}, 3_000
      assert_receive {:session, "close", _message, _fields}, 3_000
    end

    test "a renewal releases the owner of a row whose entry no longer stands, a restore's needs_reauth included",
         %{ctx: ctx, controller: controller} do
      entry = login_entry(ctx, "gh-login", "gh")
      row = kept_stdio_row(ctx, entry)
      assert {:ok, _tools} = Servers.ensure_started(row, ctx)
      pid = server_pid(ctx, row)
      ref = Process.monitor(pid)

      # No signal: a restore marks entries needs_reauth in the store alone.
      {:ok, _} = Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), entry, "needs_reauth")
      tick(controller)

      assert_receive {:control, "release", %{"owners" => [%{"server" => server}]}, _}, 3_000
      assert server == row.id
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 3_000
    end

    test "every open of a kept row asks its entry again", %{ctx: ctx, fake: fake} do
      entry = login_entry(ctx, "gh-login", "gh")
      row = kept_stdio_row(ctx, entry)
      assert {:ok, _tools} = Servers.ensure_started(row, ctx)
      pid = server_pid(ctx, row)

      # The entry is revoked with no signal and its session ended: the next
      # call must open again, and the open is refused before it is sent.
      {:ok, _} = Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), entry, "revoked")
      Scripted.end_sessions(fake, row.id)
      flush_opens()

      # The call that finds its session ended fails; the next opens again,
      # and that open is refused before anything is sent.
      _ = Emissary.External.Server.call_tool(pid, "github__search", %{})

      assert {:error, message} = Emissary.External.Server.call_tool(pid, "github__search", %{})
      assert message =~ "login entry"
      refute_received {:session, "open", _message, _fields}
    end
  end

  defp flush_opens do
    receive do
      {:session, "open", _message, _fields} -> flush_opens()
    after
      0 -> :ok
    end
  end

  describe "a sign-in recovering a needs_reauth entry" do
    test "renewal keeps the owner for the sign-in alone, which completes, while the row's MCP session stands down",
         %{ctx: ctx, fake: fake, controller: controller} do
      entry = login_entry(ctx, "gh-login", "gh")
      row = kept_stdio_row(ctx, entry)
      assert {:ok, _tools} = Servers.ensure_started(row, ctx)
      server = server_pid(ctx, row)
      server_ref = Process.monitor(server)

      # A restore leaves the entry needs_reauth; the person signs the row in
      # again, as #561 rules.
      {:ok, _} = Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), entry, "needs_reauth")
      admin = %{ctx | permissions: MapSet.new([:*])}

      assert {:ok, %{session: token}} =
               Provider.handle("mcp_servers", admin, %{
                 "action" => "sign_in",
                 "name" => row.name,
                 "entry" => entry
               })

      :ok = Programs.sign_in_attach(admin, token, self())
      [{relay, _}] = Registry.lookup(Opus.Programs.Registry, {:sign_in, token})
      relay_ref = Process.monitor(relay)

      # A tick while the sign-in runs: the MCP holder of the row stands down,
      # the sign-in's owner is kept, renewed and never released.
      tick(controller)
      assert_receive {:DOWN, ^server_ref, :process, ^server, _reason}, 3_000
      refute_receive {:control, "release", %{"owners" => [%{"server" => _}]}, _}, 300
      refute_received {:DOWN, ^relay_ref, :process, _, _}
      refute_received {Programs, ^token, {:ended, _}}

      # Its command exits 0: the sign-in completes and the entry is active.
      Scripted.end_sessions(fake, row.id, 0)
      assert_receive {Programs, ^token, {:ended, :signed_in}}, 5_000

      assert {:ok, %{status: "active"}} =
               Arca.VaultStorage.get(Sanctum.Context.actor(ctx), entry)
    end
  end

  describe "a kept row's status" do
    test "names its stderr's length and never its text", %{ctx: ctx, fake: fake} do
      entry = login_entry(ctx, "gh-login", "gh")
      row = kept_stdio_row(ctx, entry)
      assert {:ok, _tools} = Servers.ensure_started(row, ctx)
      Scripted.set(fake, :stderr_bytes, 12)

      assert {:ok, %{"programs" => [program]}} = Programs.status(ctx.athanor_id, row.id)
      assert %{"home" => "kept", "stderr_bytes" => 12} = program
      refute Map.has_key?(program, "stderr_tail")
    end
  end

  describe "a sign-in's status" do
    test "shows none of the lines it holds or the text sent to it", %{ctx: ctx, fake: fake} do
      row = pipe_row(ctx)
      entry = login_entry(ctx, "claude-login", "claude")
      admin = %{ctx | permissions: MapSet.new([:*])}

      assert {:ok, %{session: token}} =
               Provider.handle("mcp_servers", admin, %{
                 "action" => "sign_in",
                 "name" => "claude",
                 "entry" => entry
               })

      # Held for a subscriber that has not attached yet.
      Scripted.write(fake, row.id, "token sk-signin-canary-0123456789")

      [{relay, _}] = Registry.lookup(Opus.Programs.Registry, {:sign_in, token})

      eventually(fn -> match?([_ | _], :sys.get_state(relay).kept) end)
      status = inspect(:sys.get_status(relay), limit: :infinity, printable_limit: :infinity)

      refute status =~ "sk-signin-canary"
      assert status =~ "redacted"
      Programs.sign_in_close(admin, token)
    end
  end

  defp eventually(check, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    cond do
      check.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("timed out")
      true -> Process.sleep(10) && eventually(check, deadline)
    end
  end

  describe "the sweep of kept homes" do
    test "retires every home the box holds whose entry is gone, and keeps the rest",
         %{ctx: ctx, fake: fake} do
      kept = login_entry(ctx, "kept-login", "claude")
      gone = login_entry(ctx, "gone-login", "claude")
      :ok = Sanctum.Vault.delete(ctx, gone)
      Scripted.set(fake, :homes, MapSet.new([kept, gone, "vlt_no-row-left"]))

      assert :ok = Emissary.External.Reconciler.sweep_homes()

      retired =
        for _ <- 1..2 do
          assert_receive {:control, "home", %{"op" => "retire", "home_id" => id} = message, _},
                         3_000

          {id, message["athanor"]}
        end

      assert Enum.sort(retired) == Enum.sort([{gone, ctx.athanor_id}, {"vlt_no-row-left", "-"}])
      refute_receive {:control, "home", %{"home_id" => ^kept}, _fields}, 200
    end

    test "a store that cannot answer retires nothing", %{ctx: ctx, fake: fake} do
      gone = login_entry(ctx, "gone-login", "claude")
      :ok = Sanctum.Vault.delete(ctx, gone)
      Scripted.set(fake, :homes, MapSet.new([gone]))

      # The vault's table cannot be read: renamed inside the sandbox's
      # transaction, which rolls it back.
      Arca.Repo.query!("ALTER TABLE vault_entries RENAME TO vault_entries_unavailable")
      assert :ok = Emissary.External.Reconciler.sweep_homes()

      refute_receive {:control, "home", _message, _fields}, 300
    end
  end
end
