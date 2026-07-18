# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Memberships do
  @moduledoc """
  Membership assignments — "user X is admin of scope S".

  A membership row is a presence-only grant: its existence assigns the user to
  a scope (`platform` / `org` / `project`). There is no role tier and no invite
  ceremony. Every install carries memberships; a fresh single-operator install
  gets one platform-scope row for the operator on first sign-in (see
  `Sanctum.Tenancy`).
  """

  import Ecto.Query
  require Logger
  require Arca.Repo.Errors

  alias Arca.Schemas.Membership

  @doc """
  Insert a membership. `attrs` must carry `:user_id` and `:scope`; `:org_id`
  and `:project_id` are required by the changeset for org/project scopes.
  """
  def create(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)

    %Membership{}
    |> Membership.changeset(attrs)
    |> Arca.Repo.insert()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Memberships: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc """
  Idempotently ensure a membership exists for `user_id` at the given scope.

  Opts: `:scope` (default `"platform"`), `:org_id`, `:project_id`. Safe under
  concurrent first-logins — a unique-constraint conflict resolves to a re-read
  of the existing row.
  """
  def ensure(user_id, opts \\ []) when is_binary(user_id) do
    scope = Keyword.get(opts, :scope, "platform")
    org_id = Keyword.get(opts, :org_id)
    project_id = Keyword.get(opts, :project_id)

    # Read-before-write: the membership almost always already exists (it is
    # minted once on first sign-in), so probing first avoids a failed INSERT —
    # and the noisy `QUERY ERROR ... memberships` log line — on every later
    # bootstrap. A concurrent first-login can still race past the probe; the
    # INSERT's unique-constraint error then resolves to a re-read.
    case find(user_id, scope, org_id, project_id) do
      {:ok, membership} ->
        {:ok, membership}

      _ ->
        case create(%{user_id: user_id, scope: scope, org_id: org_id, project_id: project_id}) do
          {:ok, membership} ->
            {:ok, membership}

          {:error, %Ecto.Changeset{errors: errors}} = err ->
            if Keyword.has_key?(errors, :user_id) or unique_conflict?(errors) do
              # Lost the race: re-read the existing assignment.
              find(user_id, scope, org_id, project_id)
            else
              err
            end

          other ->
            other
        end
    end
  end

  def get(id) do
    case Arca.Repo.get(Membership, id) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Memberships: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get_by_user_and_org(user_id, org_id) do
    case Arca.Repo.get_by(Membership, user_id: user_id, org_id: org_id) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "Sanctum.Tenancy.Memberships: get_by_user_and_org failed (#{Exception.message(e)})"
      )

      {:error, :database_error}
  end

  def remove(%Membership{} = membership) do
    Arca.Repo.delete(membership)
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Memberships: remove failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def list_by_org(org_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(m in Membership,
      where: m.org_id == ^org_id,
      order_by: [desc: m.created_at],
      limit: ^limit
    )
    |> Arca.Repo.all()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Memberships: list_by_org failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def list_by_user(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(m in Membership,
      where: m.user_id == ^user_id,
      order_by: [desc: m.created_at],
      limit: ^limit
    )
    |> Arca.Repo.all()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Memberships: list_by_user failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp find(user_id, scope, org_id, project_id) do
    query =
      from(m in Membership,
        where: m.user_id == ^user_id and m.scope == ^scope,
        limit: 1
      )

    query =
      query
      |> where_eq_or_nil(:org_id, org_id)
      |> where_eq_or_nil(:project_id, project_id)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Memberships: find failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp where_eq_or_nil(query, field, nil), do: from(m in query, where: is_nil(field(m, ^field)))

  defp where_eq_or_nil(query, field, value),
    do: from(m in query, where: field(m, ^field) == ^value)

  defp unique_conflict?(errors) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  defp generate_id, do: "mem_" <> Ecto.UUID.generate()
end
