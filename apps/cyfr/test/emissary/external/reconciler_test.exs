# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.ReconcilerTest do
  use ExUnit.Case, async: false

  # Where the cases' entries may go: an external server's credential is
  # resolved by name, and its destination is not what these cases test.
  @destination %{"hosts" => ["api.example.com"]}

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Emissary.External.Reconciler
  alias Sanctum.Vault

  setup tags do
    # The suite's sandbox, started once no other connection holds SQLite's
    # write lock: on a connection that has read, the first write answers
    # busy at once while another holds it, and the rollback of the case
    # before this one may still hold it.
    Cyfr.Test.Sandbox.setup!(tags)
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

    start_supervised!(Reconciler)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp sync_reconciler, do: :sys.get_state(Reconciler)

  test "a rotate of a referenced entry restarts the referencing server", %{ctx: ctx} do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "gh-header-token",
        kind: "api_key",
        fields: %{"token" => "ghp_original"},
        destination: @destination
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
      Sanctum.TestContext.rotate_vault(ctx, %{
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
      Sanctum.TestContext.create_vault(ctx, %{
        name: "prod-token",
        kind: "api_key",
        fields: %{"token" => "ghp_prod"},
        destination: @destination
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
      Sanctum.TestContext.create_vault(ctx, %{
        name: "bearer-token",
        kind: "api_key",
        fields: %{"token" => "t1"},
        destination: @destination
      })

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
      Sanctum.TestContext.create_vault(ctx, %{
        name: "env-token",
        kind: "api_key",
        fields: %{"token" => "t1"},
        destination: @destination
      })

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

  describe "the member's slot" do
    setup %{ctx: ctx} do
      keys = [
        {Arca.ControlPlane, :standing},
        {Arca.ControlPlane, :generation},
        {Arca.ControlPlane, :slot}
      ]

      saved = Map.new(keys, &{&1, :persistent_term.get(&1, :absent)})

      on_exit(fn ->
        for {key, value} <- saved do
          if value == :absent,
            do: :persistent_term.erase(key),
            else: :persistent_term.put(key, value)
        end
      end)

      test_pid = self()
      handler_id = "reconciler-failed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:cyfr, :emissary, :external_server, :reconcile_failed],
        fn _event, _measure, metadata, _cfg -> send(test_pid, {:reconcile_failed, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      node = "node-reconciler-#{System.unique_integer([:positive])}"
      {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)

      {:ok, entry} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "slot-token",
          kind: "api_key",
          fields: %{"token" => "t1"},
          destination: @destination
        })

      {:ok, server} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          name: "slotsrv",
          url: "https://127.0.0.1:9/mcp",
          config_json:
            Jason.encode!(%{
              "headers" => %{"authorization" => "vault:slot-token"},
              "timeout_ms" => 1_000
            })
        })

      {:ok, slot: slot, entry: entry, server: server}
    end

    test "the epoch is raised under the member's own slot", %{ctx: ctx, entry: entry} do
      {:ok, _} = Vault.revoke(ctx, entry.id)

      sync_reconciler()
      assert_receive {:reconciled, %{server: "slotsrv"}}, 2_000

      assert {:ok, %{epoch: 2, revision: 1}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "slotsrv")
    end

    test "a slot taken over after the member last renewed raises nothing, and the reconcile stays pending",
         %{ctx: ctx, entry: entry, slot: slot} do
      # The row names a successor; this member still believes it holds.
      {1, _} =
        Arca.Repo.update_all(
          from(l in Arca.Schemas.CellLease, where: l.node == ^slot.node),
          set: [owner: slot.node <> "#boot_b", generation: slot.generation + 1, fence: 9]
        )

      {:ok, _} = Vault.revoke(ctx, entry.id)

      assert %{pending: pending} = sync_reconciler()
      assert Map.has_key?(pending, {ctx.athanor_id, entry.id})
      refute_received {:reconciled, %{server: "slotsrv"}}
      refute_received {:reconcile_failed, _}

      assert {:ok, %{epoch: 1, revision: 0}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "slotsrv")
    end

    test "a slot that ran out with no successor raises nothing", %{
      ctx: ctx,
      entry: entry,
      slot: slot
    } do
      past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

      {1, _} =
        Arca.Repo.update_all(
          from(l in Arca.Schemas.CellLease, where: l.node == ^slot.node),
          set: [lease_until: past]
        )

      {:ok, _} = Vault.revoke(ctx, entry.id)

      assert %{pending: pending} = sync_reconciler()
      assert Map.has_key?(pending, {ctx.athanor_id, entry.id})

      assert {:ok, %{epoch: 1}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "slotsrv")
    end
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

    actor = Prima.Actor.in_athanor(ctx.athanor_id)

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
      Emissary.External.ServerSupervisor.ensure_started(
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
      Sanctum.TestContext.create_vault(ctx, %{
        name: "unrelated",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: @destination
      })

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

  # Where the servers below post: an entry they name is bound to it.
  @local_url "https://127.0.0.1:9/mcp"
  @local_destination %{"hosts" => ["127.0.0.1"], "port" => 9}

  test "creating a server with a vault-referencing credential header is accepted", %{ctx: ctx} do
    admin_ctx = %{ctx | permissions: MapSet.new([:*])}
    on_exit(fn -> Emissary.External.ServerSupervisor.stop("vaultref", ctx.athanor_id) end)

    {:ok, _} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "gh-header-token",
        kind: "api_key",
        fields: %{"token" => "ghp_header"},
        destination: @local_destination
      })

    # Unreachable URL: creation validates and persists the row, and the
    # connect it then makes is what fails.
    assert {:ok, %{name: "vaultref"}} =
             Emissary.External.Provider.handle("mcp_servers", admin_ctx, %{
               "action" => "create",
               "name" => "vaultref",
               "config" => %{
                 "url" => @local_url,
                 "headers" => %{"authorization" => "vault:gh-header-token"}
               }
             })

    assert {:ok, _} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "vaultref")
    sync_reconciler()
  end

  test "a revoked referenced entry can no longer resolve its header", %{ctx: ctx} do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "revoke-me",
        kind: "api_key",
        fields: %{"token" => "ghp_live"},
        destination: @destination
      })

    url = "https://api.example.com/mcp"

    # While active, the header resolves through the host-side unseal path.
    assert {:ok, %{"token" => "ghp_live"}} =
             Sanctum.VaultReader.unseal_for(ctx.athanor_id, "revoke-me", url)

    {:ok, _} = Vault.revoke(ctx, entry.id)
    # Drain the reconcile the revoke broadcast triggers, so its DB reads aren't
    # in flight when the sandbox connection is checked in at test teardown.
    sync_reconciler()

    # After revocation the same reference fails closed.
    assert {:error, {:entry_unavailable, "revoked"}} =
             Sanctum.VaultReader.unseal_for(ctx.athanor_id, "revoke-me", url)
  end

  test "an entry rebound elsewhere stops the server that names it, and its next connect is refused",
       %{ctx: ctx} do
    admin_ctx = %{ctx | permissions: MapSet.new([:*])}
    on_exit(fn -> Emissary.External.ServerSupervisor.stop("movedsrv", ctx.athanor_id) end)

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "moved-token",
        kind: "api_key",
        fields: %{"token" => "ghp_moved"},
        destination: @local_destination
      })

    # The URL matches at create: the row is stored and its process started.
    assert {:ok, %{name: "movedsrv"}} =
             Emissary.External.Provider.handle("mcp_servers", admin_ctx, %{
               "action" => "create",
               "name" => "movedsrv",
               "config" => %{
                 "url" => @local_url,
                 "headers" => %{"authorization" => "vault:moved-token"}
               }
             })

    sync_reconciler()

    [{pid, _digest}] =
      Registry.lookup(Emissary.External.ServerRegistry, {"movedsrv", ctx.athanor_id})

    watched = Process.monitor(pid)

    {:ok, _} = Vault.rebind(ctx, %{id: entry.id, destination: @destination})

    sync_reconciler()
    assert_receive {:reconciled, %{server: "movedsrv"}}, 2_000
    assert_receive {:DOWN, ^watched, :process, ^pid, _}, 2_000

    # The next connect reads the entry where it may go now, and refuses
    # before it is unsealed.
    actor = Sanctum.Context.actor(ctx)
    {:ok, %{last_used_at: used}} = Arca.VaultStorage.get(actor, entry.id)
    {:ok, row} = Arca.McpServerStorage.get(actor, "movedsrv")
    assert {:error, sentence} = Emissary.External.Servers.ensure_started(row, ctx)
    assert sentence == Grimoire.render(:destination_mismatch)
    assert {:ok, %{last_used_at: ^used}} = Arca.VaultStorage.get(actor, entry.id)
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
        Emissary.External.ServerSupervisor.ensure_started(
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
      send(Reconciler, :sweep)
      sync_reconciler()
    end

    test "a server whose credential was rotated without an announcement is restarted",
         %{ctx: ctx} do
      {:ok, entry} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "swept-token",
          kind: "api_key",
          fields: %{"token" => "v1"},
          destination: @destination
        })

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
        Sanctum.TestContext.create_vault(ctx, %{
          name: "rebound-token",
          kind: "api_key",
          fields: %{"token" => "v1"},
          destination: @destination
        })

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
        Sanctum.TestContext.create_vault(ctx, %{
          name: "gone-token",
          kind: "api_key",
          fields: %{"token" => "v1"},
          destination: @destination
        })

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
        Sanctum.TestContext.create_vault(ctx, %{
          name: "idle-token",
          kind: "api_key",
          fields: %{"token" => "v1"},
          destination: @destination
        })

      {:ok, pid} =
        Emissary.External.ServerSupervisor.ensure_started(
          name: "idlesrv",
          url: "https://127.0.0.1:9/mcp",
          headers: %{"authorization" => "vault:idle-token"},
          athanor_id: ctx.athanor_id
        )

      assert Emissary.External.Server.vault_revisions(pid) == :none
      watched = Process.monitor(pid)
      sweep!()
      refute_received {:DOWN, ^watched, :process, ^pid, _}
      DynamicSupervisor.terminate_child(Emissary.External.ServerSupervisor, pid)
    end
  end

  test "the catch-all handle_info survives and logs an unexpected message" do
    pid = Process.whereis(Reconciler)
    assert is_pid(pid)

    log =
      capture_log(fn ->
        send(pid, :unexpected_test_message)
        # Force a synchronous round-trip so the message is processed.
        :sys.get_state(Reconciler)
      end)

    assert Process.alive?(pid)
    assert log =~ "unexpected message"
  end
end
