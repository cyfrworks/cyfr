# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Test.AuthorityFixtures do
  @moduledoc """
  Authority fixtures that need the running store. The consented graph and
  its root authority are `Prima.Test.AuthorityFixtures`.
  """

  alias Prima.Authority
  alias Prima.Test.AuthorityFixtures

  @doc """
  Mint the reservation row an authority's budget names — the root's, as
  admission would — so the authority crosses the wire. The root records
  `origin` (`Prima.Origin`), the admission path the case models.
  """
  def reserve!(%Authority{} = auth, athanor_id, origin) when is_atom(origin) do
    {:ok, grant} =
      Sanctum.ExecutionStanding.capture(
        Sanctum.internal_context(athanor_id: athanor_id, scope: :athanor)
      )

    {:ok, _} =
      Arca.Execution.admit(
        %{
          id: Prima.UUID7.execution_id(),
          reference: "#{AuthorityFixtures.formula_ref()}:1.0.0",
          user_id: "usr_wire",
          athanor_id: athanor_id,
          component_type: "formula",
          origin: origin
        },
        reservation: %{budget_id: auth.budget.id, cap: auth.budget.cap},
        grant: grant,
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    auth
  end
end
