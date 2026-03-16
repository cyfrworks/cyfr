defmodule SanctumArx.Memberships do
  @moduledoc """
  Context module for organization membership operations.

  All operations are gated on the Arx edition.
  """

  import Ecto.Query
  require Logger
  require Arca.Repo.Errors

  alias SanctumArx.Membership

  def create(attrs) do
    with :ok <- require_arx() do
      now = DateTime.utc_now()

      attrs =
        attrs
        |> Map.put_new(:id, generate_id())
        |> Map.put_new(:invited_at, now)
        |> Map.put_new(:created_at, now)
        |> Map.put_new(:updated_at, now)

      %Membership{}
      |> Membership.changeset(attrs)
      |> Arca.Repo.insert()
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Memberships: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def accept(%Membership{} = membership) do
    with :ok <- require_arx() do
      now = DateTime.utc_now()

      membership
      |> Membership.changeset(%{accepted_at: now, updated_at: now})
      |> Arca.Repo.update()
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Memberships: accept failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get(id) do
    with :ok <- require_arx() do
      case Arca.Repo.get(Membership, id) do
        nil -> {:error, :not_found}
        membership -> {:ok, membership}
      end
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Memberships: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get_by_user_and_org(user_id, org_id) do
    with :ok <- require_arx() do
      case Arca.Repo.get_by(Membership, user_id: user_id, org_id: org_id) do
        nil -> {:error, :not_found}
        membership -> {:ok, membership}
      end
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Memberships: get_by_user_and_org failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def update_role(%Membership{} = membership, role) do
    with :ok <- require_arx() do
      membership
      |> Membership.changeset(%{role: role, updated_at: DateTime.utc_now()})
      |> Arca.Repo.update()
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Memberships: update_role failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def remove(%Membership{} = membership) do
    with :ok <- require_arx() do
      Arca.Repo.delete(membership)
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Memberships: remove failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def list_by_org(org_id, opts \\ []) do
    with :ok <- require_arx() do
      limit = Keyword.get(opts, :limit, 50)

      from(m in Membership,
        where: m.org_id == ^org_id,
        order_by: [desc: m.created_at],
        limit: ^limit
      )
      |> Arca.Repo.all()
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Memberships: list_by_org failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def list_by_user(user_id, opts \\ []) do
    with :ok <- require_arx() do
      limit = Keyword.get(opts, :limit, 50)

      from(m in Membership,
        where: m.user_id == ^user_id,
        order_by: [desc: m.created_at],
        limit: ^limit
      )
      |> Arca.Repo.all()
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Memberships: list_by_user failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def user_role(user_id, org_id) do
    with :ok <- require_arx() do
      case Arca.Repo.get_by(Membership, user_id: user_id, org_id: org_id) do
        nil -> {:error, :not_found}
        membership -> {:ok, membership.role}
      end
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Memberships: user_role failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp require_arx do
    cond do
      not SanctumArx.Edition.arx?() -> {:error, :feature_not_available}
      not SanctumArx.License.valid?() -> {:error, :license_expired}
      true -> :ok
    end
  end

  defp generate_id, do: "mem_" <> Ecto.UUID.generate()
end
