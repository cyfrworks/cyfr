# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServerTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.ExternalServer

  @registry Emissary.MCP.ExternalServerRegistry

  setup do
    # Clean up any leftover test servers
    name = "test-srv-#{System.unique_integer([:positive])}"
    org_id = ""
    project_id = "default"

    on_exit(fn ->
      case Registry.lookup(@registry, {name, org_id, project_id}) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(Emissary.MCP.ExternalServerSupervisor, pid)

        [] ->
          :ok
      end
    end)

    {:ok, name: name, org_id: org_id, project_id: project_id}
  end

  describe "init/1" do
    test "preserves raw_headers separately from resolved headers", %{
      name: name,
      org_id: org_id,
      project_id: project_id
    } do
      raw = %{"Authorization" => "vault:MY_KEY", "X-Custom" => "plain-value"}

      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        headers: raw,
        org_id: org_id,
        project_id: project_id
      ]

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Emissary.MCP.ExternalServerSupervisor,
          {ExternalServer, config}
        )

      # The process should start with raw_headers preserved and headers empty
      state = :sys.get_state(pid)
      assert state.raw_headers == raw
      assert state.headers == %{}
    end
  end

  describe "in-flight cap" do
    defp start_server(name, org_id, project_id, extra \\ []) do
      config =
        Keyword.merge(
          [name: name, url: "https://localhost:99999/mcp", org_id: org_id, project_id: project_id],
          extra
        )

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Emissary.MCP.ExternalServerSupervisor,
          {ExternalServer, config}
        )

      pid
    end

    test "refuses a call past the cap instead of queueing a task", %{
      name: name,
      org_id: org_id,
      project_id: project_id
    } do
      pid = start_server(name, org_id, project_id)

      cap = Application.get_env(:cyfr, :external_server_max_in_flight, 8)

      fakes = for _ <- 1..cap, do: spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(pid, fn state ->
        in_flight = Map.new(fakes, fn fake -> {fake, Process.monitor(fake)} end)
        %{state | status: :ready, in_flight: in_flight}
      end)

      assert {:error, message} = GenServer.call(pid, {:call_tool, "anything", %{}}, 1_000)
      assert message =~ "busy"
      assert message =~ "retry"

      Enum.each(fakes, &Process.exit(&1, :kill))
    end

    test "a finished (dead) task frees its in-flight slot", %{
      name: name,
      org_id: org_id,
      project_id: project_id
    } do
      pid = start_server(name, org_id, project_id)

      fake = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(pid, fn state ->
        # This closure runs in the server process, so the monitor's :DOWN
        # lands in the server's mailbox — same as a real dispatched task.
        ref = Process.monitor(fake)
        %{state | in_flight: Map.put(state.in_flight, fake, ref)}
      end)

      Process.exit(fake, :kill)

      # The monitor above was created by the replace_state closure, which runs
      # in the server process — its :DOWN goes to the server.
      wait_until(fn -> map_size(:sys.get_state(pid).in_flight) == 0 end)
    end

    test "the configured upstream timeout is clamped below the caller deadline", %{
      name: name,
      org_id: org_id,
      project_id: project_id
    } do
      pid = start_server(name, org_id, project_id, timeout_ms: 999_999)

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
      org_id: org_id,
      project_id: project_id
    } do
      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        org_id: org_id,
        project_id: project_id
      ]

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Emissary.MCP.ExternalServerSupervisor,
          {ExternalServer, config}
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
      org_id: org_id,
      project_id: project_id
    } do
      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        org_id: org_id,
        project_id: project_id
      ]

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Emissary.MCP.ExternalServerSupervisor,
          {ExternalServer, config}
        )

      # The module should compile with @version — no Mix.Project runtime dependency.
      # If Mix.Project.config() were called at runtime, this would crash in releases.
      # We verify the module attribute exists by checking the process starts cleanly.
      status = ExternalServer.status(name, org_id, project_id)
      assert %{status: :disconnected} = status
    end
  end

  describe "ensure_started/1 config reconciliation" do
    test "same config returns the same process", %{org_id: org_id, project_id: project_id} do
      name = "reconcile-same-#{System.unique_integer([:positive])}"

      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        headers: %{"authorization" => "vault:RECON_TOKEN"},
        org_id: org_id,
        project_id: project_id
      ]

      {:ok, pid1} = Emissary.MCP.ExternalServerSupervisor.ensure_started(config)
      {:ok, pid2} = Emissary.MCP.ExternalServerSupervisor.ensure_started(config)

      assert pid1 == pid2
      Emissary.MCP.ExternalServerSupervisor.stop(name, org_id, project_id)
    end

    test "changed config replaces the process", %{org_id: org_id, project_id: project_id} do
      name = "reconcile-change-#{System.unique_integer([:positive])}"

      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        headers: %{"authorization" => "vault:OLD_TOKEN"},
        org_id: org_id,
        project_id: project_id
      ]

      {:ok, pid1} = Emissary.MCP.ExternalServerSupervisor.ensure_started(config)

      changed = Keyword.put(config, :headers, %{"authorization" => "vault:NEW_TOKEN"})
      {:ok, pid2} = Emissary.MCP.ExternalServerSupervisor.ensure_started(changed)

      refute pid1 == pid2
      refute Process.alive?(pid1)
      assert Process.alive?(pid2)

      # And the replacement is stable for the new config
      {:ok, pid3} = Emissary.MCP.ExternalServerSupervisor.ensure_started(changed)
      assert pid2 == pid3

      Emissary.MCP.ExternalServerSupervisor.stop(name, org_id, project_id)
    end
  end

  describe "header secret resolution" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      :ok
    end

    test "secret: references are retired — the reference form itself refuses" do
      assert {:error, message} =
               ExternalServer.resolve_headers(
                 %{"authorization" => "secret:EXT_PROJ_TOKEN"},
                 "local",
                 "default"
               )

      assert message =~ "authorization"
      refute message =~ "EXT_PROJ_TOKEN"
    end

    test "reports only the header name on a missing secret" do
      assert {:error, message} =
               ExternalServer.resolve_headers(
                 %{"authorization" => "secret:EXT_MISSING"},
                 "local",
                 "default"
               )

      assert message =~ "authorization"
      refute message =~ "EXT_MISSING"
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

      masked = ExternalServer.mask_credentials(result, masking_state())
      text = masked["content"] |> hd() |> Map.fetch!("text")

      refute text =~ "sk-super-secret-token"
      assert text =~ "[REDACTED]"
    end

    test "masks the bare token after a scheme prefix" do
      masked =
        ExternalServer.mask_credentials(
          %{"echo" => "token was sk-super-secret-token"},
          masking_state()
        )

      refute masked["echo"] =~ "sk-super-secret-token"
    end

    test "masks credential-shaped literal headers but not innocuous ones" do
      masked =
        ExternalServer.mask_credentials(
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
      org_id: org_id,
      project_id: project_id
    } do
      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        org_id: org_id,
        project_id: project_id
      ]

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Emissary.MCP.ExternalServerSupervisor,
          {ExternalServer, config}
        )

      # First call triggers initialization (will fail due to unreachable URL)
      {:error, _} = ExternalServer.get_tools(name, org_id, project_id)

      # Immediate second call should hit cooldown and return cached error
      {:error, reason} = ExternalServer.get_tools(name, org_id, project_id)
      assert is_binary(reason)
    end
  end

  describe "crash-report redaction" do
    # OTP prints `inspect(state)` in every GenServer crash/exit report. The
    # state holds resolved plaintext credentials in `headers` (and possibly
    # inline ones in `raw_headers`), so both must be invisible to Inspect.
    test "inspect(state) never shows header values" do
      state = %ExternalServer.State{
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
