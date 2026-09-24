# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.CatalogChargeRowTest do
  @moduledoc """
  A spawn-shaped in-chain call that carries a charge identity holds a
  reservation row for the call: charged before the handler runs, released
  after it returns, and refused (with the slot given back) when the
  reservation is full.
  """

  use ExUnit.Case, async: false

  alias Grimoire.Catalog
  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Context

  @node "formula:local.charge-row"
  @athanor "ath_test"
  @user "charge_row_user"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    graph = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        @node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
            "max_concurrent_tasks" => 10,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => %{"tools" => ["tincture_visibility.get"]}}
        }
      }
    }

    {:ok, blob} = Blob.parse(graph)

    {:ok, auth} =
      Authority.root(
        %{
          profile_id: "prof-charge-row",
          consent_id: "consent-charge-row",
          source_ref: @node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{@node => "sha256:charge-row"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    {:ok, %{execution: root, attempt: root_attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_charge_row_#{System.unique_integer([:positive])}",
          reference: "#{@node}:1.0.0",
          user_id: @user,
          athanor_id: @athanor,
          component_type: "formula"
        },
        reservation: %{budget_id: auth.budget.id, cap: 1},
        grant: Cyfr.Test.AttemptFixtures.grant(@athanor),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    ctx =
      Context.enter_guest(%Context{
        user_id: @user,
        athanor_id: @athanor,
        scope: :athanor,
        permissions: MapSet.new([:*]),
        authenticated: true,
        request_id: "req_charge_row"
      })

    charge = %{
      id: "call:t:1:c1:g0",
      attempt: root_attempt.attempt,
      generation: 0,
      holder_execution_id: nil
    }

    # The chain the calls come from: the root's execution and the attempt
    # that owns it, as the host stamps them.
    lineage = %{parent_execution_id: root.id, attempt: root_attempt.attempt}

    {:ok, auth: auth, ctx: ctx, charge: charge, lineage: lineage}
  end

  defp call(ctx, auth, charge, lineage) do
    Catalog.call_in_chain(
      "tincture_visibility",
      ctx,
      %{"action" => "get", "publisher" => "local", "name" => "no-such-tincture"},
      auth,
      guest_fn: :spawn,
      charge: charge,
      lineage: lineage
    )
  end

  test "the row is charged for the call and released after it", %{
    auth: auth,
    ctx: ctx,
    charge: charge,
    lineage: lineage
  } do
    case call(ctx, auth, charge, lineage) do
      {:ok, _} -> :ok
      {:error, msg} when is_binary(msg) -> refute msg =~ "Denied by chain authority"
    end

    assert Sanctum.Authority.budget(auth).in_flight == 0

    assert %{charged: 0} =
             Arca.BudgetReservations.lookup(Prima.Actor.in_athanor(@athanor), auth.budget.id)

    assert {:ok, []} =
             Arca.BudgetReservations.charges(Prima.Actor.in_athanor(@athanor), auth.budget.id)
  end

  test "a full reservation refuses the call and gives the slot back", %{
    auth: auth,
    ctx: ctx,
    charge: charge,
    lineage: lineage
  } do
    :ok =
      Arca.BudgetReservations.charge(
        Prima.Actor.in_athanor(@athanor),
        auth.budget.id,
        %{charge | id: "other"},
        1
      )

    assert {:error, msg} = call(ctx, auth, charge, lineage)
    assert msg =~ "Denied by chain authority"
    assert Sanctum.Authority.budget(auth).in_flight == 0

    assert {:ok, [%{id: "other"}]} =
             Arca.BudgetReservations.charges(Prima.Actor.in_athanor(@athanor), auth.budget.id)
  end

  test "a call under the chain's attempt with no identity of its own holds a row of its own", %{
    auth: auth,
    ctx: ctx,
    charge: charge,
    lineage: lineage
  } do
    result =
      Catalog.call_in_chain(
        "tincture_visibility",
        ctx,
        %{"action" => "get", "publisher" => "local", "name" => "no-such-tincture"},
        auth,
        guest_fn: :spawn,
        lineage: lineage
      )

    case result do
      {:ok, _} -> :ok
      {:error, msg} when is_binary(msg) -> refute msg =~ "Denied by chain authority"
    end

    # Charged for the call, released after it.
    assert %{charged: 0} =
             Arca.BudgetReservations.lookup(Prima.Actor.in_athanor(@athanor), auth.budget.id)

    assert {:ok, []} =
             Arca.BudgetReservations.charges(Prima.Actor.in_athanor(@athanor), auth.budget.id)

    # The row is the authority: a full reservation refuses the call.
    :ok =
      Arca.BudgetReservations.charge(
        Prima.Actor.in_athanor(@athanor),
        auth.budget.id,
        %{charge | id: "other"},
        1
      )

    assert {:error, msg} =
             Catalog.call_in_chain(
               "tincture_visibility",
               ctx,
               %{"action" => "get", "publisher" => "local", "name" => "no-such-tincture"},
               auth,
               guest_fn: :spawn,
               lineage: lineage
             )

    assert msg =~ "Denied by chain authority"
    assert Sanctum.Authority.budget(auth).in_flight == 0
  end
end
