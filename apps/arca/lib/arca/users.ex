# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Users do
  @moduledoc """
  Person rows (`Arca.Schemas.User`).

  ## Why none of this is athanor-scoped

  A person is not a row inside an athanor. They exist before any athanor
  does — the row is written by their admission, before their athanor is
  minted, and the athanor names its owner, not the other way round.
  Scoping these reads to an athanor would make sign-in impossible
  and would answer "not on this server" for every person outside the
  caller's athanor.

  So every function here is a cross-tenant read or write and says so in
  its head: it matches `scope: :platform` and refuses an athanor-scoped
  actor with `{:error, :cross_tenant}`. `Prima.Actor.system/0` is the
  server's own actor, which is what the door, sign-in and tenancy
  resolution act as. Who may see a person, and which of these rows they
  may act on, is decided above this layer.

  Nothing that belongs to Ecto crosses the boundary: a person is answered
  as a plain map (`Arca.Data`). A refusal is
  `:conflict` (a unique index — a concurrent admission won it, so the
  loser re-reads), `{:invalid, %{field => [message]}}`, `:not_found`,
  `:cross_tenant` or `:database_error`.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.User

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

  @doc """
  Record `namespace`, the registry's personal namespace for the person
  `user_id` names, as a write only the control plane's holder makes
  (`Arca.Repo.owned/2`): it follows a registry's answer, and a member
  whose slot was taken while the registry answered writes nothing
  (`{:error, :not_owner}`).
  """
  @spec set_namespace(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :not_owner} | refusal() | write_refusal()
  def set_namespace(%Prima.Actor{scope: :platform}, user_id, namespace)
      when is_binary(user_id) and user_id != "" and is_binary(namespace) do
    Arca.Repo.owned("Arca.Users.set_namespace", fn ->
      with {:ok, user} <- found(Arca.Repo.get(User, user_id)) do
        user
        |> User.update_changeset(%{namespace: namespace, updated_at: DateTime.utc_now()})
        |> Arca.Repo.update()
        |> settled()
      end
    end)
  end

  def set_namespace(%Prima.Actor{scope: :platform}, _user_id, _namespace),
    do: {:error, :not_found}

  def set_namespace(%Prima.Actor{}, _user_id, _namespace), do: {:error, :cross_tenant}

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
  Mint a person, as ONE transaction run only by the control plane's
  holder (`Arca.Repo.owned/2`): a member whose slot was taken mints no one
  (`{:error, :not_owner}`).

  `opts`:

    * `admission:` (required) — how the person is made here
      (`Arca.Schemas.User.admissions/0`), recorded on their row.
    * `verify:` — the higher owner's check (`ARCHITECTURE.md` §4.4), run
      inside the transaction after the installation guard and before any
      row is written. A zero-arity function answering `:ok` or
      `{:error, reason}`, which refuses the mint with that reason, so a
      refused mint has written nothing. It writes nothing and makes no
      network call.
    * `also:` — the higher owner's closure (`ARCHITECTURE.md` §4.4), run
      inside the transaction after the person's rows are written. It is
      handed the person as a plain map and answers `:ok` or
      `{:error, reason}`, which rolls the whole mint back with that reason.
      It writes only its owner's rows through Arca and makes no network
      call.

  The installation guard runs first, inside the same transaction
  (`Arca.InstallationClaims.guard!/1`): the installation's first person is
  made only by `setup`, and is written with the platform administrator's
  mark (`users.platform_admin_at`) in this transaction; no other mint
  writes it. Every other admission onto an empty node is `:not_set_up`,
  and a `setup` on a node that holds a person is `:setup_closed`.
  """
  @spec mint(Prima.Actor.t(), map(), keyword()) ::
          {:ok, map()}
          | {:error,
             :not_set_up
             | :setup_closed
             | :not_owner
             | term()}
          | refusal()
          | write_refusal()
  def mint(actor, user_attrs, opts)

  def mint(%Prima.Actor{scope: :platform}, user_attrs, opts)
      when is_map(user_attrs) and is_list(opts) do
    admission = Keyword.fetch!(opts, :admission)

    if admission in User.admissions() do
      mint_guarded(admission, user_attrs, opts)
    else
      {:error, {:invalid, %{admission: ["is not an admission"]}}}
    end
  end

  def mint(%Prima.Actor{}, _user_attrs, _opts), do: {:error, :cross_tenant}

  defp mint_guarded(admission, user_attrs, opts) do
    verify = Keyword.get(opts, :verify, fn -> :ok end)
    also = Keyword.get(opts, :also, fn _user -> :ok end)
    user_attrs = user_attrs |> Map.new() |> Map.put(:admission, admission)

    Arca.Repo.owned("Arca.Users.mint", fn ->
      case Arca.InstallationClaims.guard!(admission) do
        {:error, _reason} = refusal ->
          refusal

        admitted when admitted in [:first, :ok] ->
          with :ok <- also_ran(verify.()),
               {:ok, user} <-
                 admitted
                 |> born()
                 |> User.changeset(user_attrs)
                 |> Arca.Repo.insert()
                 |> settled(),
               :ok <- also_ran(also.(Arca.Data.project(user))) do
            {:ok, {admitted, user}}
          end
      end
    end)
    |> case do
      {:ok, {:first, user}} ->
        # Committed: the installation holds its first person from here on.
        Arca.InstallationClaims.first_person_made()
        {:ok, user}

      {:ok, {:ok, user}} ->
        {:ok, user}

      {:error, _reason} = refusal ->
        refusal
    end
  end

  # The installation's first person is born with the platform
  # administrator's mark, on the row itself and past every changeset.
  defp born(:first), do: %User{platform_admin_at: DateTime.utc_now()}
  defp born(:ok), do: %User{}

  defp also_ran(:ok), do: :ok
  defp also_ran({:error, _reason} = refusal), do: refusal

  defp also_ran(other) do
    raise ArgumentError,
          "a verify: or also: closure answers :ok or {:error, reason}, got " <>
            Prima.LoggerContext.shape(other)
  end

  # ---- internal --------------------------------------------------------------

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
