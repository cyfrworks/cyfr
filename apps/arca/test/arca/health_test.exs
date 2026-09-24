# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.HealthTest do
  @moduledoc """
  The database reachability probe, and the three answers a load balancer's
  rotation depends on keeping apart.

  An unreachable database and an empty one must not read the same. The
  probe's defence is that it reads no table at all, so "nothing stored
  yet" cannot reach it as a signal in the first place.
  """
  use ExUnit.Case, async: false

  alias Arca.Health
  alias Arca.Schemas.BuildRecord

  describe "with the database reachable" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      :ok
    end

    test "the server's own actor gets :ok" do
      assert :ok = Health.check(Prima.Actor.system())
    end

    test "an empty database is ready — absent data is not unavailable infrastructure" do
      # The state a freshly migrated node boots into: a schema and no rows.
      # A probe that read a product table would call this "nothing there"
      # and a load balancer would take a perfectly good node out of
      # rotation for it.
      Arca.Repo.delete_all(BuildRecord)
      assert Arca.Repo.aggregate(BuildRecord, :count) == 0

      assert :ok = Health.check(Prima.Actor.system())
    end

    test "a tenant actor is refused, and the refusal is not an outage" do
      tenant = %Prima.Actor{athanor_id: "ath_probe", user_id: "usr_probe"}

      assert {:error, :not_system} = Health.check(tenant)
      # Same call, same moment, with the system actor: the database is up,
      # so the refusal above said something about authority and nothing
      # about reachability.
      assert :ok = Health.check(Prima.Actor.system())
    end

    test "an actor that carries a tenant but not the system flag is still refused" do
      assert {:error, :not_system} =
               Health.check(%Prima.Actor{athanor_id: "ath_probe", scope: :platform})
    end
  end

  describe "with no connection to be had" do
    setup do
      # No sandbox owner and manual mode: the pool will give this process
      # nothing, which is the shape of a database the node cannot reach.
      # The failure arrives as a `DBConnection.OwnershipError`, which is
      # not one of `Arca.Repo.Errors.db_errors()` — so the probe must
      # answer it on its own rather than through `with_db_rescue/2`.
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)
      :ok
    end

    test "the probe answers unavailable, with a sentence for the log" do
      assert {:error, {:unavailable, why}} = Health.check(Prima.Actor.system())
      assert is_binary(why)
      assert why != ""
    end

    test "a refused caller is told about its authority, not about the database" do
      assert {:error, :not_system} = Health.check(%Prima.Actor{athanor_id: "ath_probe"})
    end

    test "nothing in the answer can be mistaken for :ok" do
      refute Health.check(Prima.Actor.system()) == :ok
    end
  end
end
