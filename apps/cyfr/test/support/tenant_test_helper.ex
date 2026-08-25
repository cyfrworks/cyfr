# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TenantTestHelper do
  @moduledoc false

  alias Sanctum.Context

  @doc "Returns two contexts working in different athanors."
  def two_contexts do
    ctx_a =
      Context.build(
        user_id: "user_a",
        namespace: "user_a",
        athanor_id: "ath_a",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    ctx_b =
      Context.build(
        user_id: "user_b",
        namespace: "user_b",
        athanor_id: "ath_b",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {ctx_a, ctx_b}
  end

  @doc """
  Insert an `athanors` row for `athanor_id` so settings-bearing code paths
  (`Sanctum.Tenancy.Athanors.get/1`, retention policy) can resolve it. Blob
  storage needs no row, but per-athanor settings live on the row.
  """
  def ensure_athanor_row(athanor_id, opts \\ []) do
    case Sanctum.Tenancy.Athanors.get(athanor_id) do
      {:ok, athanor} ->
        athanor

      {:error, :not_found} ->
        default_slug =
          athanor_id
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        {:ok, athanor} =
          Sanctum.Tenancy.Athanors.create(%{
            id: athanor_id,
            kind: "person",
            name: Keyword.get(opts, :name, athanor_id),
            slug: Keyword.get(opts, :slug, default_slug),
            created_by: Keyword.get(opts, :created_by, "test"),
            owner_user_id: Keyword.get(opts, :owner_user_id, "test")
          })

        athanor
    end
  end
end
