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
  caller's athanor.

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
  Everyone the server knows, a page at a time, `limit:` people to a page
  (default and ceiling `max_page/0`).

  By default the most recently seen first, paged with `offset:`: a
  display order, in which a sign-in between two pages moves people from
  one page to another. `order: :id` pages in id order instead, `after:`
  naming the last id of the previous page (only greater ids follow), so a
  walk of every page reads no one twice and everyone whose row predates
  the walk; a row written during it is read when its id sorts after the
  last page already read, and otherwise by the next walk.
  """
  @spec list(Prima.Actor.t(), keyword()) :: {:ok, [map()]} | refusal()
  def list(actor, opts \\ [])

  def list(%Prima.Actor{scope: :platform}, opts) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, @max_page) |> min(@max_page) |> max(1)
    query = page_query(Keyword.get(opts, :order), opts, limit)

    Arca.Repo.Errors.with_db_rescue("Arca.Users.list", fn -> {:ok, Arca.Repo.all(query)} end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, _opts), do: {:error, :cross_tenant}

  defp page_query(nil, opts, limit) do
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    from(u in User,
      order_by: [desc: u.last_seen_at, asc: u.id],
      limit: ^limit,
      offset: ^offset
    )
  end

  # Keyset paging: ids are unique, so the order is total and a person is
  # on exactly one page.
  defp page_query(:id, opts, limit) do
    query = from(u in User, order_by: [asc: u.id], limit: ^limit)

    case Keyword.get(opts, :after) do
      nil -> query
      after_id when is_binary(after_id) -> from(u in query, where: u.id > ^after_id)
    end
  end

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
  def touch_identity(%Prima.Actor{scope: :platform}, key, %DateTime{} = now)
      when is_binary(key) do
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

  The installation guard runs first, inside the same transaction
  (`Arca.InstallationClaims.guard!/1`), so a first sign-in cannot race a
  restore's claim of the node: an ordinary mint is refused
  `:restore_reserved` while a restore claim is pending, or on a node with
  no person while the installed mode is `:restore_reserved`, even when it
  wins the race. A node whose boot installed no mode raises
  `Arca.InstallationClaims.NotInstalledError` and mints nothing.

  `opts`:

    * `also:` — the higher owner's closure (`ARCHITECTURE.md` §4.4), run
      inside the transaction after the person and identity rows are
      written. It is handed the person as a plain map and answers `:ok` or
      `{:error, reason}`, which rolls the whole mint back with that reason.
      It writes only its owner's rows through Arca and makes no network
      call.
    * `restore:` — the installation claim a restore's mint names
      (`%{request_id: …, token_digest: …}`), never a caller's argument. A
      restore's mint may name no IdP identity (`identity_attrs` nil); it is
      refused `:not_claimed` unless the claim is pending exactly as named,
      and `:not_empty` on a node that holds a person.

  A concurrent first sign-in of the same identity wins the unique index;
  the loser rolls back and reads the person the winner minted, so both
  answer the same row rather than one of them reporting a conflict.
  """
  @spec mint(Prima.Actor.t(), map(), map() | nil, keyword()) ::
          {:ok, map()}
          | {:error, :restore_reserved | :not_claimed | :not_empty | term()}
          | refusal()
          | write_refusal()
  def mint(actor, user_attrs, identity_attrs, opts \\ [])

  def mint(%Prima.Actor{scope: :platform} = actor, user_attrs, identity_attrs, opts)
      when is_map(user_attrs) and (is_map(identity_attrs) or is_nil(identity_attrs)) and
             is_list(opts) do
    restore = Keyword.get(opts, :restore)
    also = Keyword.get(opts, :also, fn _user -> :ok end)

    if is_nil(identity_attrs) and is_nil(restore) do
      {:error, {:invalid, %{identity: ["an ordinary mint names the identity that admitted it"]}}}
    else
      mint_guarded(actor, user_attrs, identity_attrs, restore, also)
    end
  end

  def mint(%Prima.Actor{}, _user_attrs, _identity_attrs, _opts), do: {:error, :cross_tenant}

  defp mint_guarded(actor, user_attrs, identity_attrs, restore, also) when is_function(also, 1) do
    Arca.Repo.Errors.with_db_rescue("Arca.Users.mint", fn ->
      identity_attrs =
        identity_attrs &&
          identity_attrs |> Map.new() |> Map.put_new(:id, Prima.UUID7.generate_id("ext"))

      Arca.Repo.locking_transaction(fn ->
        with :ok <- Arca.InstallationClaims.guard!(restore),
             {:ok, user} <-
               %User{} |> User.changeset(user_attrs) |> Arca.Repo.insert() |> settled(),
             {:ok, _identity} <- insert_identity(identity_attrs, user.id),
             :ok <- also_ran(also.(Arca.Data.project(user))) do
          user
        else
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, user} -> {:ok, user}
        {:error, reason} -> lost_the_race(actor, identity_attrs && identity_attrs[:key], reason)
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Link another IdP identity (`attrs`: its `:key`, `:provider`, `:issuer`
  and `:subject`) to the person `user_id`, in one locking transaction that
  locks the person's row first and reads them `active`
  (`:not_active` otherwise, `:not_found` for no such person).

  An identity already the person's is answered `{:ok, %{identity: row,
  linked: false}}` and writes nothing. One another person holds is
  `:conflict`. Otherwise the row is written and `opts[:also]` runs after
  it, inside the transaction, handed `%{identity: row}`; it answers `:ok`
  or `{:error, reason}`, which rolls the link back with that reason. A
  link answers `{:ok, %{identity: row, linked: true}}`.
  """
  @spec link_identity(Prima.Actor.t(), String.t(), map(), keyword()) ::
          {:ok, %{identity: map(), linked: boolean()}}
          | {:error, :conflict | :not_active | :not_found | term()}
          | refusal()
  def link_identity(actor, user_id, attrs, opts \\ [])

  def link_identity(%Prima.Actor{scope: :platform}, user_id, attrs, opts)
      when is_binary(user_id) and user_id != "" and is_map(attrs) and is_list(opts) do
    also = Keyword.get(opts, :also, fn _linked -> :ok end)

    Arca.Repo.Errors.with_db_rescue("Arca.Users.link_identity", fn ->
      Arca.Repo.locking_transaction(fn ->
        with :ok <- active_locked(user_id),
             {:ok, outcome} <- linked(user_id, attrs) do
          case outcome do
            %{linked: false} ->
              outcome

            %{linked: true, identity: identity} ->
              case also_ran(also.(%{identity: Arca.Data.project(identity)})) do
                :ok -> outcome
                {:error, reason} -> Arca.Repo.rollback(reason)
              end
          end
        else
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def link_identity(%Prima.Actor{}, _user_id, _attrs, _opts), do: {:error, :cross_tenant}

  @doc """
  Unlink the IdP identity `key` from the person `user_id`, in one locking
  transaction that locks the person's row first and reads them `active`.
  Only the person's own identity is removed (`:not_found` for one that is
  not theirs). `opts[:also]` runs after the delete, inside the
  transaction, handed `%{identity: row, remaining: count}`, the person's
  identities left; it answers `:ok` or `{:error, reason}`, which restores
  the identity and refuses with that reason.
  """
  @spec unlink_identity(Prima.Actor.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_active | :not_found | term()} | refusal()
  def unlink_identity(actor, user_id, key, opts \\ [])

  def unlink_identity(%Prima.Actor{scope: :platform}, user_id, key, opts)
      when is_binary(user_id) and user_id != "" and is_binary(key) and is_list(opts) do
    also = Keyword.get(opts, :also, fn _unlinked -> :ok end)

    Arca.Repo.Errors.with_db_rescue("Arca.Users.unlink_identity", fn ->
      Arca.Repo.locking_transaction(fn ->
        with :ok <- active_locked(user_id),
             %ExternalIdentity{} = identity <-
               Arca.Repo.get_by(ExternalIdentity, key: key, user_id: user_id) ||
                 {:error, :not_found} do
          {1, _} = Arca.Repo.delete_all(from(i in ExternalIdentity, where: i.id == ^identity.id))

          remaining =
            Arca.Repo.one(
              from(i in ExternalIdentity, where: i.user_id == ^user_id, select: count(i.id))
            )

          unlinked = %{identity: Arca.Data.project(identity), remaining: remaining}

          case also_ran(also.(unlinked)) do
            :ok -> unlinked
            {:error, reason} -> Arca.Repo.rollback(reason)
          end
        else
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def unlink_identity(%Prima.Actor{}, _user_id, _key, _opts), do: {:error, :cross_tenant}

  # The person's row, locked first as every standing order locks it, and
  # read active under the lock.
  defp active_locked(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.status)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :not_found}
      "active" -> :ok
      _not_active -> {:error, :not_active}
    end
  end

  # The unique key decides: an insert that finds the key taken writes
  # nothing (`on_conflict: :nothing`, which on PostgreSQL leaves the
  # transaction usable) and reads whose it is.
  defp linked(user_id, attrs) do
    key = attrs[:key]

    case Arca.Repo.get_by(ExternalIdentity, key: key) do
      %ExternalIdentity{user_id: ^user_id} = identity ->
        {:ok, %{identity: identity, linked: false}}

      %ExternalIdentity{} ->
        {:error, :conflict}

      nil ->
        now = DateTime.utc_now()

        row = %{
          id: Prima.UUID7.generate_id("ext"),
          user_id: user_id,
          key: key,
          provider: attrs[:provider],
          issuer: attrs[:issuer],
          subject: attrs[:subject],
          first_seen_at: now,
          last_seen_at: now
        }

        changeset = ExternalIdentity.changeset(%ExternalIdentity{}, row)

        cond do
          not changeset.valid? ->
            {:error, Arca.Data.invalid(changeset)}

          match?({1, _}, Arca.Repo.insert_all(ExternalIdentity, [row], on_conflict: :nothing)) ->
            {:ok, %{identity: Arca.Repo.get!(ExternalIdentity, row.id), linked: true}}

          true ->
            {:error, :conflict}
        end
    end
  end

  defp also_ran(:ok), do: :ok
  defp also_ran({:error, _reason} = refusal), do: refusal

  defp also_ran(other) do
    raise ArgumentError,
          "an also: closure answers :ok or {:error, reason}, got " <>
            Prima.LoggerContext.shape(other)
  end

  # ---- internal --------------------------------------------------------------

  defp insert_identity(nil, _user_id), do: {:ok, nil}

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
