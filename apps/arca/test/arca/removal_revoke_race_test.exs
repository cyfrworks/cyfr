# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RemovalRevokeRaceTest do
  @moduledoc """
  A removal's revocation of a source (`Arca.ProfileStorage.revoke_for_source/2`)
  and its person's revocation of one of its profiles, under real
  concurrency, on connections of their own: the person's revocation
  committed while the removal runs keeps its cause, `person`, so the
  component installed again is not granted over it.

  PostgreSQL only: SQLite takes its one write lock at each transaction's
  start (`Arca.Repo.locking_transaction/2`), so the two never interleave
  there.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ProfileStorage
  alias Arca.Test.Writers
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres

  setup do
    actor = Arca.Test.Actor.local()
    source = "reagent:local.removal-race-#{System.unique_integer([:positive])}"

    {:ok, profile} =
      unboxed(fn ->
        Writers.put_profile(%{
          athanor_id: actor.athanor_id,
          source_ref: source,
          kind: "owner",
          label: "default",
          status: "active"
        })
      end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(
          from(p in Arca.Schemas.Profile,
            where: p.athanor_id == ^actor.athanor_id and p.source_ref == ^source
          )
        )
      end)
    end)

    {:ok, actor: actor, source: source, profile: profile}
  end

  # The removal is held after its first statement on `profiles`, and the
  # person's revocation commits there, before the removal goes on.
  def hold_after_profiles(_event, _measurements, meta, test) do
    if Process.get(:hold_removal) && meta[:source] == "profiles" do
      Process.delete(:hold_removal)
      send(test, {:holding, self()})

      receive do
        :go -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  test "a person's revocation committed while a removal runs keeps its cause",
       %{actor: actor, source: source, profile: profile} do
    test = self()
    handler = "removal-race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.hold_after_profiles/4, test)

    on_exit(fn -> :telemetry.detach(handler) end)

    removing =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:hold_removal, true)
          ProfileStorage.revoke_for_source(actor, source)
        end)
      end)

    assert_receive {:holding, removal}, 5_000
    assert :ok = unboxed(fn -> ProfileStorage.revoke_by_person(actor, profile.id) end)
    send(removal, :go)
    assert {:ok, _revoked} = Task.await(removing, 10_000)

    assert {:ok, %{status: "revoked", revoked_by: "person"}} =
             unboxed(fn -> ProfileStorage.get(actor, profile.id) end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
end
