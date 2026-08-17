# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Users do
  @moduledoc """
  The people this server knows (`Arca.Schemas.User`).

  A row is written on the first admitted sign-in and touched on every later
  one; the door, invited memberships and per-person preferences key off it.
  `deny/2` and `allow/2` are the operator's eject and re-admit: a denied
  person loses their sessions and API keys, their own athanor is archived
  (nothing deleted) and their group rows are removed; allowing them again
  reopens the door and the athanor, and leaves the revoked credentials
  revoked.
  """

  import Ecto.Query, only: [from: 2]
  require Logger
  require Arca.Repo.Errors

  alias Arca.Schemas.User
  alias Sanctum.Tenancy.{Athanors, Members}

  @type provider_info :: %{
          required(:id) => String.t(),
          required(:provider) => String.t() | atom(),
          optional(:email) => String.t() | nil,
          optional(:verified) => boolean() | :unknown,
          optional(:name) => String.t() | nil
        }

  @doc """
  Insert or refresh the row for an identity the door just admitted.

  `first_seen_at` is set once; `last_seen_at`, `email`, `email_verified`
  and `display_name` follow what the provider asserted this time.
  """
  @spec upsert_from_provider(provider_info()) :: {:ok, User.t()} | {:error, term()}
  def upsert_from_provider(%{id: id, provider: provider} = info) when is_binary(id) do
    now = DateTime.utc_now()

    seen = %{
      email: Map.get(info, :email),
      email_verified: Map.get(info, :verified) == true,
      provider: to_string(provider),
      display_name: Map.get(info, :name),
      last_seen_at: now,
      updated_at: now
    }

    case get(id) do
      {:ok, user} ->
        user |> User.changeset(seen) |> Arca.Repo.update()

      {:error, :not_found} ->
        %User{}
        |> User.changeset(
          Map.merge(seen, %{
            id: id,
            first_seen_at: now,
            created_at: now,
            prefs: Jason.encode!(%{})
          })
        )
        |> Arca.Repo.insert()
        |> case do
          {:error, %Ecto.Changeset{}} = err ->
            # A concurrent first sign-in of the same identity won the insert.
            case get(id) do
              {:ok, user} -> {:ok, user}
              _ -> err
            end

          other ->
            other
        end

      {:error, _} = err ->
        err
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Users: upsert failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @spec get(String.t()) :: {:ok, User.t()} | {:error, :not_found | :database_error}
  def get(id) when is_binary(id) and id != "" do
    case Arca.Repo.get(User, id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Users: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get(_), do: {:error, :not_found}

  @doc "Every identity that signed in with this (lowercased) email."
  @spec list_by_email(String.t()) :: [User.t()]
  def list_by_email(email) when is_binary(email) do
    email = String.downcase(email)
    Arca.Repo.all(from(u in User, where: u.email == ^email, order_by: [asc: u.first_seen_at]))
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Users: list_by_email failed (#{Exception.message(e)})")
      []
  end

  @doc "The identity whose cyfr.run namespace this is, if any."
  @spec get_by_namespace(String.t()) :: {:ok, User.t()} | {:error, :not_found | :database_error}
  def get_by_namespace(namespace) when is_binary(namespace) and namespace != "" do
    case Arca.Repo.get_by(User, namespace: namespace) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Users: get_by_namespace failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @max_page 500

  @doc """
  Everyone the server knows, newest first. A platform view, paged with
  `limit:` (default and ceiling #{@max_page}) and `offset:`.
  """
  @spec list(keyword()) :: [User.t()]
  def list(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @max_page) |> min(@max_page) |> max(1)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    Arca.Repo.all(
      from(u in User,
        order_by: [desc: u.last_seen_at, asc: u.id],
        limit: ^limit,
        offset: ^offset
      )
    )
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Users: list failed (#{Exception.message(e)})")
      []
  end

  @doc "Record the person's cyfr.run namespace once it is known."
  @spec set_namespace(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def set_namespace(%User{namespace: ns} = user, ns), do: {:ok, user}

  def set_namespace(%User{} = user, namespace) when is_binary(namespace) do
    update(user, %{namespace: namespace})
  end

  @doc "Record the person's own athanor once minted."
  @spec set_personal_athanor(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def set_personal_athanor(%User{} = user, athanor_id) when is_binary(athanor_id) do
    update(user, %{personal_athanor_id: athanor_id})
  end

  @doc "The person's preferences document (`mode`, `theme`), as a map."
  @spec prefs(User.t()) :: map()
  def prefs(%User{prefs: nil}), do: %{}

  def prefs(%User{prefs: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc "Merge `patch` into the person's preferences."
  @spec put_prefs(User.t(), map()) :: {:ok, User.t()} | {:error, term()}
  def put_prefs(%User{} = user, patch) when is_map(patch) do
    update(user, %{prefs: Jason.encode!(Map.merge(prefs(user), patch))})
  end

  @doc """
  Eject a person from this server: mark them denied, revoke every session
  and API key they created, archive their own athanor and remove their
  group rows. The door entry that keeps them out is written by the caller
  (`Sanctum.Door.Store.deny/4`) — this is the part that acts on what the
  person already has.
  """
  @spec deny(User.t()) :: {:ok, User.t()} | {:error, term()}
  def deny(%User{} = user) do
    now = DateTime.utc_now()

    with {:ok, user} <- update(user, %{status: "denied", denied_at: now}) do
      Sanctum.Session.revoke_all_for_user(user.id)
      Sanctum.ApiKey.revoke_all_created_by(user.id)
      archive_personal(user)

      # The status is written (the person is out at the door either way);
      # what fails here is reported so the operator can retry, not hidden.
      with :ok <- Members.remove_all_for_user(user.id) do
        :telemetry.execute([:cyfr, :sanctum, :door, :denied], %{count: 1}, %{
          user_id: user.id,
          email: user.email
        })

        {:ok, user}
      end
    end
  end

  @doc """
  Reverse `deny/1` at the door: the person may sign in again and their own
  athanor is reopened. Revoked sessions and keys stay revoked, and the group
  seats the deny removed are not restored — eject is permanent for groups;
  a member adds them again.
  """
  @spec allow(User.t()) :: {:ok, User.t()} | {:error, term()}
  def allow(%User{} = user) do
    with {:ok, user} <- update(user, %{status: "active", denied_at: nil}) do
      unarchive_personal(user)
      {:ok, user}
    end
  end

  defp archive_personal(%User{personal_athanor_id: id}) when is_binary(id) do
    case Athanors.get(id) do
      {:ok, athanor} -> Athanors.archive(athanor, force: true)
      _ -> :ok
    end
  end

  defp archive_personal(_), do: :ok

  defp unarchive_personal(%User{personal_athanor_id: id}) when is_binary(id) do
    case Athanors.get(id) do
      {:ok, %{status: "archived"} = athanor} -> Athanors.unarchive(athanor)
      _ -> :ok
    end
  end

  defp unarchive_personal(_), do: :ok

  defp update(%User{} = user, attrs) do
    attrs = attrs |> Map.new() |> Map.put(:updated_at, DateTime.utc_now())

    user
    |> User.changeset(attrs)
    |> Arca.Repo.update()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Users: update failed (#{Exception.message(e)})")
      {:error, :database_error}
  end
end
