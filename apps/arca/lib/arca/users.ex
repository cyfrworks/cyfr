# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Users do
  @moduledoc """
  Person rows and the IdP identities that name them
  (`Arca.Schemas.User`, `Arca.Schemas.ExternalIdentity`).

  ## Why none of this is athanor-scoped

  A person is not a row inside an athanor. They exist before any athanor
  does — the row is written at the first admitted sign-in, before
  membership resolution has chosen anything — they sit in several at
  once, and the one column that names an athanor
  (`personal_athanor_id`) is a pointer out of the row, not a tenant
  stamp. Scoping these reads to an athanor would make sign-in impossible
  and would answer "not on this server" for every person outside the
  caller's estate.

  So every function here is a cross-tenant read or write and says so in
  its head: it matches `scope: :platform` and refuses an athanor-scoped
  actor with `{:error, :cross_tenant}`. `Prima.Actor.system/0` is the
  server's own actor, which is what the door, sign-in and tenancy
  resolution act as. Who may see a person, and which of these rows they
  may act on, is decided above this layer.

  Nothing that belongs to Ecto crosses the boundary: a person or an
  identity is answered as a plain map (`Arca.Data`). A refusal is
  `:conflict` (a unique index — a concurrent first sign-in won it, so the
  loser re-reads), `{:invalid, %{field => [message]}}`, `:not_found`,
  `:cross_tenant` or `:database_error`.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{ExternalIdentity, User}

  @type refusal :: {:error, :cross_tenant | :database_error}
  @type write_refusal ::
          {:error, :conflict | {:invalid, %{atom() => [String.t()]}} | :database_error}

  @max_page 500

  @doc "The ceiling on one page of people, which is also its default."
  @spec max_page() :: pos_integer()
  def max_page, do: @max_page

  @doc "The person this id names."
  @spec get(Prima.Actor.t(), String.t()) :: {:ok, map()} | {:error, :not_found} | refusal()
  def get(%Prima.Actor{scope: :platform}, id) when is_binary(id) and id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Users.get", fn -> found(Arca.Repo.get(User, id)) end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{scope: :platform}, _id), do: {:error, :not_found}
  def get(%Prima.Actor{}, _id), do: {:error, :cross_tenant}

  @doc "The person an IdP identity key names, if any."
  @spec get_by_identity(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  def get_by_identity(%Prima.Actor{scope: :platform}, key) when is_binary(key) and key != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Users.get_by_identity", fn ->
      found(
        Arca.Repo.one(
          from(u in User,
            join: i in ExternalIdentity,
            on: i.user_id == u.id,
            where: i.key == ^key
          )
        )
      )
    end)
    |> Arca.Data.project()
  end

  def get_by_identity(%Prima.Actor{scope: :platform}, _key), do: {:error, :not_found}
  def get_by_identity(%Prima.Actor{}, _key), do: {:error, :cross_tenant}

  @doc "The person whose cyfr.run namespace this is, if any."
  @spec get_by_namespace(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  def get_by_namespace(%Prima.Actor{scope: :platform}, namespace)
      when is_binary(namespace) and namespace != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Users.get_by_namespace", fn ->
      found(Arca.Repo.get_by(User, namespace: namespace))
    end)
    |> Arca.Data.project()
  end

  def get_by_namespace(%Prima.Actor{}, _namespace), do: {:error, :cross_tenant}

  @doc "Every person who signed in with this (already lowercased) address, oldest first."
  @spec list_by_email(Prima.Actor.t(), String.t()) :: {:ok, [map()]} | refusal()
  def list_by_email(%Prima.Actor{scope: :platform}, email) when is_binary(email) do
    Arca.Repo.Errors.with_db_rescue("Arca.Users.list_by_email", fn ->
      {:ok,
       Arca.Repo.all(from(u in User, where: u.email == ^email, order_by: [asc: u.first_seen_at]))}
    end)
    |> Arca.Data.project()
  end

  def list_by_email(%Prima.Actor{}, _email), do: {:error, :cross_tenant}

  @doc """
  Everyone the server knows, newest first. Paged with `limit:` (default
  and ceiling `max_page/0`) and `offset:`.
  """
  @spec list(Prima.Actor.t(), keyword()) :: {:ok, [map()]} | refusal()
  def list(actor, opts \\ [])

  def list(%Prima.Actor{scope: :platform}, opts) when is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.Users.list", fn ->
      limit = opts |> Keyword.get(:limit, @max_page) |> min(@max_page) |> max(1)
      offset = opts |> Keyword.get(:offset, 0) |> max(0)

      {:ok,
       Arca.Repo.all(
         from(u in User,
           order_by: [desc: u.last_seen_at, asc: u.id],
           limit: ^limit,
           offset: ^offset
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, _opts), do: {:error, :cross_tenant}

  @doc "Every IdP identity that names this person, oldest first."
  @spec identities(Prima.Actor.t(), String.t()) :: {:ok, [map()]} | refusal()
  def identities(%Prima.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Users.identities", fn ->
      {:ok,
       Arca.Repo.all(
         from(i in ExternalIdentity,
           where: i.user_id == ^user_id,
           order_by: [asc: i.first_seen_at]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def identities(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc "Whether any person's row names this athanor as their own furnace."
  @spec personal_athanor?(Prima.Actor.t(), String.t()) :: {:ok, boolean()} | refusal()
  def personal_athanor?(%Prima.Actor{scope: :platform}, athanor_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Users.personal_athanor?", fn ->
      {:ok, Arca.Repo.exists?(from(u in User, where: u.personal_athanor_id == ^athanor_id))}
    end)
  end

  def personal_athanor?(%Prima.Actor{}, _athanor_id), do: {:error, :cross_tenant}

  @doc "Stamp `now` on the identity row this key names, as its last sighting."
  @spec touch_identity(Prima.Actor.t(), String.t(), DateTime.t()) :: :ok | refusal()
  def touch_identity(%Prima.Actor{scope: :platform}, key, %DateTime{} = now) when is_binary(key) do
    Arca.Repo.Errors.with_db_rescue("Arca.Users.touch_identity", fn ->
      Arca.Repo.update_all(from(i in ExternalIdentity, where: i.key == ^key),
        set: [last_seen_at: now]
      )

      :ok
    end)
  end

  def touch_identity(%Prima.Actor{}, _key, _now), do: {:error, :cross_tenant}

  @doc """
  Write `attrs` over the person `user_id` names, as the row reads now.
  `updated_at` is stamped here. The standing columns (`status`,
  `denied_at`, `security_generation`) are refused as read-only:
  `Arca.SecurityTransitions` alone moves them.
  """
  @spec update(Prima.Actor.t(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_found} | refusal() | write_refusal()
  def update(%Prima.Actor{scope: :platform}, user_id, attrs)
      when is_binary(user_id) and user_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.Users.update", fn ->
      with {:ok, user} <- found(Arca.Repo.get(User, user_id)) do
        user
        |> User.update_changeset(Map.put(Map.new(attrs), :updated_at, DateTime.utc_now()))
        |> Arca.Repo.update()
        |> settled()
      end
    end)
    |> Arca.Data.project()
  end

  def update(%Prima.Actor{scope: :platform}, _user_id, _attrs), do: {:error, :not_found}
  def update(%Prima.Actor{}, _user_id, _attrs), do: {:error, :cross_tenant}

  @doc """
  Mint a person and the IdP identity that names them, as ONE transaction:
  a person with no identity could never sign in again, and an identity
  with no person names nobody.

  A concurrent first sign-in of the same identity wins the unique index;
  the loser rolls back and reads the person the winner minted, so both
  answer the same row rather than one of them reporting a conflict.
  """
  @spec mint(Prima.Actor.t(), map(), map()) :: {:ok, map()} | refusal() | write_refusal()
  def mint(%Prima.Actor{scope: :platform} = actor, user_attrs, identity_attrs)
      when is_map(user_attrs) and is_map(identity_attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.Users.mint", fn ->
      identity_attrs =
        identity_attrs |> Map.new() |> Map.put_new(:id, Prima.UUID7.generate_id("ext"))

      Arca.Repo.transaction(fn ->
        with {:ok, user} <-
               %User{} |> User.changeset(user_attrs) |> Arca.Repo.insert() |> settled(),
             {:ok, _identity} <- insert_identity(identity_attrs, user.id) do
          user
        else
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, user} -> {:ok, user}
        {:error, reason} -> lost_the_race(actor, identity_attrs[:key], reason)
      end
    end)
    |> Arca.Data.project()
  end

  def mint(%Prima.Actor{}, _user_attrs, _identity_attrs), do: {:error, :cross_tenant}

  # ---- internal --------------------------------------------------------------

  defp insert_identity(attrs, user_id) do
    %ExternalIdentity{}
    |> ExternalIdentity.changeset(Map.put(attrs, :user_id, user_id))
    |> Arca.Repo.insert()
    |> case do
      {:ok, identity} -> {:ok, identity}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, refusal(changeset)}
    end
  end

  # The unique index on the identity key is the arbiter of a concurrent
  # first sign-in: the loser reads the row the winner wrote rather than
  # reporting a conflict nobody can act on.
  defp lost_the_race(actor, key, reason) when is_binary(key) do
    case get_by_identity(actor, key) do
      {:ok, user} -> {:ok, user}
      _ -> {:error, reason}
    end
  end

  defp lost_the_race(_actor, _key, reason), do: {:error, reason}

  defp found(nil), do: {:error, :not_found}
  defp found(%User{} = user), do: {:ok, user}

  defp settled({:ok, %User{} = user}), do: {:ok, user}
  defp settled({:error, %Ecto.Changeset{} = changeset}), do: {:error, refusal(changeset)}

  defp refusal(%Ecto.Changeset{errors: errors} = changeset) do
    if unique?(errors), do: :conflict, else: Arca.Data.invalid(changeset)
  end

  defp unique?(errors) do
    Enum.any?(errors, fn {_field, {_message, meta}} -> meta[:constraint] == :unique end)
  end
end
