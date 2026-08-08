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
      raw = %{"Authorization" => "secret:MY_KEY", "X-Custom" => "plain-value"}

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

  describe "stop_all_for_tenant" do
    test "stops all servers for a tenant", %{org_id: org_id, project_id: project_id} do
      s1 = "stop-all-1-#{System.unique_integer([:positive])}"
      s2 = "stop-all-2-#{System.unique_integer([:positive])}"

      {:ok, pid1} =
        Emissary.MCP.ExternalServerSupervisor.ensure_started(
          name: s1,
          url: "https://localhost:99999/mcp",
          org_id: org_id,
          project_id: project_id
        )

      {:ok, pid2} =
        Emissary.MCP.ExternalServerSupervisor.ensure_started(
          name: s2,
          url: "https://localhost:99999/mcp",
          org_id: org_id,
          project_id: project_id
        )

      # Both should be running
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)

      # Stop all for this tenant
      Emissary.MCP.ExternalServerSupervisor.stop_all_for_tenant(org_id, project_id)

      # Both processes should be dead
      refute Process.alive?(pid1)
      refute Process.alive?(pid2)
    end

    test "does not affect servers for other tenants", %{org_id: org_id, project_id: project_id} do
      s1 = "tenant-a-#{System.unique_integer([:positive])}"
      s2 = "tenant-b-#{System.unique_integer([:positive])}"

      other_org = "other-org-#{System.unique_integer([:positive])}"

      {:ok, pid1} =
        Emissary.MCP.ExternalServerSupervisor.ensure_started(
          name: s1,
          url: "https://localhost:99999/mcp",
          org_id: org_id,
          project_id: project_id
        )

      {:ok, pid2} =
        Emissary.MCP.ExternalServerSupervisor.ensure_started(
          name: s2,
          url: "https://localhost:99999/mcp",
          org_id: other_org,
          project_id: project_id
        )

      # Stop only the first tenant
      Emissary.MCP.ExternalServerSupervisor.stop_all_for_tenant(org_id, project_id)

      # First tenant's server should be dead
      refute Process.alive?(pid1)

      # Other tenant's server should still be running
      assert Process.alive?(pid2)

      # Cleanup
      Emissary.MCP.ExternalServerSupervisor.stop(s2, other_org, project_id)
    end
  end

  describe "ensure_started/1 config reconciliation" do
    test "same config returns the same process", %{org_id: org_id, project_id: project_id} do
      name = "reconcile-same-#{System.unique_integer([:positive])}"

      config = [
        name: name,
        url: "https://localhost:99999/mcp",
        headers: %{"authorization" => "secret:RECON_TOKEN"},
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
        headers: %{"authorization" => "secret:OLD_TOKEN"},
        org_id: org_id,
        project_id: project_id
      ]

      {:ok, pid1} = Emissary.MCP.ExternalServerSupervisor.ensure_started(config)

      changed = Keyword.put(config, :headers, %{"authorization" => "secret:NEW_TOKEN"})
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

    test "secret: references are retired — even a live row cannot resolve" do
      # The secrets plane is going; a stale header reference fails closed
      # with an opaque outward error, never a value.
      writer =
        Sanctum.Context.build(
          user_id: "partition-writer",
          org_id: "local",
          project_id: "default",
          scope: :project,
          permissions: [:secrets_read, :secrets_write],
          authenticated: true
        )

      :ok = Sanctum.Secrets.set(writer, "EXT_PROJ_TOKEN", "proj-value")

      assert {:error, message} =
               ExternalServer.resolve_headers(
                 %{"authorization" => "secret:EXT_PROJ_TOKEN"},
                 "local",
                 "default"
               )

      assert message =~ "authorization"
      refute message =~ "proj-value"
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
          "authorization" => "secret:MASK_TOKEN",
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
end
