# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Test.AuthorityFixtures do
  @moduledoc """
  Authority fixtures that need the running store. The consented graph and
  its root authority are `Cyfr.Test.AuthorityFixtures`.
  """

  alias Cyfr.Authority
  alias Cyfr.Test.AuthorityFixtures

  @doc """
  Mint the reservation row an authority's budget names — the root's, as
  admission would — so the authority crosses the wire.
  """
  def reserve!(%Authority{} = auth, athanor_id \\ "ath_test") do
    {:ok, grant} =
      Sanctum.ExecutionStanding.capture(
        Sanctum.internal_context(athanor_id: athanor_id, scope: :athanor)
      )

    {:ok, _} =
      Arca.Execution.admit(
        %{
          id: Cyfr.UUID7.execution_id(),
          reference: "#{AuthorityFixtures.formula_ref()}:1.0.0",
          user_id: "usr_wire",
          athanor_id: athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: auth.budget.id, cap: auth.budget.cap},
        grant: grant,
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    auth
  end
end
