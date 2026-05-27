# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.IdentityLinks do
  @moduledoc """
  Context module for identity-link operations. Storage layer only.

  Federated OIDC users link a GitHub/Google identity so the
  linked provider's access_token can drive cyfr.run namespace-claim
  flows — the federated OIDC token itself can't claim against the
  public cyfr.run.
  """

  import Ecto.Query
  require Logger
  require Arca.Repo.Errors

  alias Arca.Schemas.IdentityLink

  def create(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:linked_at, now)

    %IdentityLink{}
    |> IdentityLink.changeset(attrs)
    |> Arca.Repo.insert()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.IdentityLinks: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get(user_id, provider) do
    case Arca.Repo.get_by(IdentityLink, user_id: user_id, provider: provider) do
      nil -> {:error, :not_found}
      link -> {:ok, link}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.IdentityLinks: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def list_by_user(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(l in IdentityLink,
      where: l.user_id == ^user_id,
      order_by: [desc: l.linked_at],
      limit: ^limit
    )
    |> Arca.Repo.all()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.IdentityLinks: list_by_user failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def delete(%IdentityLink{} = link) do
    Arca.Repo.delete(link)
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.IdentityLinks: delete failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp generate_id, do: "lnk_" <> Ecto.UUID.generate()
end
