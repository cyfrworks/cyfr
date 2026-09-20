# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DoorsTest do
  @moduledoc """
  The door rows: who the facade lets ask, what it hands back, and the three
  answers it keeps apart — the row is there, the row is not there, and the
  store could not say.
  """
  # async: false — one case drops the table inside its transaction.
  use ExUnit.Case, async: false

  alias Arca.Doors

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, actor: Cyfr.Actor.system()}
  end

  defp entry(actor, kind, value, over \\ %{}) do
    {:ok, entry} =
      Doors.insert(
        actor,
        Map.merge(%{kind: kind, value: value, effect: "allow", status: "allowed"}, over)
      )

    entry
  end

  describe "who may ask" do
    test "an athanor-scoped actor is refused, before any query", %{actor: system} do
      tenant = %Cyfr.Actor{athanor_id: "ath_doors_#{System.unique_integer([:positive])}"}
      handler = "doors-not-platform-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        # The event fires in the querying process; a neighbour's query is not
        # this test's.
        fn _event, _measure, _meta, _config ->
          if self() == parent, do: send(parent, :queried)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, :not_platform} = Doors.list(tenant)
      assert {:error, :not_platform} = Doors.requests(tenant)
      assert {:error, :not_platform} = Doors.get(tenant, "door_x")
      assert {:error, :not_platform} = Doors.find(tenant, "email", "a@example.com")
      assert {:error, :not_platform} = Doors.insert(tenant, %{kind: "email", value: "a@b.c"})
      assert {:error, :not_platform} = Doors.update(tenant, "door_x", %{note: "no"})
      assert {:error, :not_platform} = Doors.delete(tenant, "door_x")
      refute_received :queried

      # The probe is live: the platform actor does query.
      assert {:error, :not_found} = Doors.get(system, "door_probe")
      assert_received :queried
    end

    test "a context or a bare id is not an actor and raises", %{actor: actor} do
      ctx = Sanctum.TestContext.local()

      assert_raise FunctionClauseError, fn -> Doors.list(ctx) end
      assert_raise FunctionClauseError, fn -> Doors.find(ctx, "email", "a@example.com") end
      # Through apply/3: an argument of the wrong shape in the first
      # position is the mistake under test, and spelling it as a literal
      # call would only make the type checker complain instead of the
      # facade.
      assert_raise FunctionClauseError, fn -> apply(Doors, :get, ["ath_1", "door_x"]) end
      assert_raise FunctionClauseError, fn -> apply(Doors, :delete, [nil, "door_x"]) end

      # And the same call with the actor works, so the raise is the shape of
      # the argument and not the call.
      assert {:error, :not_found} = Doors.get(actor, "door_x")
    end
  end

  describe "what crosses" do
    test "a plain map, never a schema struct or a changeset", %{actor: actor} do
      row = entry(actor, "email", "plain@example.com")

      refute is_struct(row)

      assert Map.keys(row) |> Enum.sort() ==
               ~w(added_by created_at effect id kind note requested_by status updated_at value)a

      {:ok, [listed]} = Doors.list(actor)
      refute is_struct(listed)

      assert {:error, {:invalid, %{kind: _}}} =
               Doors.insert(actor, %{kind: "nonsense", value: "x", effect: "allow"})
    end

    test "insert mints the id and both stamps", %{actor: actor} do
      row = entry(actor, "user_id", "github|https://github.com|1")

      assert "door_" <> _ = row.id
      assert %DateTime{} = row.created_at
      assert row.created_at == row.updated_at
    end
  end

  describe "the three answers" do
    @tag :capture_log
    test "not_found is not database_error", %{actor: actor} do
      entry(actor, "email", "here@example.com")

      assert {:ok, %{value: "here@example.com"}} = Doors.find(actor, "email", "here@example.com")
      assert {:error, :not_found} = Doors.find(actor, "email", "gone@example.com")

      # An unreadable store answers neither "there is one" nor "there is
      # none" — the door is where that difference decides who gets in.
      Arca.Repo.query!("DROP TABLE server_allowlist")

      assert {:error, :database_error} = Doors.find(actor, "email", "here@example.com")
    end
  end

  describe "writes" do
    test "the unique kind/value pair is the arbiter of a race", %{actor: actor} do
      entry(actor, "email", "one@example.com")

      assert {:error, :already_exists} =
               Doors.insert(actor, %{
                 kind: "email",
                 value: "one@example.com",
                 effect: "deny",
                 status: "allowed"
               })
    end

    test "update stamps updated_at and leaves created_at alone", %{actor: actor} do
      row = entry(actor, "email", "up@example.com", %{status: "requested"})

      assert {:ok, changed} = Doors.update(actor, row.id, %{status: "allowed", added_by: "ops"})
      assert changed.status == "allowed"
      assert changed.added_by == "ops"
      assert changed.created_at == row.created_at
      assert DateTime.compare(changed.updated_at, row.updated_at) in [:gt, :eq]
    end

    test "a write into the gap left by a delete says it lost", %{actor: actor} do
      row = entry(actor, "email", "gap@example.com")

      assert :ok = Doors.delete(actor, row.id)
      assert {:error, :not_found} = Doors.delete(actor, row.id)
      assert {:error, :not_found} = Doors.update(actor, row.id, %{note: "too late"})
      assert {:error, :not_found} = Doors.get(actor, row.id)
    end
  end

  describe "reads" do
    test "list is newest first and requests is oldest first, requested only", %{actor: actor} do
      old = entry(actor, "email", "old@example.com", %{status: "requested"})
      new = entry(actor, "email", "new@example.com", %{status: "requested"})
      settled = entry(actor, "wildcard", "*")

      {:ok, listed} = Doors.list(actor)

      assert Enum.sort(Enum.map(listed, & &1.id)) ==
               Enum.sort([old.id, new.id, settled.id])

      stamps = Enum.map(listed, & &1.created_at)
      assert stamps == Enum.sort(stamps, {:desc, DateTime})

      {:ok, waiting} = Doors.requests(actor)
      assert Enum.sort(Enum.map(waiting, & &1.id)) == Enum.sort([old.id, new.id])

      waiting_stamps = Enum.map(waiting, & &1.created_at)
      assert waiting_stamps == Enum.sort(waiting_stamps, {:asc, DateTime})
    end
  end
end
