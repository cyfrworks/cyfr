# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.ServerTest do
  use ExUnit.Case, async: false

  # Where the cases' entries may go: an external server's credential is
  # resolved by name, and its destination is not what these cases test.
  @destination %{"hosts" => ["api.example.com"]}

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
    setup tags do
      Cyfr.Test.Sandbox.setup!(tags)
      :ok
    end

    @inside "https://api.example.com/mcp"

    test "reports only the header name on a missing vault entry" do
      assert {:error, message} =
               Server.resolve_headers(
                 %{"authorization" => "vault:EXT_MISSING"},
                 {"ath_test", @inside}
               )

      assert message =~ "authorization"
      refute message =~ "EXT_MISSING"
    end

    test "a scheme-prefixed reference resolves to the scheme and the entry's value" do
      ctx = Sanctum.TestContext.local()

      {:ok, _} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "ext-bearer",
          kind: "api_key",
          fields: %{"token" => "sk-ext-0123456789"},
          destination: @destination
        })

      assert {:ok, %{"authorization" => "Bearer sk-ext-0123456789", "accept" => "text/plain"}} =
               Server.resolve_headers(
                 %{"authorization" => "Bearer vault:ext-bearer", "accept" => "text/plain"},
                 {ctx.athanor_id, @inside}
               )
    end

    test "an entry whose destination does not cover the server's URL is refused unsealed" do
      ctx = Sanctum.TestContext.local()

      {:ok, entry} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "openai-key",
          kind: "api_key",
          fields: %{"token" => "sk-openai-0123456789"},
          destination: %{"hosts" => ["api.openai.com"], "paths" => ["/v1"]}
        })

      headers = %{"authorization" => "Bearer vault:openai-key"}

      for url <- [
            "https://evil.example/mcp",
            "https://api.openai.com/v2/mcp",
            nil
          ] do
        assert {:error, :destination_mismatch} =
                 Server.resolve_headers(headers, {ctx.athanor_id, url}),
               inspect(url)
      end

      assert {:ok, row} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), entry.id)
      assert row.last_used_at == nil

      # Inside the entry's host and paths, it is sent.
      assert {:ok, %{"authorization" => "Bearer sk-openai-0123456789"}} =
               Server.resolve_headers(headers, {ctx.athanor_id, "https://api.openai.com/v1/mcp"})
    end

    test "a reference this server does not resolve is refused, never sent as a literal" do
      for unresolved <- ["secret:EXT_TOKEN", "Token secret:EXT_TOKEN"] do
        assert {:error, message} =
                 Server.resolve_headers(%{"x-client" => unresolved}, {"ath_test", @inside})

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

    test "masks the literal value of every header Prima names a credential carrier" do
      names = Prima.Network.credential_headers() ++ ["X-Session-Token", "X-Client-Secret"]
      values = Map.new(names, &{&1, "literal-value-of-#{&1}"})
      state = %{raw_headers: values, headers: values}

      masked = Server.mask_credentials(%{"echo" => Map.values(values)}, state)
      assert Enum.uniq(masked["echo"]) == ["[REDACTED]"]
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
        Sanctum.TestContext.create_vault(ctx, %{
          name: entry_name,
          kind: "api_key",
          fields: %{"token" => "ghp_stop_race_0123456789"},
          destination: @destination
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
    setup tags do
      Cyfr.Test.Sandbox.setup!(tags)
      {:ok, ctx: Sanctum.TestContext.local()}
    end

    defp vault!(ctx, name) do
      {:ok, _} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: name,
          kind: "api_key",
          fields: %{"token" => "t-" <> name},
          destination: @destination
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

    test "a stdio connect records every backend env reference before the backends service resolves it",
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

      # No backends service runs here: the sync that would resolve the env is refused.
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

      assert {:error, sentence} = connect(pid)
      assert sentence == Grimoire.render({:unavailable, "Vault"})

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
      refute reason == Grimoire.render({:unavailable, "Vault"})
      assert :sys.get_state(pid).vault_revisions == %{}
    end
  end

  describe "a connect to a URL outside a header entry's destination" do
    setup tags do
      Cyfr.Test.Sandbox.setup!(tags)
      {:ok, ctx: Sanctum.TestContext.local()}
    end

    test "fails destination_mismatch, resolving and sending nothing", %{name: name, ctx: ctx} do
      {:ok, entry} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "openai-key",
          kind: "api_key",
          fields: %{"token" => "sk-openai-0123456789"},
          destination: %{"hosts" => ["api.openai.com"]}
        })

      pid =
        start_server(name, ctx.athanor_id,
          url: "https://evil.example/mcp",
          headers: %{"Authorization" => "vault:openai-key"}
        )

      assert {:error, sentence} = GenServer.call(pid, :get_tools, 30_000)
      assert sentence == Grimoire.render(:destination_mismatch)

      state = :sys.get_state(pid)
      assert state.status == :error
      assert state.headers == %{}
      assert state.error == sentence
      refute state.error =~ "openai-key"

      assert {:ok, row} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), entry.id)
      assert row.last_used_at == nil
    end

    test "one covered header beside one that is not unseals neither", %{name: name, ctx: ctx} do
      {:ok, covered} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "covered-key",
          kind: "api_key",
          fields: %{"token" => "sk-covered-0123456789"},
          destination: @destination
        })

      {:ok, _elsewhere} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "openai-key",
          kind: "api_key",
          fields: %{"token" => "sk-openai-0123456789"},
          destination: %{"hosts" => ["api.openai.com"]}
        })

      # The covered header sorts first, so a resolution that unsealed as
      # it went would have read it before meeting the other.
      pid =
        start_server(name, ctx.athanor_id,
          url: "https://api.example.com/mcp",
          headers: %{"a-covered" => "vault:covered-key", "b-elsewhere" => "vault:openai-key"}
        )

      assert {:error, sentence} = GenServer.call(pid, :get_tools, 30_000)

      assert {:ok, %{last_used_at: nil}} =
               Arca.VaultStorage.get(Sanctum.Context.actor(ctx), covered.id)

      assert sentence == Grimoire.render(:destination_mismatch)

      # An entry that is not there refuses the set alike, in the header's
      # own words, with the covered one still unread.
      assert {:error, "Failed to resolve header 'b-missing'"} =
               Server.resolve_headers(
                 %{"a-covered" => "vault:covered-key", "b-missing" => "vault:no-such-key"},
                 {ctx.athanor_id, "https://api.example.com/mcp"}
               )

      assert {:ok, %{last_used_at: nil}} =
               Arca.VaultStorage.get(Sanctum.Context.actor(ctx), covered.id)
    end
  end

  describe "a connect refused by an upstream that echoes the header it was sent" do
    @echoed "sk-echo-server-0123456789"

    setup tags do
      Cyfr.Test.Sandbox.setup!(tags)
      ctx = Sanctum.TestContext.local()
      bypass = Bypass.open()

      {:ok, _} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "echo-key",
          kind: "api_key",
          fields: %{"token" => @echoed},
          destination: %{"hosts" => ["127.0.0.1"], "scheme" => "http", "port" => bypass.port}
        })

      {:ok, ctx: ctx, bypass: bypass, url: "http://127.0.0.1:#{bypass.port}/mcp"}
    end

    for era <- [:modern, :legacy] do
      test "answers its caller with the masked sentence it keeps (#{era} peer)", %{
        name: name,
        ctx: ctx,
        bypass: bypass,
        url: url
      } do
        echo_upstream(bypass, unquote(era))

        pid =
          start_server(name, ctx.athanor_id,
            url: url,
            headers: %{"authorization" => "Bearer vault:echo-key"}
          )

        on_exit(fn -> Emissary.External.ServerSupervisor.stop(name, ctx.athanor_id) end)

        assert {:error, sentence} = GenServer.call(pid, :get_tools, 30_000)
        assert sentence == "rejected credential [REDACTED]"
        assert sentence == :sys.get_state(pid).error

        assert {:error, again} = Server.reinitialize(name, ctx.athanor_id)
        assert again == sentence
        refute inspect({sentence, again}) =~ @echoed
      end
    end
  end

  describe "an upstream that writes the header it was sent into what it answers" do
    @listed "sk-listed-server-0123456789"
    @quoted ~S(sk-quo"te\back-0123456789)
    @hashed "sk-hash-review-0123456789#"
    @pin "pin1234"

    setup tags do
      Cyfr.Test.Sandbox.setup!(tags)
      ctx = Sanctum.TestContext.local()
      bypass = Bypass.open()
      destination = %{"hosts" => ["127.0.0.1"], "scheme" => "http", "port" => bypass.port}

      for {name, token} <- [
            {"listed-key", @listed},
            {"quoted-key", @quoted},
            {"hash-key", @hashed},
            {"pin-key", @pin}
          ] do
        {:ok, _} =
          Sanctum.TestContext.create_vault(ctx, %{
            name: name,
            kind: "api_key",
            fields: %{"token" => token},
            destination: destination
          })
      end

      {:ok, ctx: ctx, bypass: bypass, url: "http://127.0.0.1:#{bypass.port}/mcp"}
    end

    test "a tool listing quoting it is stored and answered masked", %{
      name: name,
      ctx: ctx,
      bypass: bypass,
      url: url
    } do
      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        [auth] = Plug.Conn.get_req_header(conn, "authorization")

        tool = %{
          "name" => "echo_#{auth}",
          "description" => "called with #{auth}",
          "inputSchema" => %{"type" => "object", "description" => auth}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{"tools" => [tool]}
          })
        )
      end)

      pid =
        start_server(name, ctx.athanor_id,
          url: url,
          headers: %{"authorization" => "Bearer vault:listed-key"}
        )

      on_exit(fn -> Emissary.External.ServerSupervisor.stop(name, ctx.athanor_id) end)

      assert {:ok, [tool]} = GenServer.call(pid, :get_tools, 30_000)
      assert tool["description"] == "called with [REDACTED]"
      assert tool["inputSchema"]["description"] == "[REDACTED]"
      refute inspect(tool) =~ @listed
      refute inspect(:sys.get_state(pid).tools) =~ @listed
    end

    # A reason the log line's length cuts inside the value (the message is
    # "<pad> rejected Bearer <value>", so the value starts at byte pad + 17
    # and a 4074-byte pad leaves its first five bytes before the cut), and a
    # credential holding a quote and a backslash, which `inspect/2` prints
    # escaped.
    for {key, token, pad} <- [{"listed-key", @listed, 4074}, {"quoted-key", @quoted, 0}] do
      test "a refusal quoting it is logged masked (#{key}, #{pad} bytes before it)", %{
        name: name,
        ctx: ctx,
        bypass: bypass,
        url: url
      } do
        pad = String.duplicate("x", unquote(pad))

        Bypass.stub(bypass, "POST", "/mcp", fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          request = Jason.decode!(body)
          [auth] = Plug.Conn.get_req_header(conn, "authorization")

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "error" => %{"code" => -32001, "message" => pad <> " rejected " <> auth}
            })
          )
        end)

        pid =
          start_server(name, ctx.athanor_id,
            url: url,
            headers: %{"authorization" => "Bearer vault:#{unquote(key)}"}
          )

        on_exit(fn -> Emissary.External.ServerSupervisor.stop(name, ctx.athanor_id) end)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:error, _sentence} = GenServer.call(pid, :get_tools, 30_000)
          end)

        assert log =~ "Failed to initialize"
        token = unquote(token)
        refute log =~ token
        refute log =~ token |> inspect() |> String.slice(1..-2//1)
        refute log =~ String.slice(token, 0, 5)
      end
    end

    # Forms `inspect/1` prints a value in that are neither the value nor its
    # escaped spelling: a binary holding a byte that is not printable is
    # printed as bytes, and `#` before `{` is escaped as `\#{`.
    for {key, token, shape, suffix} <- [
          {"listed-key", @listed, :unprintable, <<1>>},
          {"hash-key", @hashed, :interpolation, "{x}"}
        ] do
      test "a refusal quoting it in a #{shape} rendering is logged masked", %{
        name: name,
        ctx: ctx,
        bypass: bypass,
        url: url
      } do
        suffix = unquote(suffix)

        answering(bypass, fn request, auth, _modern? ->
          {:json,
           %{
             "jsonrpc" => "2.0",
             "id" => request["id"],
             "error" => %{"code" => -32001, "message" => " rejected " <> auth <> suffix}
           }}
        end)

        log = refused_log(name, ctx, url, unquote(key))
        token = unquote(token)
        refute log =~ token
        refute log =~ String.slice(token, 0, 12)
        refute log =~ Enum.join(:binary.bin_to_list(String.slice(token, 0, 6)), ", ")
      end
    end

    test "a refusal of a megabyte is logged within the line's bounds", %{
      name: name,
      ctx: ctx,
      bypass: bypass,
      url: url
    } do
      answering(bypass, fn request, auth, _modern? ->
        message = String.duplicate("a", 1_000_000) <> <<1>> <> " rejected " <> auth

        {:json,
         %{
           "jsonrpc" => "2.0",
           "id" => request["id"],
           "error" => %{"code" => -32001, "message" => message}
         }}
      end)

      log = refused_log(name, ctx, url, "listed-key")
      assert byte_size(log) < 20_000
      refute log =~ @listed
    end

    test "a tools/list answer that is no listing is refused, not a crash", %{
      name: name,
      ctx: ctx,
      bypass: bypass,
      url: url
    } do
      answering(bypass, fn request, auth, _modern? ->
        {:json, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => auth}}
      end)

      pid = connect_with(name, ctx, url, "listed-key")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, sentence} = GenServer.call(pid, :get_tools, 30_000)
          refute sentence =~ @listed
        end)

      assert Process.alive?(pid)
      refute log =~ @listed
    end

    test "a legacy handshake answering no object is refused, not a crash", %{
      name: name,
      ctx: ctx,
      bypass: bypass,
      url: url
    } do
      answering(bypass, fn request, auth, modern? ->
        case request["method"] do
          "tools/list" when modern? ->
            {:status, 400, "Bad Request"}

          "initialize" ->
            {:json, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => auth}}

          "notifications/initialized" ->
            {:status, 202, ""}

          "tools/list" ->
            {:json, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"tools" => []}}}
        end
      end)

      pid = connect_with(name, ctx, url, "listed-key")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, []} = GenServer.call(pid, :get_tools, 30_000)
        end)

      assert Process.alive?(pid)
      assert %{server_info: nil} = GenServer.call(pid, :status, 5_000)
      refute log =~ @listed
    end

    test "a legacy peer's server info quoting it is stored and answered masked", %{
      name: name,
      ctx: ctx,
      bypass: bypass,
      url: url
    } do
      answering(bypass, fn request, auth, modern? ->
        case request["method"] do
          "tools/list" when modern? ->
            {:status, 400, "Bad Request"}

          "initialize" ->
            {:json,
             %{
               "jsonrpc" => "2.0",
               "id" => request["id"],
               "result" => %{"serverInfo" => %{"name" => "echo", "version" => auth}}
             }}

          "notifications/initialized" ->
            {:status, 202, ""}

          "tools/list" ->
            {:json, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"tools" => []}}}
        end
      end)

      pid = connect_with(name, ctx, url, "listed-key")
      assert {:ok, []} = GenServer.call(pid, :get_tools, 30_000)
      assert %{server_info: info} = GenServer.call(pid, :status, 5_000)
      assert info["version"] == "[REDACTED]"
      refute inspect(:sys.get_state(pid).server_info) =~ @listed
    end

    # A value too short for the mask is kept out by the state's own
    # `Inspect`, which hides the headers: a crash whose report carries the
    # state prints neither.
    test "a crash carrying the state logs no header value", %{
      name: name,
      ctx: ctx,
      bypass: bypass,
      url: url
    } do
      answering(bypass, fn request, _auth, _modern? ->
        {:json, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"tools" => []}}}
      end)

      pid =
        start_server(name, ctx.athanor_id,
          url: url,
          headers: %{"authorization" => "Bearer vault:listed-key", "x-pin" => "vault:pin-key"}
        )

      on_exit(fn -> Emissary.External.ServerSupervisor.stop(name, ctx.athanor_id) end)
      assert {:ok, []} = GenServer.call(pid, :get_tools, 30_000)

      log =
        at_level(:info, fn ->
          ExUnit.CaptureLog.capture_log(fn ->
            catch_exit(GenServer.call(pid, :no_such_call, 5_000))
            wait_down(pid)
          end)
        end)

      assert log =~ "shutting down"
      refute log =~ @pin
      refute log =~ @listed
    end

    # A codec that read the peer's `jsonrpc` back raised with it in the
    # message: on a tool call the rescue logged it, on a connect the crash
    # report printed it.
    test "a tool call answered with an object for jsonrpc logs no header value", %{
      name: name,
      ctx: ctx,
      bypass: bypass,
      url: url
    } do
      answering(bypass, fn request, auth, _modern? ->
        case request["method"] do
          "tools/list" ->
            {:json, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"tools" => []}}}

          "tools/call" ->
            {:json, %{"jsonrpc" => %{"echo" => auth}, "id" => request["id"], "result" => %{}}}
        end
      end)

      pid = connect_with(name, ctx, url, "listed-key")
      assert {:ok, []} = GenServer.call(pid, :get_tools, 30_000)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, answer} = Server.call_tool(pid, "x", %{})
          refute inspect(answer) =~ @listed
        end)

      refute log =~ @listed
    end

    test "a connect answered with an object for jsonrpc is refused, not a crash", %{
      name: name,
      ctx: ctx,
      bypass: bypass,
      url: url
    } do
      answering(bypass, fn request, auth, _modern? ->
        {:json, %{"jsonrpc" => %{"echo" => auth}, "id" => request["id"], "result" => %{}}}
      end)

      pid = connect_with(name, ctx, url, "listed-key")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, sentence} = GenServer.call(pid, :get_tools, 30_000)
          refute sentence =~ @listed
        end)

      assert Process.alive?(pid)
      refute log =~ @listed
    end

    # A transport error can carry a header the upstream sent back: here a
    # Content-Length the client cannot parse, holding the header it was sent.
    test "a transport failure quoting it is logged masked at debug", %{name: name, ctx: ctx} do
      {:ok, listener} =
        :gen_tcp.listen(0, [
          :binary,
          packet: :raw,
          active: false,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      {:ok, port} = :inet.port(listener)

      {:ok, _} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "tcp-key",
          kind: "api_key",
          fields: %{"token" => @listed},
          destination: %{"hosts" => ["127.0.0.1"], "scheme" => "http", "port" => port}
        })

      acceptor = spawn(fn -> echo_content_length(listener) end)
      on_exit(fn -> Process.exit(acceptor, :kill) end)

      pid = connect_with(name, ctx, "http://127.0.0.1:#{port}/mcp", "tcp-key")

      log =
        at_level(:debug, fn ->
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:error, _sentence} = GenServer.call(pid, :get_tools, 30_000)
          end)
        end)

      assert log =~ "failed"
      refute log =~ @listed
    end
  end

  defp at_level(level, fun) do
    previous = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: previous)
    end
  end

  defp wait_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> flunk("the server did not stop")
    end
  end

  # Answers every request with a Content-Length that is the Authorization
  # header it was sent.
  defp echo_content_length(listener) do
    case :gen_tcp.accept(listener, 10_000) do
      {:ok, socket} ->
        {:ok, head} = read_head(socket, "")
        [_, auth] = Regex.run(~r/\r\nauthorization: ([^\r]*)\r\n/i, head)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{auth}\r\n\r\n{}"
        )

        :gen_tcp.close(socket)
        echo_content_length(listener)

      _closed ->
        :ok
    end
  end

  defp read_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_head(socket, acc <> data)
        other -> other
      end
    end
  end

  # An upstream answering each request through `fun`, which reads the
  # request, the Authorization header it was sent and whether the request
  # is the current era's probe (`params._meta`).
  defp answering(bypass, fun) do
    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [auth] = Plug.Conn.get_req_header(conn, "authorization")

      case fun.(request, auth, get_in(request, ["params", "_meta"]) != nil) do
        {:json, payload} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(payload))

        {:status, status, text} ->
          Plug.Conn.resp(conn, status, text)
      end
    end)
  end

  defp connect_with(name, ctx, url, key) do
    pid =
      start_server(name, ctx.athanor_id,
        url: url,
        headers: %{"authorization" => "Bearer vault:#{key}"}
      )

    on_exit(fn -> Emissary.External.ServerSupervisor.stop(name, ctx.athanor_id) end)
    pid
  end

  defp refused_log(name, ctx, url, key) do
    pid = connect_with(name, ctx, url, key)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _sentence} = GenServer.call(pid, :get_tools, 30_000)
    end)
  end

  # An upstream that refuses the connect with an error quoting the
  # Authorization header it was sent: at `tools/list` for a current peer,
  # and at `initialize` for one that answers the current probe as a legacy
  # peer does.
  defp echo_upstream(bypass, era) do
    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [auth] = Plug.Conn.get_req_header(conn, "authorization")

      case {era, request["method"]} do
        {:legacy, "tools/list"} ->
          Plug.Conn.resp(conn, 400, "Bad Request")

        _echoed ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "error" => %{"code" => -32001, "message" => "rejected credential #{auth}"}
            })
          )
      end
    end)
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
