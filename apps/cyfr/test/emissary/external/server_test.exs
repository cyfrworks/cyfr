# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.ServerTest do
  use ExUnit.Case, async: false

  alias Emissary.External.Server

  @registry Emissary.External.ServerRegistry

  setup do
    # Clean up any leftover test servers
    name = "test-srv-#{System.unique_integer([:positive])}"
    athanor_id = "ath_test"

    on_exit(fn ->
      case Registry.lookup(@registry, {name, athanor_id}) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(Emissary.External.ServerSupervisor, pid)

        [] ->
          :ok
      end
    end)

    {:ok, name: name, athanor_id: athanor_id}
  end

  describe "init/1" do
    test "preserves raw_headers separately from resolved headers", %{
      name: name,
      athanor_id: athanor_id
    } do
      raw = %{"Authorization" => "vault:MY_KEY", "X-Custom" => "plain-value"}

      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        headers: raw,
        athanor_id: athanor_id
      ]

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Emissary.External.ServerSupervisor,
          {Server, config}
        )

      # The process should start with raw_headers preserved and headers empty
      state = :sys.get_state(pid)
      assert state.raw_headers == raw
      assert state.headers == %{}
    end
  end

  describe "in-flight cap" do
    defp start_server(name, athanor_id, extra \\ []) do
      config =
        Keyword.merge(
          [name: name, url: "https://localhost:99999/mcp", athanor_id: athanor_id],
          extra
        )

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Emissary.External.ServerSupervisor,
          {Server, config}
        )

      pid
    end

    test "refuses a call past the cap instead of queueing a task", %{
      name: name,
      athanor_id: athanor_id
    } do
      pid = start_server(name, athanor_id)

      cap = Application.get_env(:cyfr, :external_server_max_in_flight, 8)

      fakes = for _ <- 1..cap, do: spawn(fn -> Process.sleep(:infinity) end)
      caller = self()

      :sys.replace_state(pid, fn state ->
        in_flight =
          Map.new(fakes, fn fake ->
            {fake, {Process.monitor(fake), {caller, make_ref()}, Process.monitor(caller)}}
          end)

        %{state | status: :ready, in_flight: in_flight}
      end)

      assert {:error, message} = GenServer.call(pid, {:call_tool, "anything", %{}}, 1_000)
      assert message =~ "busy"
      assert message =~ "retry"

      Enum.each(fakes, &Process.exit(&1, :kill))
    end

    test "a finished (dead) task frees its in-flight slot", %{
      name: name,
      athanor_id: athanor_id
    } do
      pid = start_server(name, athanor_id)

      fake = spawn(fn -> Process.sleep(:infinity) end)

      caller = self()

      :sys.replace_state(pid, fn state ->
        # This closure runs in the server process, so the monitor's :DOWN
        # lands in the server's mailbox — same as a real dispatched task.
        ref = Process.monitor(fake)
        entry = {ref, {caller, make_ref()}, Process.monitor(caller)}
        %{state | in_flight: Map.put(state.in_flight, fake, entry)}
      end)

      Process.exit(fake, :kill)

      # The monitor above was created by the replace_state closure, which runs
      # in the server process — its :DOWN goes to the server.
      wait_until(fn -> map_size(:sys.get_state(pid).in_flight) == 0 end)
    end

    test "a stopped server ends its calls in flight and answers their callers", %{
      name: name,
      athanor_id: athanor_id
    } do
      pid = start_server(name, athanor_id)
      task = spawn(fn -> Process.sleep(:infinity) end)
      watched = Process.monitor(task)
      tag = make_ref()
      caller = self()

      :sys.replace_state(pid, fn state ->
        entry = {Process.monitor(task), {caller, tag}, Process.monitor(caller)}
        %{state | in_flight: Map.put(state.in_flight, task, entry)}
      end)

      :ok = Emissary.External.ServerSupervisor.stop(name, athanor_id)

      assert_receive {:DOWN, ^watched, :process, ^task, :killed}, 5_000
      assert_receive {^tag, {:error, {:uncertain, message}}}, 5_000
      assert message =~ "stopped"
    end

    test "the configured upstream timeout is clamped below the caller deadline", %{
      name: name,
      athanor_id: athanor_id
    } do
      pid = start_server(name, athanor_id, timeout_ms: 999_999)

      state = :sys.get_state(pid)
      assert state.timeout_ms == 110_000
    end
  end

  defp wait_until(fun, deadline_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    unless fun.() do
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition not met within #{deadline_ms}ms")
      end

      Process.sleep(10)
      wait_until(fun, deadline_ms)
    end
  end

  describe "handle_info/2" do
    test "handles unexpected messages without crashing", %{
      name: name,
      athanor_id: athanor_id
    } do
      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        athanor_id: athanor_id
      ]

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Emissary.External.ServerSupervisor,
          {Server, config}
        )

      # Send unexpected message — should not crash
      send(pid, :unexpected_message)
      send(pid, {:some, :tuple, "data"})

      # Process should still be alive
      assert Process.alive?(pid)
    end
  end

  describe "version attribute" do
    test "uses compile-time version in initialize params", %{
      name: name,
      athanor_id: athanor_id
    } do
      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        athanor_id: athanor_id
      ]

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Emissary.External.ServerSupervisor,
          {Server, config}
        )

      # The module should compile with @version — no Mix.Project runtime dependency.
      # If Mix.Project.config() were called at runtime, this would crash in releases.
      # We verify the module attribute exists by checking the process starts cleanly.
      status = Server.status(name, athanor_id)
      assert %{status: :disconnected} = status
    end
  end

  describe "ensure_started/1 config reconciliation" do
    test "same config returns the same process", %{athanor_id: athanor_id} do
      name = "reconcile-same-#{System.unique_integer([:positive])}"

      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        headers: %{"authorization" => "vault:RECON_TOKEN"},
        athanor_id: athanor_id
      ]

      {:ok, pid1} = Emissary.External.ServerSupervisor.ensure_started(config)
      {:ok, pid2} = Emissary.External.ServerSupervisor.ensure_started(config)

      assert pid1 == pid2
      Emissary.External.ServerSupervisor.stop(name, athanor_id)
    end

    test "changed config replaces the process", %{athanor_id: athanor_id} do
      name = "reconcile-change-#{System.unique_integer([:positive])}"

      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        headers: %{"authorization" => "vault:OLD_TOKEN"},
        athanor_id: athanor_id
      ]

      {:ok, pid1} = Emissary.External.ServerSupervisor.ensure_started(config)

      changed = Keyword.put(config, :headers, %{"authorization" => "vault:NEW_TOKEN"})
      {:ok, pid2} = Emissary.External.ServerSupervisor.ensure_started(changed)

      refute pid1 == pid2
      refute Process.alive?(pid1)
      assert Process.alive?(pid2)

      # And the replacement is stable for the new config
      {:ok, pid3} = Emissary.External.ServerSupervisor.ensure_started(changed)
      assert pid2 == pid3

      Emissary.External.ServerSupervisor.stop(name, athanor_id)
    end
  end

  describe "header vault resolution" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      :ok
    end

    test "reports only the header name on a missing vault entry" do
      assert {:error, message} =
               Server.resolve_headers(
                 %{"authorization" => "vault:EXT_MISSING"},
                 "ath_test"
               )

      assert message =~ "authorization"
      refute message =~ "EXT_MISSING"
    end

    test "a scheme-prefixed reference resolves to the scheme and the entry's value" do
      ctx = Sanctum.TestContext.local()

      {:ok, _} =
        Sanctum.Vault.create(ctx, %{
          name: "ext-bearer",
          kind: "api_key",
          fields: %{"token" => "sk-ext-0123456789"}
        })

      assert {:ok, %{"authorization" => "Bearer sk-ext-0123456789", "accept" => "text/plain"}} =
               Server.resolve_headers(
                 %{"authorization" => "Bearer vault:ext-bearer", "accept" => "text/plain"},
                 ctx.athanor_id
               )
    end

    test "a reference this server does not resolve is refused, never sent as a literal" do
      for unresolved <- ["secret:EXT_TOKEN", "Token secret:EXT_TOKEN"] do
        assert {:error, message} =
                 Server.resolve_headers(%{"x-client" => unresolved}, "ath_test")

        assert message =~ "x-client"
        refute message =~ "EXT_TOKEN"
      end
    end
  end

  describe "credential masking" do
    defp masking_state do
      %{
        raw_headers: %{
          "authorization" => "vault:MASK_TOKEN",
          "x-custom-key" => "literal-credential-value",
          "content-type" => "application/json"
        },
        headers: %{
          "authorization" => "Bearer sk-super-secret-token",
          "x-custom-key" => "literal-credential-value",
          "content-type" => "application/json"
        }
      }
    end

    test "masks resolved secret header values echoed by the upstream" do
      result = %{
        "content" => [
          %{"text" => "debug: got header Bearer sk-super-secret-token from you"}
        ]
      }

      masked = Server.mask_credentials(result, masking_state())
      text = masked["content"] |> hd() |> Map.fetch!("text")

      refute text =~ "sk-super-secret-token"
      assert text =~ "[REDACTED]"
    end

    test "masks the bare token after a scheme prefix" do
      masked =
        Server.mask_credentials(
          %{"echo" => "token was sk-super-secret-token"},
          masking_state()
        )

      refute masked["echo"] =~ "sk-super-secret-token"
    end

    test "masks credential-shaped literal headers but not innocuous ones" do
      masked =
        Server.mask_credentials(
          %{"a" => "literal-credential-value", "b" => "application/json"},
          masking_state()
        )

      assert masked["a"] == "[REDACTED]"
      assert masked["b"] == "application/json"
    end
  end

  describe "reinit backoff" do
    test "respects cooldown on error status retries", %{
      name: name,
      athanor_id: athanor_id
    } do
      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        athanor_id: athanor_id
      ]

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Emissary.External.ServerSupervisor,
          {Server, config}
        )

      # First call triggers initialization (will fail due to unreachable URL)
      {:error, _} = Server.get_tools(name, athanor_id)

      # Immediate second call should hit cooldown and return cached error
      {:error, reason} = Server.get_tools(name, athanor_id)
      assert is_binary(reason)
    end
  end

  # Each of the three ways a server process is stopped from outside it,
  # with a call already in flight. The call is made to sit unanswered in
  # the process's mailbox by suspending the process first: `:sys`' suspended
  # loop answers a parent exit itself, so the shutdown the supervisor sends
  # ends the process with the call still queued behind it — which is the
  # shape a stop racing a call takes in production, made deterministic.
  describe "a server stopped while a call is in flight" do
    setup do
      Cyfr.Test.Sandbox.setup!()
      Arca.Cache.init()

      ctx = Sanctum.TestContext.local()
      suffix = System.unique_integer([:positive])
      entry_name = "stop-race-#{suffix}"

      {:ok, entry} =
        Sanctum.Vault.create(ctx, %{
          name: entry_name,
          kind: "api_key",
          fields: %{"token" => "ghp_stop_race_0123456789"}
        })

      {:ok, row} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          name: "stop-race-srv-#{suffix}",
          url: "https://127.0.0.1:9/mcp",
          config_json:
            Jason.encode!(%{
              "headers" => %{"authorization" => "vault:#{entry_name}"},
              "timeout_ms" => 1_000
            })
        })

      Application.put_env(:cyfr, :external_server_reconciler_enabled, true)
      on_exit(fn -> Application.put_env(:cyfr, :external_server_reconciler_enabled, false) end)
      start_supervised!(Emissary.External.Reconciler)

      {:ok, ctx: ctx, entry: entry, row: row}
    end

    for {cause, told} <- [
          {:vault, "a vault revocation"},
          {:archived, "an archived athanor"},
          {:restart, "a restart on a config change"}
        ],
        called <- [:get_tools, :reinitialize] do
      test "#{called}/2 answers a typed error, and exits nobody, when #{told} stops the server",
           context do
        assert {:error, {:server_exited, reason}} =
                 answered_after_stop(context, unquote(called), unquote(cause))

        assert {:shutdown, {GenServer, :call, [_pid, _message, _timeout]}} = reason
      end
    end

    defp answered_after_stop(context, called, cause) do
      %{ctx: ctx, row: row} = context

      {:ok, pid} =
        Emissary.External.ServerSupervisor.ensure_started(
          Emissary.External.Servers.server_config(row, ctx)
        )

      :ok = :sys.suspend(pid)

      test = self()
      name = row.name
      athanor_id = ctx.athanor_id

      {caller, ref} =
        spawn_monitor(fn ->
          send(test, {:answered, apply(Server, called, [name, athanor_id])})
        end)

      wait_until(fn -> queued?(pid) end)
      stop_cause(cause, context)

      receive do
        {:answered, answer} ->
          answer

        {:DOWN, ^ref, :process, ^caller, reason} ->
          flunk("the caller was exited with #{inspect(reason)} instead of being answered")
      after
        10_000 -> flunk("the caller was never answered")
      end
    end

    defp queued?(pid),
      do:
        match?(
          {:message_queue_len, queued} when queued > 0,
          Process.info(pid, :message_queue_len)
        )

    defp stop_cause(:vault, %{ctx: ctx, entry: entry}) do
      {:ok, _} = Sanctum.Vault.revoke(ctx, entry.id)
      :sys.get_state(Emissary.External.Reconciler)
    end

    defp stop_cause(:archived, %{ctx: ctx}) do
      Cyfr.Bus.broadcast_global(
        Cyfr.Bus.athanor_archived_global(),
        Cyfr.Bus.AthanorArchived.new(ctx.athanor_id)
      )

      :sys.get_state(Emissary.External.Reconciler)
    end

    defp stop_cause(:restart, %{ctx: ctx, row: row}) do
      {:ok, _replacement} =
        Emissary.External.ServerSupervisor.ensure_started(
          Emissary.External.Servers.server_config(%{row | epoch: row.epoch + 1}, ctx)
        )
    end
  end

  describe "vault revisions" do
    # A connect reads the revision token of every vault entry the server's
    # header and backend env templates name before it resolves any of them,
    # and refuses when the store cannot answer.
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      {:ok, ctx: Sanctum.TestContext.local()}
    end

    defp vault!(ctx, name) do
      {:ok, _} =
        Sanctum.Vault.create(ctx, %{
          name: name,
          kind: "api_key",
          fields: %{"token" => "t-" <> name}
        })
    end

    defp connect(pid), do: GenServer.call(pid, :get_tools, 30_000)

    test "an http connect records every header reference before resolving one", %{
      name: name,
      ctx: ctx
    } do
      vault!(ctx, "rev-header")

      # The second reference names no entry, so resolving the headers fails:
      # what was recorded was recorded before anything was resolved.
      pid =
        start_server(name, ctx.athanor_id,
          headers: %{"authorization" => "vault:rev-header", "x-other" => "vault:rev-missing"}
        )

      assert {:error, _} = connect(pid)

      {:ok, expected} =
        Sanctum.VaultReader.revisions(ctx.athanor_id, ["rev-header", "rev-missing"])

      state = :sys.get_state(pid)
      assert state.vault_revisions == expected
      assert {rev, digest} = expected["rev-header"]
      assert is_integer(rev) and is_binary(digest)
      assert expected["rev-missing"] == :inactive
      assert state.headers == %{}
    end

    test "a stdio connect records every backend env reference before the bridge resolves it",
         %{name: name, ctx: ctx} do
      vault!(ctx, "rev-env")
      vault!(ctx, "rev-env-other")

      pid =
        start_server(name, ctx.athanor_id,
          transport: :stdio,
          id: "srv_rev_#{System.unique_integer([:positive])}",
          epoch: 1,
          backends: [
            %{"name" => "one", "command" => "npx -y one", "env" => %{"TOKEN" => "vault:rev-env"}},
            %{
              "name" => "two",
              "command" => "npx -y two",
              "env" => %{"KEY" => "vault:rev-env-other", "NODE_ENV" => "production"}
            }
          ]
        )

      # No bridge runs here: the sync that would resolve the env is refused.
      assert {:error, _} = connect(pid)

      {:ok, expected} =
        Sanctum.VaultReader.revisions(ctx.athanor_id, ["rev-env", "rev-env-other"])

      assert :sys.get_state(pid).vault_revisions == expected
      assert map_size(expected) == 2
    end

    test "a store that cannot answer refuses the connect as unavailable, resolving nothing", %{
      name: name,
      ctx: ctx
    } do
      vault!(ctx, "rev-outage")
      pid = start_server(name, ctx.athanor_id, headers: %{"authorization" => "vault:rev-outage"})

      Arca.Repo.query!("ALTER TABLE vault_entries RENAME TO vault_entries_unreadable")

      assert {:error, {:unavailable, "Vault"}} = connect(pid)

      state = :sys.get_state(pid)
      assert state.vault_revisions == nil
      assert state.headers == %{}
    end

    test "a server that names no vault entry records nothing and reads nothing", %{
      name: name,
      ctx: ctx
    } do
      pid = start_server(name, ctx.athanor_id, headers: %{"accept" => "application/json"})
      Arca.Repo.query!("ALTER TABLE vault_entries RENAME TO vault_entries_unreadable")

      assert {:error, reason} = connect(pid)
      refute reason == {:unavailable, "Vault"}
      assert :sys.get_state(pid).vault_revisions == %{}
    end
  end

  describe "crash-report redaction" do
    # OTP prints `inspect(state)` in every GenServer crash/exit report. The
    # state holds resolved plaintext credentials in `headers` (and possibly
    # inline ones in `raw_headers`), so both must be invisible to Inspect.
    test "inspect(state) never shows header values" do
      state = %Server.State{
        name: "leaky",
        url: "https://mcp.example.com",
        raw_headers: %{"authorization" => "vault:github-token"},
        headers: %{"authorization" => "Bearer ghp_plaintext_credential"}
      }

      rendered = inspect(state)
      refute rendered =~ "ghp_plaintext_credential"
      refute rendered =~ "vault:github-token"
      assert rendered =~ "leaky"
    end
  end
end
