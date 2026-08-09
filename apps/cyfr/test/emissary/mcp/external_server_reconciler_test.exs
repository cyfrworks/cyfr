# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServerReconcilerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Emissary.MCP.ExternalServerReconciler
  alias Sanctum.Vault

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    test_pid = self()
    handler_id = "reconciler-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:emissary, :external_server, :reconciled],
      fn _event, _measure, metadata, _cfg -> send(test_pid, {:reconciled, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    original = Application.get_env(:cyfr, :external_server_reconciler_enabled)
    Application.put_env(:cyfr, :external_server_reconciler_enabled, true)

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:cyfr, :external_server_reconciler_enabled),
        else: Application.put_env(:cyfr, :external_server_reconciler_enabled, original)
    end)

    start_supervised!(ExternalServerReconciler)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp sync_reconciler, do: :sys.get_state(ExternalServerReconciler)

  test "a rotate of a referenced entry restarts the referencing server", %{ctx: ctx} do
    {:ok, entry} =
      Vault.create(ctx, %{
        name: "gh-header-token",
        kind: "api_key",
        fields: %{"token" => "ghp_original"}
      })

    {:ok, _} =
      Arca.McpServerStorage.put(ctx, %{
        name: "refsrv",
        url: "https://127.0.0.1:9/mcp",
        config_json:
          Jason.encode!(%{
            "headers" => %{"authorization" => "vault:gh-header-token"},
            "timeout_ms" => 1_000
          })
      })

    {:ok, _} =
      Vault.rotate(ctx, %{
        id: entry.id,
        fields: %{"token" => "ghp_rotated"},
        expected_payload_rev: 0
      })

    sync_reconciler()
    assert_receive {:reconciled, %{server: "refsrv"}}, 2_000
  end

  test "unrelated entries and non-referencing servers are untouched", %{ctx: ctx} do
    {:ok, entry} =
      Vault.create(ctx, %{name: "unrelated", kind: "api_key", fields: %{"k" => "v"}})

    {:ok, _} =
      Arca.McpServerStorage.put(ctx, %{
        name: "quietsrv",
        url: "https://127.0.0.1:9/mcp",
        config_json:
          Jason.encode!(%{
            "headers" => %{"authorization" => "secret:SOME_TOKEN"},
            "timeout_ms" => 1_000
          })
      })

    {:ok, _} = Vault.revoke(ctx, entry.id)
    sync_reconciler()

    refute_receive {:reconciled, %{server: "quietsrv"}}, 200
  end

  test "creating a server with a vault-referencing credential header is accepted", %{ctx: ctx} do
    admin_ctx = %{ctx | permissions: MapSet.new([:*])}

    # Unreachable URL: creation should still validate and persist the row.
    result =
      Emissary.MCP.ExternalProvider.handle("mcp_servers", admin_ctx, %{
        "action" => "create",
        "name" => "vaultref",
        "config" => %{
          "url" => "https://127.0.0.1:9/mcp",
          "headers" => %{"authorization" => "vault:gh-header-token"}
        }
      })

    case result do
      {:ok, _} -> assert {:ok, _} = Arca.McpServerStorage.get(ctx, "vaultref")
      # Creation may fail on the unreachable probe, but never on validation.
      {:error, message} -> refute message =~ "looks like a credential"
    end
  end

  test "a revoked referenced entry can no longer resolve its header", %{ctx: ctx} do
    {:ok, entry} =
      Vault.create(ctx, %{
        name: "revoke-me",
        kind: "api_key",
        fields: %{"token" => "ghp_live"}
      })

    # While active, the header resolves through the host-side unseal path.
    assert {:ok, %{"token" => "ghp_live"}} =
             Sanctum.VaultReader.unseal_by_name(ctx.org_id, ctx.project_id, "revoke-me")

    {:ok, _} = Vault.revoke(ctx, entry.id)

    # After revocation the same reference fails closed.
    assert {:error, _} =
             Sanctum.VaultReader.unseal_by_name(ctx.org_id, ctx.project_id, "revoke-me")
  end

  test "the catch-all handle_info survives and logs an unexpected message" do
    pid = Process.whereis(ExternalServerReconciler)
    assert is_pid(pid)

    log =
      capture_log(fn ->
        send(pid, :unexpected_test_message)
        # Force a synchronous round-trip so the message is processed.
        :sys.get_state(ExternalServerReconciler)
      end)

    assert Process.alive?(pid)
    assert log =~ "unexpected message"
  end
end
