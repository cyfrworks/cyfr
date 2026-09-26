# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ExecutionStandingTest do
  @moduledoc """
  An admitted execution's grant is its athanor at the generation its root
  read: it stands while the athanor is active at exactly that generation,
  and an archive retires it for good — a reopen raises the generation
  again, so the old grant never stands and only a fresh capture does. The
  check runs only inside an execution write's locking transaction. A
  retirement's check asks nothing of the athanor. The retired scan pages
  through every open attempt whose stamp no longer stands, by attempt id,
  for the server's own actor alone.
  """

  use ExUnit.Case, async: false

  alias Sanctum.ExecutionStanding
  alias Sanctum.Tenancy.Athanors

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, athanor} =
      Athanors.create(%{
        kind: "group",
        name: "Standing",
        slug: "standing-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    {:ok, athanor: athanor}
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

  test "a capture is the athanor's active standing now", %{athanor: athanor} do
    assert {:ok, %Prima.ExecutionGrant{athanor_id: id, generation: generation}} =
             ExecutionStanding.capture(ctx(athanor.id))

    assert id == athanor.id
    assert generation == athanor.security_generation
  end

  test "no athanor, an unknown one and an archived one capture nothing", %{athanor: athanor} do
    assert {:error, :not_standing} = ExecutionStanding.capture(ctx(nil))
    assert {:error, :not_standing} = ExecutionStanding.capture(ctx("ath_no_such_athanor"))

    {:ok, _} = Athanors.archive(athanor)
    assert {:error, :not_standing} = ExecutionStanding.capture(ctx(athanor.id))
  end

  test "the check runs only inside a locking transaction", %{athanor: athanor} do
    {:ok, grant} = ExecutionStanding.capture(ctx(athanor.id))
    assert_raise ArgumentError, fn -> ExecutionStanding.verify(grant) end
  end

  test "an archive retires a grant for good; a reopen admits only a fresh one", %{
    athanor: athanor
  } do
    {:ok, grant} = ExecutionStanding.capture(ctx(athanor.id))
    assert :ok = verify(grant)

    {:ok, archived} = Athanors.archive(athanor)
    assert {:error, :not_standing} = verify(grant)

    {:ok, _reopened} = Athanors.unarchive(archived)
    assert {:error, :not_standing} = verify(grant)

    {:ok, fresh} = ExecutionStanding.capture(ctx(athanor.id))
    assert fresh.generation > grant.generation
    assert :ok = verify(fresh)

    # A grant naming a generation the athanor never had stands for nothing.
    assert {:error, :not_standing} = verify(%{fresh | generation: fresh.generation + 7})
  end

  test "a retirement's check asks nothing of the athanor", %{athanor: athanor} do
    {:ok, grant} = ExecutionStanding.capture(ctx(athanor.id))
    {:ok, _} = Athanors.archive(athanor)
    assert :ok = ExecutionStanding.stamp_only(grant)
  end

  test "the retired scan pages every open attempt whose stamp no longer stands", %{
    athanor: athanor
  } do
    {:ok, grant} = ExecutionStanding.capture(ctx(athanor.id))
    retired = for _ <- 1..3, do: admit!(athanor.id, grant)

    assert {:ok, []} = scan_of(athanor.id)

    {:ok, archived} = Athanors.archive(athanor)
    {:ok, _reopened} = Athanors.unarchive(archived)

    # Work admitted after the reopen stands, and is not found.
    {:ok, fresh} = ExecutionStanding.capture(ctx(athanor.id))
    {standing_id, _standing_attempt} = admit!(athanor.id, fresh)

    assert {:ok, found} = scan_of(athanor.id)

    assert Enum.sort(found) ==
             Enum.sort(
               for {execution_id, attempt} <- retired,
                   do: {execution_id, attempt, athanor.id, grant.generation}
             )

    refute Enum.any?(found, &(elem(&1, 0) == standing_id))

    # One page at a time, in attempt-id order, each after the last.
    {:ok, [first]} = ExecutionStanding.retired_attempts(Prima.Actor.system(), nil, 1)
    {:ok, [second]} = ExecutionStanding.retired_attempts(Prima.Actor.system(), elem(first, 1), 1)
    assert elem(second, 1) > elem(first, 1)
  end

  test "the scan is the server's own", %{athanor: athanor} do
    assert {:error, :cross_tenant} =
             ExecutionStanding.retired_attempts(Prima.Actor.in_athanor(athanor.id), nil, 10)
  end

  # Every page of the scan, narrowed to one athanor's rows.
  defp scan_of(athanor_id, cursor \\ nil, acc \\ []) do
    case ExecutionStanding.retired_attempts(Prima.Actor.system(), cursor, 2) do
      {:ok, []} ->
        {:ok, Enum.filter(acc, &(elem(&1, 2) == athanor_id))}

      {:ok, page} ->
        scan_of(athanor_id, page |> List.last() |> elem(1), acc ++ page)
    end
  end
end
