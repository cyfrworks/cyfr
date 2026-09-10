# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.AthanorsDestroyTest do
  @moduledoc """
  `destroy/1` is the only verb that deletes a tenant's rows.

  Checks that destruction removes tenant rows and credentials as well as stored objects.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "destroy_#{:rand.uniform(1_000_000)}")
    prev = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if prev,
        do: Application.put_env(:cyfr, :base_path, prev),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|destroy-#{n}",
        provider: "github",
        email: "destroy#{n}@example.com",
        verified: true
      })

    {:ok, group} = Athanors.create_group(user.id, "Destroy #{n}")

    ctx =
      Context.build(
        user_id: user.id,
        athanor_id: group.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, group: group, ctx: ctx, user: user}
  end

  # One row in each of the tables whose survival was the point: a sealed
  # credential, a conversation with a message, and a request log.
  defp seed_rows!(ctx) do
    {:ok, _entry} =
      Sanctum.Vault.create(ctx, %{
        name: "to-be-erased",
        kind: "api_key",
        fields: %{"token" => "super-secret-value"}
      })

    {:ok, conv} = Arca.ConversationStorage.create(ctx)

    {:ok, _msg} =
      Arca.ConversationStorage.append(ctx, conv.id, %{
        author: ctx.user_id,
        kind: "text",
        content: "something private"
      })

    :ok = Arca.put(ctx, ["data", "notes.txt"], "kept until destroy")

    # The rest of the roster, written straight through the row plane. Going
    # via each domain API would need a component, a consent walk and a
    # webhook target apiece; what this test has to prove is that
    # `delete_all_for/1` reaches every table, and for that the rows only
    # have to exist. Four of them arrive above through their real APIs,
    # which is what proves the roster describes the real schema.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    a = ctx.athanor_id

    insert_row!("api_keys", %{
      id: "key_#{uniq()}",
      athanor_id: a,
      name: "erase-me",
      key_hash: "hash_#{uniq()}",
      key_prefix: "cyk_test",
      type: "application",
      scope: "[]",
      created_by: ctx.user_id,
      revoked: false,
      inserted_at: now,
      updated_at: now
    })

    insert_row!("mcp_logs", %{
      id: "mcp_#{uniq()}",
      athanor_id: a,
      user_id: ctx.user_id,
      tool: "component",
      status: "completed",
      timestamp: now
    })

    insert_row!("policy_logs", %{
      id: "pol_#{uniq()}",
      athanor_id: a,
      user_id: ctx.user_id,
      event_type: "decision",
      decision: "allow",
      timestamp: now
    })

    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp insert_row!(table, row) do
    {1, _} = Arca.Repo.insert_all(table, [row])
    :ok
  end

  defp count(table, athanor_id) do
    Arca.Repo.aggregate(from(t in table, where: t.athanor_id == ^athanor_id), :count)
  end

  test "refused while the athanor is active — archive first", %{group: group} do
    assert {:error, :not_archived} = Athanors.destroy(group)
  end

  test "erases every athanor-scoped row and the blob tree", %{group: group, ctx: ctx} do
    :ok = seed_rows!(ctx)

    for table <-
          ~w(vault_entries conversations messages memberships api_keys mcp_logs policy_logs) do
      assert count(table, group.id) >= 1, "#{table} was not seeded — the erasure proves nothing"
    end

    {:ok, archived} = Athanors.archive(group)
    assert {:ok, _counts} = Athanors.destroy(archived)

    # Every table on the roster, not just the ones this test seeded — a
    # table left behind is data somebody was told had been deleted.
    #
    # Seven of the nineteen are non-zero going in (asserted above), so for
    # those this is a real before/after. For the remaining twelve it proves
    # the query runs and the roster is walked; `verify_roster!/1`'s two
    # negative tests below are what cover the roster being complete.
    for table <- Arca.TenantTables.roster() do
      assert count(table, group.id) == 0,
             "#{table} still holds rows for a destroyed athanor"
    end

    refute Arca.exists?(ctx, ["data", "notes.txt"])
    assert {:ok, []} = Arca.list_recursive(ctx, [])

    # The tombstone stands: an audit trail that forgets an athanor existed
    # cannot say what happened to it.
    assert {:ok, %{status: "archived"}} = Athanors.get(group.id)
  end

  test "the sealed payload itself is gone, not merely unreferenced", %{group: group, ctx: ctx} do
    :ok = seed_rows!(ctx)

    {:ok, archived} = Athanors.archive(group)
    assert {:ok, _} = Athanors.destroy(archived)

    payloads =
      Arca.Repo.all(from(v in "vault_entries", where: v.athanor_id == ^group.id, select: v.id))

    assert payloads == []
  end

  test "refuses a personal athanor — its owner still names it", %{user: user} do
    # The fixture only makes a group. A personal athanor is what
    # `Sanctum.Provisioning` records on first sign-in, so make that link
    # explicitly rather than hoping the fixture has one — the earlier
    # version of this test guarded on `if is_binary(...)` and asserted
    # nothing whenever it did not.
    {:ok, personal} =
      Athanors.create_group(user.id, "Personal #{System.unique_integer([:positive])}")

    {:ok, _} = Users.set_personal_athanor(user, personal.id)

    {:ok, refreshed} = Users.get(user.id)
    assert refreshed.personal_athanor_id == personal.id

    # `users.personal_athanor_id` is not an athanor-scoped column, so
    # erasure would leave it naming a row whose data is gone: the unique
    # index then blocks minting a replacement and `unarchive_personal/1`
    # reopens a wiped shell.
    assert Sanctum.Tenancy.Users.personal_athanor?(personal.id)

    # Archive the persisted row so destroy/1 reaches the personal-athanor
    # check after rereading its status.
    {:ok, archived} = Athanors.archive(personal)
    assert archived.status == "archived"

    assert {:error, :personal_athanor} = Athanors.destroy(archived)

    # Still there, and still the owner's.
    assert {:ok, %{status: "archived"}} = Athanors.get(personal.id)
    assert Sanctum.Tenancy.Users.personal_athanor?(personal.id)
  end

  describe "the roster is closed" do
    test "every table carrying athanor_id is one destroy/1 deletes" do
      # The boot assertion, run here too so a new athanor-scoped table
      # fails a test rather than only a deployment.
      assert :ok = Arca.TenantTables.verify_roster!()
    end

    # Asserting the check returns `:ok` proves only that today's schema
    # matches today's roster; it says nothing about whether the check can
    # fail. Drive both directions against a real table.
    test "the check raises when a table carrying athanor_id is left off" do
      live = Arca.TenantTables.athanor_scoped_tables()
      omitted = "vault_entries"
      assert omitted in live

      assert_raise RuntimeError, ~r/#{omitted}/, fn ->
        Arca.TenantTables.verify_roster!(Arca.TenantTables.roster() -- [omitted])
      end
    end

    test "the check raises when the roster names a table the schema dropped" do
      assert_raise RuntimeError, ~r/no_such_table/, fn ->
        Arca.TenantTables.verify_roster!(["no_such_table" | Arca.TenantTables.roster()])
      end
    end

    test "the roster names only tables that exist and carry the column" do
      live = Arca.TenantTables.athanor_scoped_tables()

      for table <- Arca.TenantTables.roster() do
        assert table in live,
               "#{table} is on the destroy roster but carries no athanor_id column"
      end
    end

    test "webhook_deliveries is reached through its parent, not by athanor_id" do
      # It has no `athanor_id` of its own, so the roster cannot cover it;
      # relying on ON DELETE CASCADE would be relying on
      # `PRAGMA foreign_keys` being on.
      assert {"webhook_deliveries", :webhook_id, "webhooks"} in Arca.TenantTables.by_parent()
      refute "webhook_deliveries" in Arca.TenantTables.athanor_scoped_tables()
    end
  end
end
