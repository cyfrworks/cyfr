# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.CatalogChargeRowTest do
  @moduledoc """
  A spawn-shaped in-chain call that carries a charge identity holds a
  reservation row for the call: charged before the handler runs, released
  after it returns, and refused (with the slot given back) when the
  reservation is full.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Ops.Catalog
  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
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
        blob
      )

    {:ok, %{attempt: root_attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_charge_row_#{System.unique_integer([:positive])}",
          reference: "#{@node}:1.0.0",
          user_id: @user,
          athanor_id: @athanor,
          component_type: "formula"
        },
        reservation: %{budget_id: auth.budget.id, cap: 1}
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

    {:ok, auth: auth, ctx: ctx, charge: charge}
  end

  defp call(ctx, auth, charge) do
    Catalog.call_in_chain(
      "tincture_visibility",
      ctx,
      %{"action" => "get", "publisher" => "local", "name" => "no-such-tincture"},
      auth,
      guest_fn: :spawn,
      charge: charge
    )
  end

  test "the row is charged for the call and released after it", %{
    auth: auth,
    ctx: ctx,
    charge: charge
  } do
    case call(ctx, auth, charge) do
      {:ok, _} -> :ok
      {:error, msg} when is_binary(msg) -> refute msg =~ "Denied by chain authority"
    end

    assert Authority.budget(auth).in_flight == 0
    assert %{charged: 0} = Arca.BudgetReservations.lookup(@athanor, auth.budget.id)
    assert {:ok, []} = Arca.BudgetReservations.charges(@athanor, auth.budget.id)
  end

  test "a full reservation refuses the call and gives the slot back", %{
    auth: auth,
    ctx: ctx,
    charge: charge
  } do
    :ok = Arca.BudgetReservations.charge(@athanor, auth.budget.id, %{charge | id: "other"}, 1)

    assert {:error, msg} = call(ctx, auth, charge)
    assert msg =~ "Denied by chain authority"
    assert Authority.budget(auth).in_flight == 0

    assert {:ok, [%{id: "other"}]} = Arca.BudgetReservations.charges(@athanor, auth.budget.id)
  end
end
