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
      [:cyfr, :emissary, :external_server, :reconciled],
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
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
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

  test "a rename restarts the server still spelling the OLD name", %{ctx: ctx} do
    # A rename must reconcile servers using both the previous and current credential name.
    {:ok, entry} =
      Vault.create(ctx, %{
        name: "prod-token",
        kind: "api_key",
        fields: %{"token" => "ghp_prod"}
      })

    {:ok, _} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "oldnamesrv",
        url: "https://127.0.0.1:9/mcp",
        config_json:
          Jason.encode!(%{
            "headers" => %{"authorization" => "vault:prod-token"},
            "timeout_ms" => 1_000
          })
      })

    :ok = Vault.rename(ctx, entry.id, "prod-token-retired")

    sync_reconciler()
    assert_receive {:reconciled, %{server: "oldnamesrv"}}, 2_000
  end

  test "a scheme-prefixed template is matched by the entry it names", %{ctx: ctx} do
    {:ok, entry} =
      Vault.create(ctx, %{name: "bearer-token", kind: "api_key", fields: %{"token" => "t1"}})

    {:ok, _} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "bearersrv",
        url: "https://127.0.0.1:9/mcp",
        config_json:
          Jason.encode!(%{
            "headers" => %{"authorization" => "Bearer vault:bearer-token"},
            "timeout_ms" => 1_000
          })
      })

    {:ok, _} = Vault.revoke(ctx, entry.id)

    sync_reconciler()
    assert_receive {:reconciled, %{server: "bearersrv"}}, 2_000
  end

  test "a stdio server whose env template references the entry is matched and its epoch raised",
       %{ctx: ctx} do
    {:ok, entry} =
      Vault.create(ctx, %{name: "env-token", kind: "api_key", fields: %{"token" => "t1"}})

    {:ok, %{epoch: 1}} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "envsrv",
        transport: "stdio",
        url: nil,
        config_json:
          Jason.encode!(%{
            "backends" => [
              %{
                "name" => "gh",
                "command" => "npx -y gh",
                "env" => %{"TOKEN" => "vault:env-token"}
              }
            ]
          })
      })

    {:ok, _} = Vault.revoke(ctx, entry.id)

    sync_reconciler()
    assert_receive {:reconciled, %{server: "envsrv"}}, 2_000
    assert {:ok, %{epoch: 2}} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "envsrv")
  end

  test "a signal that names no entry stops every server whose templates reference one",
       %{ctx: ctx} do
    for {name, headers} <- [
          {"vaultsrv", %{"authorization" => "vault:anything"}},
          {"literalsrv", %{"accept" => "application/json"}}
        ] do
      {:ok, _} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          name: name,
          url: "https://127.0.0.1:9/mcp",
          config_json: Jason.encode!(%{"headers" => headers, "timeout_ms" => 1_000})
        })
    end

    actor = Cyfr.Actor.in_athanor(ctx.athanor_id)

    Cyfr.Bus.broadcast_global(
      Cyfr.Bus.vault_changed_global(),
      Cyfr.Bus.VaultEntryChanged.new(actor, :delete, entry_id: "vlt_unnamed")
    )

    sync_reconciler()
    assert_receive {:reconciled, %{server: "vaultsrv"}}, 2_000
    refute_receive {:reconciled, %{server: "literalsrv"}}, 200
  end

  test "an archived athanor has every one of its server processes stopped" do
    athanor_id = "ath_archive_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Emissary.MCP.ExternalServerSupervisor.ensure_started(
        name: "archivedsrv",
        url: "https://127.0.0.1:9/mcp",
        athanor_id: athanor_id
      )

    watched = Process.monitor(pid)

    Cyfr.Bus.broadcast_global(
      Cyfr.Bus.athanor_archived_global(),
      Cyfr.Bus.AthanorArchived.new(athanor_id)
    )

    assert_receive {:DOWN, ^watched, :process, ^pid, _}, 2_000
  end

  test "unrelated entries and non-referencing servers are untouched", %{ctx: ctx} do
    {:ok, entry} =
      Vault.create(ctx, %{name: "unrelated", kind: "api_key", fields: %{"k" => "v"}})

    {:ok, _} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "quietsrv",
        url: "https://127.0.0.1:9/mcp",
        config_json:
          Jason.encode!(%{
            "headers" => %{"authorization" => "vault:SOME_TOKEN"},
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
      Emissary.MCP.McpServersTool.handle("mcp_servers", admin_ctx, %{
        "action" => "create",
        "name" => "vaultref",
        "config" => %{
          "url" => "https://127.0.0.1:9/mcp",
          "headers" => %{"authorization" => "vault:gh-header-token"}
        }
      })

    case result do
      {:ok, _} ->
        assert {:ok, _} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "vaultref")

      # Creation may fail on the unreachable probe, but never on validation.
      {:error, message} ->
        refute message =~ "looks like a credential"
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
             Sanctum.VaultReader.unseal_by_name(ctx.athanor_id, "revoke-me")

    {:ok, _} = Vault.revoke(ctx, entry.id)
    # Drain the reconcile the revoke broadcast triggers, so its DB reads aren't
    # in flight when the sandbox connection is checked in at test teardown.
    sync_reconciler()

    # After revocation the same reference fails closed.
    assert {:error, _} =
             Sanctum.VaultReader.unseal_by_name(ctx.athanor_id, "revoke-me")
  end

  describe "the periodic pass" do
    # A server connected and resolved against `revision`, its entry's
    # revision token (the payload revision and the binding digest).
    defp swept_server!(ctx, name, entry_name) do
      {:ok, _} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          name: name,
          url: "https://127.0.0.1:9/mcp",
          config_json:
            Jason.encode!(%{
              "headers" => %{"authorization" => "vault:" <> entry_name},
              "timeout_ms" => 1_000
            })
        })

      {:ok, pid} =
        Emissary.MCP.ExternalServerSupervisor.ensure_started(
          name: name,
          url: "https://127.0.0.1:9/mcp",
          headers: %{"authorization" => "vault:" <> entry_name},
          athanor_id: ctx.athanor_id
        )

      {:ok, %{^entry_name => revision}} =
        Sanctum.VaultReader.revisions(ctx.athanor_id, [entry_name])

      # What a connect records before it resolves: the revision it read.
      :sys.replace_state(pid, &%{&1 | status: :ready, vault_revisions: %{entry_name => revision}})
      {pid, revision}
    end

    defp sweep! do
      send(ExternalServerReconciler, :sweep)
      sync_reconciler()
    end

    test "a server whose credential was rotated without an announcement is restarted",
         %{ctx: ctx} do
      {:ok, entry} =
        Vault.create(ctx, %{name: "swept-token", kind: "api_key", fields: %{"token" => "v1"}})

      sync_reconciler()
      {pid, {payload_rev, _digest}} = swept_server!(ctx, "sweptsrv", "swept-token")
      watched = Process.monitor(pid)

      # Nothing moved: the pass leaves it serving.
      sweep!()
      refute_received {:DOWN, ^watched, :process, ^pid, _}
      assert Process.alive?(pid)

      # A rotation whose `vault_changed` never reached this member: the
      # payload moves and no announcement is made.
      actor = Sanctum.Context.actor(ctx)
      {:ok, row} = Arca.VaultStorage.get(actor, entry.id)
      :ok = Arca.VaultStorage.rotate_payload(actor, entry.id, payload_rev, row.sealed_payload)

      sweep!()
      assert_receive {:DOWN, ^watched, :process, ^pid, _}, 2_000
      assert_receive {:reconciled, %{server: "sweptsrv", entry_id: nil}}, 2_000
      assert {:ok, %{epoch: epoch}} = Arca.McpServerStorage.get(actor, "sweptsrv")
      assert epoch > 0
    end

    test "a server whose credential was rebound without an announcement is restarted",
         %{ctx: ctx} do
      {:ok, entry} =
        Vault.create(ctx, %{name: "rebound-token", kind: "api_key", fields: %{"token" => "v1"}})

      sync_reconciler()
      {pid, {payload_rev, digest}} = swept_server!(ctx, "reboundsrv", "rebound-token")
      watched = Process.monitor(pid)

      # A rebind whose `vault_changed` never reached this member: the
      # binding moves and the payload does not.
      actor = Sanctum.Context.actor(ctx)
      {:ok, row} = Arca.VaultStorage.get(actor, entry.id)

      {:ok, _blocked} =
        Arca.VaultStorage.move_binding(
          actor,
          entry.id,
          row.binding_digest,
          %{field_names: Jason.encode!(["token", "scope"]), binding_digest: "sha256:rebound"},
          "needs_consent"
        )

      {:ok, %{"rebound-token" => {^payload_rev, moved}}} =
        Sanctum.VaultReader.revisions(ctx.athanor_id, ["rebound-token"])

      refute moved == digest

      sweep!()
      assert_receive {:DOWN, ^watched, :process, ^pid, _}, 2_000
      assert_receive {:reconciled, %{server: "reboundsrv", entry_id: nil}}, 2_000
    end

    test "a server whose entry is no longer active is stopped", %{ctx: ctx} do
      {:ok, entry} =
        Vault.create(ctx, %{name: "gone-token", kind: "api_key", fields: %{"token" => "v1"}})

      sync_reconciler()
      {pid, _revision} = swept_server!(ctx, "gonesrv", "gone-token")
      watched = Process.monitor(pid)

      actor = Sanctum.Context.actor(ctx)
      # Revoked without an announcement reaching this member.
      _ = Arca.VaultStorage.set_status(actor, entry.id, "revoked")

      sweep!()
      assert_receive {:DOWN, ^watched, :process, ^pid, _}, 2_000
    end

    test "a server not yet connected resolved nothing and is left alone", %{ctx: ctx} do
      {:ok, _} =
        Vault.create(ctx, %{name: "idle-token", kind: "api_key", fields: %{"token" => "v1"}})

      {:ok, pid} =
        Emissary.MCP.ExternalServerSupervisor.ensure_started(
          name: "idlesrv",
          url: "https://127.0.0.1:9/mcp",
          headers: %{"authorization" => "vault:idle-token"},
          athanor_id: ctx.athanor_id
        )

      assert Emissary.MCP.ExternalServer.vault_revisions(pid) == :none
      watched = Process.monitor(pid)
      sweep!()
      refute_received {:DOWN, ^watched, :process, ^pid, _}
      DynamicSupervisor.terminate_child(Emissary.MCP.ExternalServerSupervisor, pid)
    end
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
