# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Members do
  @moduledoc """
  Membership assignments — "user X is a member of athanor A".

  A membership row is a presence-only grant: its existence makes the user a
  member (every member is the athanor's admin — there is no role tier). A
  `"platform"` row names no athanor: it makes the user a platform admin, the
  server's operator, minted on first sign-in for the emails in
  `CYFR_PLATFORM_ADMIN_EMAILS` (see `Sanctum.Tenancy`).
  """

  import Ecto.Query
  require Logger
  require Arca.Repo.Errors

  alias Arca.Schemas.Membership

  @doc """
  Insert a membership. `attrs` must carry `:user_id` and `:scope`;
  `:athanor_id` is required by the changeset for the `"athanor"` scope and
  must name an existing athanor.
  """
  def create(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)

    changeset = Membership.changeset(%Membership{}, attrs)

    # The row also carries a foreign key, but SQLite reports a violation
    # without naming it, so the changeset could not translate it. Checking
    # here answers the same way on both adapters.
    if changeset.valid? and missing_athanor?(changeset) do
      {:error, Ecto.Changeset.add_error(changeset, :athanor_id, "does not exist")}
    else
      Arca.Repo.insert(changeset)
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc """
  Idempotently ensure a membership exists for `user_id`.

  Opts: `:scope` (required — the two scopes are different grants and neither
  is a default), `:athanor_id`. Safe under concurrent
  first-logins — a unique-constraint conflict resolves to a re-read of the
  existing row.
  """
  def ensure(user_id, opts) when is_binary(user_id) do
    scope = Keyword.fetch!(opts, :scope)
    athanor_id = Keyword.get(opts, :athanor_id)

    # Read-before-write: the membership almost always already exists (it is
    # minted once), so probing first avoids a failed INSERT — and the noisy
    # `QUERY ERROR ... memberships` log line — on every later sign-in. A
    # concurrent first-login can still race past the probe; the INSERT's
    # unique-constraint error then resolves to a re-read.
    case find(user_id, scope, athanor_id) do
      {:ok, membership} ->
        {:ok, membership}

      _ ->
        case create(%{user_id: user_id, scope: scope, athanor_id: athanor_id}) do
          {:ok, membership} ->
            {:ok, membership}

          {:error, %Ecto.Changeset{errors: errors}} = err ->
            if Keyword.has_key?(errors, :user_id) or unique_conflict?(errors) do
              # Lost the race: re-read the existing assignment.
              find(user_id, scope, athanor_id)
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
      Logger.error("Sanctum.Tenancy.Members: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def remove(%Membership{} = membership) do
    Arca.Repo.delete(membership)
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: remove failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def list_by_athanor(athanor_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(m in Membership,
      where: m.athanor_id == ^athanor_id,
      order_by: [desc: m.created_at],
      limit: ^limit
    )
    |> Arca.Repo.all()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: list_by_athanor failed (#{Exception.message(e)})")
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
      Logger.error("Sanctum.Tenancy.Members: list_by_user failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp find(user_id, scope, athanor_id) do
    query =
      from(m in Membership,
        where: m.user_id == ^user_id and m.scope == ^scope,
        limit: 1
      )

    query =
      case athanor_id do
        nil -> from(m in query, where: is_nil(m.athanor_id))
        id -> from(m in query, where: m.athanor_id == ^id)
      end

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Members: find failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp missing_athanor?(changeset) do
    case Ecto.Changeset.get_field(changeset, :athanor_id) do
      nil -> false
      id -> match?({:error, :not_found}, Sanctum.Tenancy.Athanors.get(id))
    end
  end

  defp unique_conflict?(errors) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  defp generate_id, do: "mem_" <> Ecto.UUID.generate()
end
