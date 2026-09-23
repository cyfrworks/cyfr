# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Athanors do
  @moduledoc """
  Athanor rows — the tenant itself (`Arca.Schemas.Athanor`).

  ## Two shapes, because an athanor row is not a row inside an athanor

  Every function states which shape it is, and the shape decides where its
  athanor comes from.

    * **Inside one tenant.** `current/1`, `update/2`, `set/2` and
      `put_settings/4` work on the row the actor's `athanor_id` names.
      The id comes from the actor and never from an argument, so no
      argument a caller passes can move the write to another tenant's
      row; an actor whose athanor is nil OR the empty string is
      `{:error, :no_athanor}` before any query runs. The empty string is
      an identity that was never resolved, the same thing
      `Sanctum.Context.build/1` refuses outright and
      `Arca.QueryHelpers.where_tenant/2` raises on — never a tenant
      named `""` — and a guard that took it would turn that refusal into
      an ordinary empty result.

    * **Across tenants.** Minting an athanor, finding one by slug, owner
      or pair key, listing the ones a person may work in, and counting
      what a cap bounds each decide *which* athanor a caller works in.
      None of them can be filtered by an athanor the caller does not hold
      yet — a mint has no athanor at all, and route resolution is how one
      is chosen — so they match `scope: :platform` and refuse an
      athanor-scoped actor with `{:error, :cross_tenant}`. The widening
      is asked for rather than assumed, and `Cyfr.Actor.system/0` is the
      server's own actor for the work no caller asked for.

  Nothing that belongs to Ecto crosses the boundary: a row is answered,
  and handed to a callback, as a plain map (`Arca.Data`). A refusal is
  `:slug_taken` (the unique index on kind and slug, which a derived slug
  retries against), `{:invalid, %{field => [message]}}`, `:not_found`,
  `:cross_tenant`, `:no_athanor` or `:database_error`. Reads that a
  caller may want to default on an outage say so with
  `{:error, :database_error}` and leave the default to the caller, whose
  decision it is.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Athanor, Membership, User}

  @type refusal :: {:error, :cross_tenant | :database_error}
  @type write_refusal ::
          {:error, :slug_taken | {:invalid, %{atom() => [String.t()]}} | :database_error}

  # ---- inside one tenant -----------------------------------------------------

  @doc "The actor's own athanor row."
  @spec current(Cyfr.Actor.t()) ::
          {:ok, map()} | {:error, :not_found | :no_athanor | :database_error}
  def current(%Cyfr.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.current", fn -> read(athanor_id) end)
    |> Arca.Data.project()
  end

  def current(%Cyfr.Actor{}), do: {:error, :no_athanor}

  @doc """
  Write `attrs` over the actor's own athanor row through the update
  changeset — the fields that may change after birth.
  """
  @spec update(Cyfr.Actor.t(), map()) ::
          {:ok, map()} | {:error, :not_found | :no_athanor} | write_refusal()
  def update(%Cyfr.Actor{athanor_id: athanor_id}, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.update", fn ->
      with {:ok, row} <- read(athanor_id) do
        row
        |> Athanor.update_changeset(Map.put(attrs, :updated_at, DateTime.utc_now()))
        |> Arca.Repo.update()
        |> settled()
      end
    end)
    |> Arca.Data.project()
  end

  def update(%Cyfr.Actor{}, _attrs), do: {:error, :no_athanor}

  @doc """
  Set `fields` on the actor's own athanor row with one statement — the
  provisioning stamps, which are the server's own record and never a
  patch a caller supplies. The standing columns are refused as read-only
  (`{:error, {:invalid, %{field => ["is read-only"]}}}`); they move only
  with an archive or a reopen (`Arca.SecurityTransitions`).
  """
  @spec set(Cyfr.Actor.t(), keyword()) ::
          :ok
          | {:error,
             :not_found | :no_athanor | :database_error | {:invalid, %{atom() => [String.t()]}}}
  def set(%Cyfr.Actor{athanor_id: athanor_id}, fields)
      when is_binary(athanor_id) and athanor_id != "" and is_list(fields) do
    case Enum.filter(Athanor.standing_fields(), &Keyword.has_key?(fields, &1)) do
      [] ->
        Arca.Repo.Errors.with_db_rescue("Arca.Athanors.set", fn ->
          case from(a in Athanor, where: a.id == ^athanor_id)
               |> Arca.Repo.update_all(set: fields) do
            {1, _} -> :ok
            {0, _} -> {:error, :not_found}
          end
        end)

      standing ->
        {:error, {:invalid, Map.new(standing, &{&1, ["is read-only"]})}}
    end
  end

  def set(%Cyfr.Actor{}, _fields), do: {:error, :no_athanor}

  @doc """
  Write `encoded` over the actor's athanor's settings document while it
  still reads `expected`, compare-and-set. `:stale` means the row moved
  under the caller and nothing was written — the caller merges again.
  """
  @spec put_settings(Cyfr.Actor.t(), String.t() | nil, String.t(), DateTime.t()) ::
          :ok | :stale | {:error, :no_athanor | :database_error}
  def put_settings(%Cyfr.Actor{athanor_id: athanor_id}, expected, encoded, %DateTime{} = now)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(encoded) and
             (is_binary(expected) or is_nil(expected)) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.put_settings", fn ->
      from(a in Athanor, where: a.id == ^athanor_id)
      |> settings_guard(expected)
      |> Arca.Repo.update_all(set: [settings: encoded, updated_at: now])
      |> landed()
    end)
  end

  def put_settings(%Cyfr.Actor{}, _expected, _encoded, _now), do: {:error, :no_athanor}

  # ---- across tenants --------------------------------------------------------

  @doc """
  Insert an athanor row. `:id`, `:created_at` and `:updated_at` default;
  everything else the create changeset requires must be in `attrs`.
  """
  @spec insert(Cyfr.Actor.t(), map()) :: {:ok, map()} | refusal() | write_refusal()
  def insert(%Cyfr.Actor{scope: :platform}, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.insert", fn -> do_insert(attrs) end)
    |> Arca.Data.project()
  end

  def insert(%Cyfr.Actor{}, _attrs), do: {:error, :cross_tenant}

  @doc """
  Mint an athanor, the checks that must pass first and the rows that must
  land with it, as ONE transaction. Any refusal rolls all of it back, so
  a mint that trips a cap leaves no athanor row and no membership.

  The caller's decisions arrive as functions, run in this order with the
  transaction open:

    * `:hold` — the person ids whose `users` rows are held for the length
      of the transaction. Held in sorted order, so two mints naming the
      same two people cannot deadlock, and held before anything is
      counted, so two mints by one person cannot both pass a per-person
      cap.
    * `:guards` — zero-arity functions answering `:ok` or
      `{:error, reason}`. The caps live above this layer; what they read
      is counted here, and they are asked with the rows already held.
    * `:attrs` — a zero-arity function answering `{:ok, attrs}` or
      `{:error, reason}`. A function rather than a value because the slug
      is resolved against rows this transaction can see.
    * `:seats` — a one-arity function taking the inserted athanor, as
      the plain map the mint answers, and answering `:ok` or
      `{:error, reason}`: the memberships an estate is born with.
  """
  @spec mint(Cyfr.Actor.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def mint(%Cyfr.Actor{scope: :platform}, opts) when is_list(opts) do
    hold = Keyword.get(opts, :hold, [])
    guards = Keyword.get(opts, :guards, [])
    attrs_fun = Keyword.fetch!(opts, :attrs)
    seats_fun = Keyword.get(opts, :seats, fn _athanor -> :ok end)

    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.mint", fn ->
      Arca.Repo.transaction(fn ->
        with :ok <- hold_people(hold),
             :ok <- run_guards(guards),
             {:ok, attrs} <- attrs_fun.(),
             {:ok, athanor} <- do_insert(attrs),
             :ok <- seats_fun.(Arca.Data.project(athanor)) do
          athanor
        else
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def mint(%Cyfr.Actor{}, _opts), do: {:error, :cross_tenant}

  @doc "The athanor row `id` names, whichever tenant it is."
  @spec get(Cyfr.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  def get(%Cyfr.Actor{scope: :platform}, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.get", fn -> read(id) end)
    |> Arca.Data.project()
  end

  def get(%Cyfr.Actor{}, _id), do: {:error, :cross_tenant}

  @doc """
  A person's own athanor, by its owner. At most one exists per person (a
  partial unique index on `owner_user_id` where `kind = 'person'`).
  """
  @spec get_by_owner(Cyfr.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  def get_by_owner(%Cyfr.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.get_by_owner", fn ->
      found(Arca.Repo.get_by(Athanor, kind: "person", owner_user_id: user_id))
    end)
    |> Arca.Data.project()
  end

  def get_by_owner(%Cyfr.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc "The athanor with this kind and slug — how a route segment resolves."
  @spec get_by_slug(Cyfr.Actor.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  def get_by_slug(%Cyfr.Actor{scope: :platform}, kind, slug)
      when is_binary(kind) and is_binary(slug) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.get_by_slug", fn ->
      found(Arca.Repo.get_by(Athanor, kind: kind, slug: slug))
    end)
    |> Arca.Data.project()
  end

  def get_by_slug(%Cyfr.Actor{}, _kind, _slug), do: {:error, :cross_tenant}

  @doc "The ACTIVE frozen estate with this canonical pair key, if there is one."
  @spec get_by_pair_key(Cyfr.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  def get_by_pair_key(%Cyfr.Actor{scope: :platform}, key) when is_binary(key) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.get_by_pair_key", fn ->
      found(
        Arca.Repo.one(
          from(a in Athanor, where: a.pair_key == ^key and a.status == "active", limit: 1)
        )
      )
    end)
    |> Arca.Data.project()
  end

  def get_by_pair_key(%Cyfr.Actor{}, _key), do: {:error, :cross_tenant}

  @doc "The rows these ids name, oldest first. Ids with no row are simply absent."
  @spec list_by_ids(Cyfr.Actor.t(), [String.t()]) :: {:ok, [map()]} | refusal()
  def list_by_ids(%Cyfr.Actor{scope: :platform}, []), do: {:ok, []}

  def list_by_ids(%Cyfr.Actor{scope: :platform}, ids) when is_list(ids) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.list_by_ids", fn ->
      {:ok, Arca.Repo.all(from(a in Athanor, where: a.id in ^ids, order_by: [asc: a.created_at]))}
    end)
    |> Arca.Data.project()
  end

  def list_by_ids(%Cyfr.Actor{}, _ids), do: {:error, :cross_tenant}

  @doc "Every active athanor on the server, oldest first — the roster a scan walks."
  @spec list_active(Cyfr.Actor.t()) :: {:ok, [map()]} | refusal()
  def list_active(%Cyfr.Actor{scope: :platform}) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.list_active", fn ->
      {:ok,
       Arca.Repo.all(
         from(a in Athanor, where: a.status == "active", order_by: [asc: a.created_at])
       )}
    end)
    |> Arca.Data.project()
  end

  def list_active(%Cyfr.Actor{}), do: {:error, :cross_tenant}

  @doc """
  The active athanors a person may work in: their own first, then every
  group an active membership grants, oldest first.

  One row per athanor without `DISTINCT`: the membership assignment index
  admits one active row per person and athanor, and Postgres refuses a
  `SELECT DISTINCT` ordered by an expression outside the select list.
  """
  @spec list_for_user(Cyfr.Actor.t(), String.t()) :: {:ok, [map()]} | refusal()
  def list_for_user(%Cyfr.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.list_for_user", fn ->
      {:ok,
       Arca.Repo.all(
         from(a in Athanor,
           join: m in Membership,
           on: m.athanor_id == a.id,
           where:
             m.user_id == ^user_id and m.scope == "athanor" and m.status == "active" and
               a.status == "active",
           order_by: [desc: a.kind == "person", asc: a.created_at, asc: a.id]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def list_for_user(%Cyfr.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc "How many active athanors this server holds — an archived one frees its place."
  @spec count_active(Cyfr.Actor.t()) :: {:ok, non_neg_integer()} | refusal()
  def count_active(%Cyfr.Actor{scope: :platform}) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.count_active", fn ->
      counted(from(a in Athanor, where: a.status == "active", select: count(a.id)))
    end)
  end

  def count_active(%Cyfr.Actor{}), do: {:error, :cross_tenant}

  @doc "How many person athanors were minted after `since` — the mint-rate cap's measure."
  @spec count_people_created_since(Cyfr.Actor.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | refusal()
  def count_people_created_since(%Cyfr.Actor{scope: :platform}, %DateTime{} = since) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.count_people_created_since", fn ->
      counted(
        from(a in Athanor,
          where: a.kind == "person" and a.created_at > ^since,
          select: count(a.id)
        )
      )
    end)
  end

  def count_people_created_since(%Cyfr.Actor{}, _since), do: {:error, :cross_tenant}

  @doc """
  The ACTIVE open groups this person created — what the per-person group
  cap counts. A frozen pair is not a group they made and is counted by
  `count_pairs_of/2` instead.
  """
  @spec count_groups_created_by(Cyfr.Actor.t(), String.t()) ::
          {:ok, non_neg_integer()} | refusal()
  def count_groups_created_by(%Cyfr.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.count_groups_created_by", fn ->
      counted(
        from(a in Athanor,
          where:
            a.kind == "group" and a.roster == "open" and
              a.created_by == ^user_id and a.status == "active",
          select: count(a.id)
        )
      )
    end)
  end

  def count_groups_created_by(%Cyfr.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc """
  Every ACTIVE pair this person sits in — the pair cap's measure. Counted
  by membership and not by `created_by`: a pair is minted for two, and the
  one who did not click holds it just the same.
  """
  @spec count_pairs_of(Cyfr.Actor.t(), String.t()) :: {:ok, non_neg_integer()} | refusal()
  def count_pairs_of(%Cyfr.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Athanors.count_pairs_of", fn ->
      counted(
        from(a in Athanor,
          join: m in Membership,
          on: m.athanor_id == a.id,
          where:
            m.user_id == ^user_id and m.scope == "athanor" and m.status == "active" and
              a.roster == "frozen" and a.status == "active",
          select: count(a.id)
        )
      )
    end)
  end

  def count_pairs_of(%Cyfr.Actor{}, _user_id), do: {:error, :cross_tenant}

  # ---- internal --------------------------------------------------------------

  defp do_insert(attrs) do
    %Athanor{}
    |> Athanor.create_changeset(defaults(attrs))
    |> Arca.Repo.insert()
    |> settled()
  end

  defp defaults(attrs) do
    now = DateTime.utc_now()

    attrs
    |> Map.new()
    |> Map.put_new(:id, Cyfr.UUID7.generate_id("ath"))
    |> Map.put_new(:created_at, now)
    |> Map.put_new(:updated_at, now)
  end

  # A write to the row holds it until the transaction ends, on either
  # adapter. Sorted, so two mints naming the same people cannot deadlock.
  defp hold_people(ids) do
    ids
    |> Enum.sort()
    |> Enum.each(fn user_id ->
      from(u in User, where: u.id == ^user_id, update: [set: [updated_at: u.updated_at]])
      |> Arca.Repo.update_all([])
    end)
  end

  defp run_guards(guards) do
    Enum.reduce_while(guards, :ok, fn guard, :ok ->
      case guard.() do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp read(id), do: found(Arca.Repo.get(Athanor, id))

  defp found(nil), do: {:error, :not_found}
  defp found(%Athanor{} = athanor), do: {:ok, athanor}

  defp counted(query), do: {:ok, Arca.Repo.one(query) || 0}

  defp settled({:ok, %Athanor{} = athanor}), do: {:ok, athanor}
  defp settled({:error, %Ecto.Changeset{} = changeset}), do: {:error, refusal(changeset)}

  # The unique index on kind and slug is the one refusal a caller acts on
  # rather than reports: a derived slug asks again with the next name.
  defp refusal(%Ecto.Changeset{errors: errors} = changeset) do
    if slug_conflict?(errors), do: :slug_taken, else: Arca.Data.invalid(changeset)
  end

  defp slug_conflict?(errors) do
    Enum.any?(errors, fn {field, {_message, meta}} ->
      field in [:kind, :slug] and meta[:constraint] == :unique
    end)
  end

  defp settings_guard(query, nil), do: from(a in query, where: is_nil(a.settings))
  defp settings_guard(query, expected), do: from(a in query, where: a.settings == ^expected)

  defp landed({1, _}), do: :ok
  defp landed({0, _}), do: :stale
end
