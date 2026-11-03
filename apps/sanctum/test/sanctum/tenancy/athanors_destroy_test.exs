# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.AthanorsDestroyTest do
  @moduledoc """
  `destroy/1` is the only verb that deletes a tenant's rows: it refuses
  an athanor that is not archived and a person's own athanor, and its
  roster of tenant tables is closed.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.Athanors

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|destroy-#{n}",
        provider: "github",
        email: "destroy#{n}@example.com",
        verified: true
      })

    {:ok, athanor: Sanctum.Test.People.athanor!(user), user: user}
  end

  test "refused while the athanor is active — archive first", %{athanor: athanor} do
    assert {:error, :not_archived} = Athanors.destroy(athanor)
  end

  test "refuses a personal athanor — its person's row names it", %{
    athanor: personal,
    user: user
  } do
    {:ok, refreshed} = Sanctum.Tenancy.Users.get(user.id)
    assert refreshed.personal_athanor_id == personal.id

    # `users.personal_athanor_id` is not an athanor-scoped column, so
    # erasure would leave it naming a row whose data is gone: the unique
    # index then blocks minting a replacement and `Users.allow/1`
    # reopens a wiped shell.
    assert Sanctum.Tenancy.Users.personal_athanor?(personal.id)

    # Archive the persisted row so destroy/1 reaches the personal-athanor
    # check after rereading its status.
    {:ok, archived} = Athanors.archive(personal, force: true)
    assert archived.status == "archived"

    assert {:error, :personal_athanor} = Athanors.destroy(archived)

    # Still there, and still the person's.
    assert {:ok, %{status: "archived"}} = Athanors.get(personal.id)
    assert Sanctum.Tenancy.Users.personal_athanor?(personal.id)
  end

  describe "the roster is closed" do
    test "every table carrying athanor_id is one destroy/1 deletes" do
      # The boot assertion, run here too so a new athanor-scoped table
      # fails a test rather than only a deployment.
      assert :ok = Arca.TenantTables.verify_roster!()
    end

    # Asserting the check returns `:ok` proves only that the current schema
    # matches the current roster; it says nothing about whether the check
    # can fail. Drive both directions against a real table.
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
