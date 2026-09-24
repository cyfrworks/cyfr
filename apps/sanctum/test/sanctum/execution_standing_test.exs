# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ExecutionStandingTest do
  @moduledoc """
  An admitted execution's grant is its estate at the generation its root
  read: it stands while the estate is active at exactly that generation,
  and an archive retires it for good — a reopen raises the generation
  again, so the old grant never stands and only a fresh capture does. The
  check runs only inside an execution write's locking transaction. A
  retirement's check asks nothing of the estate. The retired scan pages
  through every open attempt whose stamp no longer stands, by attempt id,
  for the server's own actor alone.
  """

  use ExUnit.Case, async: false

  alias Sanctum.ExecutionStanding
  alias Sanctum.Tenancy.Athanors

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, estate} =
      Athanors.create(%{
        kind: "group",
        name: "Standing",
        slug: "standing-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    {:ok, estate: estate}
  end

  defp ctx(athanor_id),
    do: Sanctum.internal_context(athanor_id: athanor_id, scope: :athanor)

  defp verify(grant) do
    {:ok, answer} =
      Arca.Repo.locking_transaction(fn -> ExecutionStanding.verify(grant) end)

    answer
  end

  defp admit!(athanor_id, grant) do
    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: Prima.UUID7.execution_id(),
          reference: "reagent:local.standing:0.1.0",
          user_id: "usr_standing",
          athanor_id: athanor_id,
          component_type: "reagent"
        },
        grant: grant,
        verify: &ExecutionStanding.verify/1
      )

    {execution.id, attempt.attempt}
  end

  test "a capture is the estate's active standing now", %{estate: estate} do
    assert {:ok, %Prima.ExecutionGrant{athanor_id: id, generation: generation}} =
             ExecutionStanding.capture(ctx(estate.id))

    assert id == estate.id
    assert generation == estate.security_generation
  end

  test "no estate, an unknown one and an archived one capture nothing", %{estate: estate} do
    assert {:error, :not_standing} = ExecutionStanding.capture(ctx(nil))
    assert {:error, :not_standing} = ExecutionStanding.capture(ctx("ath_no_such_estate"))

    {:ok, _} = Athanors.archive(estate)
    assert {:error, :not_standing} = ExecutionStanding.capture(ctx(estate.id))
  end

  test "the check runs only inside a locking transaction", %{estate: estate} do
    {:ok, grant} = ExecutionStanding.capture(ctx(estate.id))
    assert_raise ArgumentError, fn -> ExecutionStanding.verify(grant) end
  end

  test "an archive retires a grant for good; a reopen admits only a fresh one", %{
    estate: estate
  } do
    {:ok, grant} = ExecutionStanding.capture(ctx(estate.id))
    assert :ok = verify(grant)

    {:ok, archived} = Athanors.archive(estate)
    assert {:error, :not_standing} = verify(grant)

    {:ok, _reopened} = Athanors.unarchive(archived)
    assert {:error, :not_standing} = verify(grant)

    {:ok, fresh} = ExecutionStanding.capture(ctx(estate.id))
    assert fresh.generation > grant.generation
    assert :ok = verify(fresh)

    # A grant naming a generation the estate never had stands for nothing.
    assert {:error, :not_standing} = verify(%{fresh | generation: fresh.generation + 7})
  end

  test "a retirement's check asks nothing of the estate", %{estate: estate} do
    {:ok, grant} = ExecutionStanding.capture(ctx(estate.id))
    {:ok, _} = Athanors.archive(estate)
    assert :ok = ExecutionStanding.stamp_only(grant)
  end

  test "the retired scan pages every open attempt whose stamp no longer stands", %{
    estate: estate
  } do
    {:ok, grant} = ExecutionStanding.capture(ctx(estate.id))
    retired = for _ <- 1..3, do: admit!(estate.id, grant)

    assert {:ok, []} = scan_of(estate.id)

    {:ok, archived} = Athanors.archive(estate)
    {:ok, _reopened} = Athanors.unarchive(archived)

    # Work admitted after the reopen stands, and is not found.
    {:ok, fresh} = ExecutionStanding.capture(ctx(estate.id))
    {standing_id, _standing_attempt} = admit!(estate.id, fresh)

    assert {:ok, found} = scan_of(estate.id)

    assert Enum.sort(found) ==
             Enum.sort(
               for {execution_id, attempt} <- retired,
                   do: {execution_id, attempt, estate.id, grant.generation}
             )

    refute Enum.any?(found, &(elem(&1, 0) == standing_id))

    # One page at a time, in attempt-id order, each after the last.
    {:ok, [first]} = ExecutionStanding.retired_attempts(Prima.Actor.system(), nil, 1)
    {:ok, [second]} = ExecutionStanding.retired_attempts(Prima.Actor.system(), elem(first, 1), 1)
    assert elem(second, 1) > elem(first, 1)
  end

  test "the scan is the server's own", %{estate: estate} do
    assert {:error, :cross_tenant} =
             ExecutionStanding.retired_attempts(Prima.Actor.in_athanor(estate.id), nil, 10)
  end

  # Every page of the scan, narrowed to one estate's rows.
  defp scan_of(athanor_id, cursor \\ nil, acc \\ []) do
    case ExecutionStanding.retired_attempts(Prima.Actor.system(), cursor, 2) do
      {:ok, []} ->
        {:ok, Enum.filter(acc, &(elem(&1, 2) == athanor_id))}

      {:ok, page} ->
        scan_of(athanor_id, page |> List.last() |> elem(1), acc ++ page)
    end
  end
end
