# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 Moonmoon69, Cyfrworks.com All Rights Reserved.

defmodule SanctumArx.IdentityLinks do
  @moduledoc """
  Context module for identity-link operations.

  Phase D.2a of `auth_refactor.md`: storage-layer only. Arx enterprise-OIDC
  users link a GitHub/Google identity so the linked provider's access_token
  can drive cyfr.run namespace-claim flows (see §1.4, §Phase D.2).

  All operations are gated on the Arx edition; Core callers receive
  `{:error, :feature_not_available}`. The Arx Shell UI (D.2b) is the only
  real caller today — this module is usable on its own for testing.
  """

  import Ecto.Query
  require Logger
  require Arca.Repo.Errors

  alias SanctumArx.IdentityLink

  def create(attrs) do
    with :ok <- require_arx() do
      now = DateTime.utc_now()

      attrs =
        attrs
        |> Map.put_new(:id, generate_id())
        |> Map.put_new(:linked_at, now)

      %IdentityLink{}
      |> IdentityLink.changeset(attrs)
      |> Arca.Repo.insert()
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.IdentityLinks: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get(user_id, provider) do
    with :ok <- require_arx() do
      case Arca.Repo.get_by(IdentityLink, user_id: user_id, provider: provider) do
        nil -> {:error, :not_found}
        link -> {:ok, link}
      end
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.IdentityLinks: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def list_by_user(user_id, opts \\ []) do
    with :ok <- require_arx() do
      limit = Keyword.get(opts, :limit, 50)

      from(l in IdentityLink,
        where: l.user_id == ^user_id,
        order_by: [desc: l.linked_at],
        limit: ^limit
      )
      |> Arca.Repo.all()
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.IdentityLinks: list_by_user failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def delete(%IdentityLink{} = link) do
    with :ok <- require_arx() do
      Arca.Repo.delete(link)
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.IdentityLinks: delete failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp require_arx do
    cond do
      not SanctumArx.Edition.arx?() -> {:error, :feature_not_available}
      not SanctumArx.License.valid?() -> {:error, :license_expired}
      true -> :ok
    end
  end

  defp generate_id, do: "lnk_" <> Ecto.UUID.generate()
end
