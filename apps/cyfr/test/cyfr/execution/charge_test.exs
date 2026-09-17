# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.ChargeTest do
  @moduledoc """
  A spawn-shaped child under a known attempt charges the root's
  reservation row whether or not the caller named the charge: the
  chain gives an unnamed one an identity and a pre-minted child id, and
  the row refuses the run when the reservation is full.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Execution.Charge
  alias Cyfr.Test.AuthorityFixtures

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    auth = AuthorityFixtures.root!()
    root_id = "exec_charge_id_root_#{System.unique_integer([:positive])}"

    {:ok, %{attempt: root_attempt}} =
      Arca.Execution.admit(
        %{
          id: root_id,
          reference: "#{AuthorityFixtures.formula_ref()}:1.0.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: auth.budget.id, cap: 1}
      )

    {:ok, ctx: ctx, auth: auth, root_id: root_id, attempt: root_attempt.attempt}
  end

  test "identify/1 names an unnamed spawn under its attempt and mints the child's id", %{
    attempt: attempt
  } do
    opts = Charge.identify(ctx: nil, attempt: attempt, guest_fn: :spawn)

    assert %{id: "chg_" <> _, attempt: ^attempt, generation: 0, holder_execution_id: child} =
             Keyword.fetch!(opts, :charge)

    assert child == Keyword.fetch!(opts, :execution_id)
    assert String.starts_with?(child, "exec_")

    # A given identity and id are kept; no attempt, no identity.
    given = %{
      id: "call:t:1:c1:g0",
      attempt: attempt,
      generation: 0,
      holder_execution_id: "exec_x"
    }

    assert [charge: ^given] = Charge.identify(charge: given)
    assert [guest_fn: :spawn] = Charge.identify(guest_fn: :spawn)

    # A synchronous call takes no charge, so it is given no identity to
    # admit under.
    assert [attempt: ^attempt, guest_fn: :call] =
             Charge.identify(attempt: attempt, guest_fn: :call)
  end

  test "a full reservation refuses an unnamed spawn before anything runs", %{
    ctx: ctx,
    auth: auth,
    root_id: root_id,
    attempt: attempt
  } do
    # The one slot is taken by another dispatch.
    :ok =
      Arca.BudgetReservations.charge(
        ctx.athanor_id,
        auth.budget.id,
        %{id: "other", attempt: attempt, generation: 0, holder_execution_id: nil},
        1
      )

    assert {:error, {:invoke_denied, :invoke_budget_exhausted}} =
             Cyfr.Execution.run_child(auth, "reagent:local.ta:1.0.0", nil, %{},
               ctx: ctx,
               attempt: attempt,
               parent_execution_id: root_id,
               root_execution_id: root_id,
               declared_needs: [],
               guest_fn: :spawn
             )

    # Nothing was admitted, and the slot the transition took is back.
    assert [] =
             Arca.Repo.all(Arca.Schemas.ExecutionAttempt)
             |> Enum.reject(&(&1.execution_id == root_id))

    assert Sanctum.Authority.budget(auth).in_flight == 0

    assert {:ok, [%{id: "other"}]} =
             Arca.BudgetReservations.charges(ctx.athanor_id, auth.budget.id)
  end
end
