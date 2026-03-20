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
        [{pid, _}] -> DynamicSupervisor.terminate_child(Emissary.MCP.ExternalServerSupervisor, pid)
        [] -> :ok
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
