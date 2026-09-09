# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Athanors do
  @moduledoc """
  Athanor rows: create, find, rename, archive.

  An athanor is the unit everything is owned by — a person's or a group's.
  Rows are created here (a person's on first authorized sign-in, a group's
  when a member creates it, Home once per server) and archived, never
  deleted. Filling an athanor with components and consents is the caller's
  job (`Sanctum.Provisioning`), not this module's: a row is a name,
  provisioning is what fills it.

  A person's athanor is archived only through `Sanctum.Tenancy.Users.deny/1`
  (`force: true`); a group is archived by its members or by its last member
  leaving. Home is archived by that last leave alone (never by hand, never
  by a verb) and never comes back: the row stays as the record, its slug is
  released, and `ensure_home/0` mints its successor.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Arca.Schemas.{Athanor, Membership}
  alias Sanctum.Tenancy.Caps

  @doc """
  Insert an athanor. `attrs` must carry `:kind`, `:name`, `:slug` and
  `:created_by`; a person athanor also `:owner_user_id`. `:id` defaults to a
  fresh `ath_` id. The server-wide cap on athanors applies.
  """
  @spec create(map()) :: {:ok, Athanor.t()} | {:error, term()}
  def create(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)

    with :ok <- Caps.check_counted(:max_athanors, &count/0) do
      insert_row(attrs)
    end
  end

  # The insert without the server cap: the caller decides whether the row is
  # a tenant mint (capped) or the server's own Home (not).
  defp insert_row(attrs) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.insert_row", fn ->
      %Athanor{}
      |> Athanor.create_changeset(attrs)
      |> Arca.Repo.insert()
    end)
  end

  @doc """
  Mint a group athanor for `creator_user_id`: the row, its slug (from the
  name, or `:slug`), and the creator's membership — nobody else is added.
  The per-person cap on groups applies.
  """
  @spec create_group(String.t(), String.t(), keyword()) ::
          {:ok, Athanor.t()} | {:error, term()}
  def create_group(creator_user_id, name, opts \\ [])
      when is_binary(creator_user_id) and is_binary(name) do
    name = String.trim(name)

    with :ok <- validate_name(name),
         :ok <-
           Caps.check_counted(:max_groups_per_person, fn ->
             count_groups_created_by(creator_user_id)
           end),
         {:ok, slug} <- resolve_slug(Keyword.get(opts, :slug), name),
         {:ok, athanor} <-
           create(%{kind: "group", name: name, slug: slug, created_by: creator_user_id}),
         {:ok, _} <-
           Sanctum.Tenancy.Members.create(%{
             user_id: creator_user_id,
             scope: "athanor",
             athanor_id: athanor.id,
             added_by: creator_user_id
           }) do
      Sanctum.Tenancy.Members.broadcast_change(creator_user_id, athanor.id, :joined)
      {:ok, athanor}
    end
  end

  @doc """
  The pair of `user_a` and `user_b` — found if it exists, minted if not.

  A DM is a **frozen** group estate: it takes both members at birth and
  `Sanctum.Tenancy.Members.add/3` refuses it another forever. That is what
  lets two people talk without a second tenancy primitive beside the
  athanor — they get a vault, storage, schedules and an audit trail like
  any other estate, and the door is simply closed.

  Find-or-create runs in a transaction keyed on `pair_key`, and a losing
  racer reads the winner rather than reporting a conflict (the
  `or_read_the_winner/1` shape `ensure_home/0` uses). Two people
  double-clicking each other's names get one tape.

  The per-person cap on pairs applies to a mint, and to both people: a
  pair is minted for two, so either one at `CYFR_MAX_PAIRS_PER_PERSON`
  refuses it with `{:error, {:limit_reached, :max_pairs_per_person, cap}}`.
  Finding the existing pair is not a mint and is never capped.

  The row only — it is deliberately **not** provisioned here. A pair that
  owns nothing needs no registry pull, no component scan and no consent
  bootstrap to exist; `Sanctum.Provisioning.ensure_provisioned/1` fills it
  at first need instead, so clicking a name opens a chat immediately
  instead of waiting on the network.
  """
  @spec create_pair(String.t(), String.t()) :: {:ok, Athanor.t()} | {:error, term()}
  def create_pair(user_a, user_b)
      when is_binary(user_a) and is_binary(user_b) and user_a != user_b do
    key = pair_key(user_a, user_b)

    case get_by_pair_key(key) do
      {:ok, athanor} ->
        {:ok, athanor}

      {:error, :not_found} ->
        with :ok <- check_pair_cap(user_a, user_b), do: mint_pair(key, user_a, user_b)

      {:error, _} = err ->
        err
    end
  end

  def create_pair(_, _), do: {:error, :invalid_pair}

  # A pair is minted for two, so the cap is asked for both. Without it one
  # member of a large room could mint an estate per co-member from the
  # wire — a DM asks nobody else's consent — and spend `CYFR_MAX_ATHANORS`
  # for everyone.
  defp check_pair_cap(user_a, user_b) do
    Enum.reduce_while([user_a, user_b], :ok, fn user_id, :ok ->
      case Caps.check_counted(:max_pairs_per_person, fn -> count_pairs_of(user_id) end) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  The canonical key for a pair of people: order-independent, so
  `{alice, bob}` and `{bob, alice}` name the same estate. Exactly two ids
  — a pair is what a frozen estate holds, and a key over any other number
  would name nothing `create_pair/2` can find.

  Hashes the JSON encoding of sorted member ids, preserving unambiguous boundaries.
  """
  @spec pair_key([String.t()] | String.t(), String.t() | nil) :: String.t()
  def pair_key(user_a, user_b) when is_binary(user_a) and is_binary(user_b),
    do: pair_key([user_a, user_b], nil)

  def pair_key([a, b] = user_ids, nil) when is_binary(a) and is_binary(b) do
    user_ids
    |> Enum.sort()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  @doc "The active frozen estate with this canonical key, if there is one."
  @spec get_by_pair_key(String.t()) :: {:ok, Athanor.t()} | {:error, :not_found | :database_error}
  def get_by_pair_key(key) when is_binary(key) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.get_by_pair_key", fn ->
      case Arca.Repo.one(
             from(a in Athanor, where: a.pair_key == ^key and a.status == "active", limit: 1)
           ) do
        nil -> {:error, :not_found}
        athanor -> {:ok, athanor}
      end
    end)
  end

  defp mint_pair(key, user_a, user_b) do
    name = pair_name(user_a, user_b)

    result =
      Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.mint_pair", fn ->
        Arca.Repo.transaction(fn ->
          with {:ok, slug} <- resolve_slug(nil, name),
               {:ok, athanor} <-
                 create(%{
                   kind: "group",
                   roster: "frozen",
                   pair_key: key,
                   name: name,
                   slug: slug,
                   created_by: user_a
                 }),
               {:ok, _} <- seat(athanor, user_a),
               {:ok, _} <- seat(athanor, user_b) do
            athanor
          else
            {:error, reason} -> Arca.Repo.rollback(reason)
          end
        end)
      end)

    case result do
      {:ok, athanor} ->
        for user_id <- [user_a, user_b],
            do: Sanctum.Tenancy.Members.broadcast_change(user_id, athanor.id, :joined)

        {:ok, athanor}

      # The unique index is the arbiter: a concurrent double-click loses
      # here and reads the tape the winner made. Anything else is a real
      # failure and keeps its reason — a bare `:pair_not_created` would
      # report "could not open the chat" for a slug clash, a cap, and a
      # database outage alike.
      {:error, reason} ->
        case get_by_pair_key(key) do
          {:ok, athanor} -> {:ok, athanor}
          _ -> {:error, reason}
        end
    end
  end

  # A pair's two seats, at birth — the one write a frozen roster admits.
  defp seat(athanor, user_id) do
    Sanctum.Tenancy.Members.create(
      %{user_id: user_id, scope: "athanor", athanor_id: athanor.id, added_by: user_id},
      birth: true
    )
  end

  # Both display names, so the estate reads as the two people in it. The
  # slug's own collision fallback handles two pairs of same-named people.
  defp pair_name(user_a, user_b) do
    [user_a, user_b]
    |> Enum.map(&Sanctum.Tenancy.Users.display_name/1)
    |> Enum.sort()
    |> Enum.join(" & ")
    |> String.slice(0, 80)
  end

  @doc """
  How an estate is named to one of its members: a frozen pair by the
  OTHER person — to `user_id`, a DM is whoever they are talking to, never
  the stored "A & B" — and any other estate by its own name. The stored
  name stands in when the other seat cannot be read (an ended pair holds
  one member).
  """
  @spec pair_label(Athanor.t(), String.t() | nil) :: String.t()
  def pair_label(%Athanor{roster: "frozen", id: id, name: name}, user_id)
      when is_binary(user_id) do
    with {:ok, rows} <- Sanctum.Tenancy.Members.list_by_athanor(id),
         %{user_id: other} <- Enum.find(rows, &other_seat?(&1, user_id)) do
      Sanctum.Tenancy.Users.display_name(other)
    else
      _ -> name
    end
  end

  def pair_label(%Athanor{name: name}, _user_id), do: name

  defp other_seat?(%{user_id: other, status: "active"}, user_id) when is_binary(other),
    do: other != user_id

  defp other_seat?(_row, _user_id), do: false

  @spec get(String.t()) :: {:ok, Athanor.t()} | {:error, :not_found | :database_error}
  def get(id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.get", fn ->
      case Arca.Repo.get(Athanor, id) do
        nil -> {:error, :not_found}
        athanor -> {:ok, athanor}
      end
    end)
  end

  @doc """
  A person's own athanor, by its owner. At most one exists per person
  (a partial unique index on `owner_user_id` where `kind = 'person'`).
  """
  @spec get_by_owner(String.t()) :: {:ok, Athanor.t()} | {:error, :not_found | term()}
  def get_by_owner(user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.get_by_owner", fn ->
      case Arca.Repo.get_by(Athanor, kind: "person", owner_user_id: user_id) do
        nil -> {:error, :not_found}
        athanor -> {:ok, athanor}
      end
    end)
  end

  @doc "Find an athanor by kind and slug."
  @spec get_by_slug(String.t(), String.t()) ::
          {:ok, Athanor.t()} | {:error, :not_found | :database_error}
  def get_by_slug(kind, slug) when is_binary(kind) and is_binary(slug) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.get_by_slug", fn ->
      case Arca.Repo.get_by(Athanor, kind: kind, slug: slug) do
        nil -> {:error, :not_found}
        athanor -> {:ok, athanor}
      end
    end)
  end

  @doc """
  Resolve a route segment: `@<namespace>` names a person's athanor, a bare
  slug a group's. Only active athanors resolve, unless the caller passes
  `include_archived: true` (a read that must still see an archived row —
  `athanor.get`, `unarchive`).
  """
  @spec by_route_slug(String.t(), keyword()) :: {:ok, Athanor.t()} | {:error, :not_found}
  def by_route_slug(segment, opts \\ [])

  def by_route_slug("@" <> namespace, opts) when namespace != "" do
    get_by_slug("person", namespace) |> status_gate(opts)
  end

  def by_route_slug(slug, opts) when is_binary(slug) and slug != "" do
    get_by_slug("group", slug) |> status_gate(opts)
  end

  def by_route_slug(_, _opts), do: {:error, :not_found}

  @doc "The route segment for an athanor: `@<slug>` for a person, the slug for a group."
  @spec route_slug(Athanor.t()) :: String.t()
  def route_slug(%Athanor{kind: "person", slug: slug}), do: "@" <> slug
  def route_slug(%Athanor{slug: slug}), do: slug

  @doc """
  The server's Home athanor — the group every server has. Found by its flag,
  never by a fixed id, and only while it is active: a retired Home keeps the
  flag as its record but is nobody's Home any more.
  """
  @spec home() :: {:ok, Athanor.t()} | {:error, :not_found | :database_error}
  def home do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.home", fn ->
      case Arca.Repo.one(
             from(a in Athanor, where: a.home == true and a.status == "active", limit: 1)
           ) do
        nil -> {:error, :not_found}
        athanor -> {:ok, athanor}
      end
    end)
  end

  @doc """
  The server's Home, minting one when the last was retired by its final
  member leaving. The row only — filling it (seed + consents) is the
  caller's job, as for every other athanor. Home is the server's own
  furnace, not somebody's mint, so the per-server cap does not bind it.
  """
  @spec ensure_home() :: {:ok, Athanor.t()} | {:error, term()}
  def ensure_home do
    case home() do
      {:ok, athanor} ->
        {:ok, athanor}

      {:error, :not_found} ->
        with {:ok, slug} <- resolve_slug(nil, "Home") do
          %{
            id: generate_id(),
            kind: "group",
            name: "Home",
            slug: slug,
            home: true,
            created_by: "system",
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
          |> insert_row()
          |> or_read_the_winner()
        end

      {:error, _} = err ->
        err
    end
  end

  # Two callers can find no Home and both go on to mint one. The
  # `athanors_home_index` partial unique index means exactly one insert
  # lands; the loser's job is to read the row that did, not to report a
  # broken install to whoever is booting the server.
  defp or_read_the_winner({:ok, _} = ok), do: ok

  defp or_read_the_winner({:error, _} = err) do
    case home() do
      {:ok, athanor} -> {:ok, athanor}
      _ -> err
    end
  end

  @doc "Like `home/0`, raising when the seed is missing — a broken install."
  @spec home!() :: Athanor.t()
  def home! do
    case home() do
      {:ok, athanor} ->
        athanor

      # A refusal, not a bare string: the seed being absent is an
      # authorization-shaped fact (there is no athanor to work in), and
      # `Sanctum.UnauthorizedError` is what every other surface renders for
      # that — a `RuntimeError` here rendered as a 500 with the internal
      # reason inspected into the message.
      {:error, reason} ->
        require Logger
        Logger.error("[Sanctum.Tenancy.Athanors] no Home athanor: #{inspect(reason)}")
        raise Sanctum.UnauthorizedError, reason: :missing_tenant
    end
  end

  @spec update(Athanor.t(), map()) :: {:ok, Athanor.t()} | {:error, term()}
  def update(%Athanor{} = athanor, attrs) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.update", fn ->
      attrs = attrs |> Map.new() |> Map.put(:updated_at, DateTime.utc_now())

      athanor
      |> Athanor.update_changeset(attrs)
      |> Arca.Repo.update()
    end)
  end

  @doc "Rename an athanor. The slug stays: it is an address."
  @spec rename(Athanor.t(), String.t()) :: {:ok, Athanor.t()} | {:error, term()}
  def rename(%Athanor{} = athanor, name) when is_binary(name) do
    name = String.trim(name)

    with :ok <- validate_name(name) do
      update(athanor, %{name: name})
    end
  end

  @doc """
  Mark an athanor archived. Nothing is deleted; every ingress gate refuses
  it, its API keys are revoked, whatever is running in it is cancelled, and
  its members are told — the same on every path that archives (a member's
  `athanor.archive`, the last member leaving, a person being denied), so no
  path leaves work running in a furnace nobody may enter.

  A person's athanor refuses unless `force: true` — the arm
  `Sanctum.Tenancy.Users.deny/1` uses when it ejects a person. Home refuses
  everything but `reason: :empty`, the last member leaving: no verb and no
  operator retires the server's own furnace by hand. A retired Home also
  releases its slug, so its successor is reachable where Home has always
  been.
  """
  @spec archive(Athanor.t(), keyword()) :: {:ok, Athanor.t()} | {:error, term()}
  def archive(%Athanor{} = athanor, opts \\ []) do
    # Re-read first: callers often hold a struct from before the last change,
    # and a changeset built on a stale status would write nothing.
    with {:ok, current} <- get(athanor.id) do
      cond do
        current.status == "archived" ->
          # Idempotent — but a retry after a half-finished archive still
          # closes what the first attempt may not have reached.
          close(current)
          {:ok, current}

        current.home and Keyword.get(opts, :reason) != :empty ->
          {:error, :home_cannot_be_archived}

        current.kind == "person" and not Keyword.get(opts, :force, false) ->
          {:error, :person_athanor_cannot_be_archived}

        true ->
          with {:ok, archived} <- update(current, archived_attrs(current)) do
            close(archived)
            Sanctum.Notify.broadcast(archived.id, :athanor_changed, %{name: archived.name})
            {:ok, archived}
          end
      end
    end
  end

  defp archived_attrs(%Athanor{home: true} = current) do
    %{status: "archived", archived_at: DateTime.utc_now(), slug: retired_slug(current.slug)}
  end

  defp archived_attrs(%Athanor{}), do: %{status: "archived", archived_at: DateTime.utc_now()}

  # A retired Home hands its address to its successor: the row keeps the flag
  # and the name for the record, under the next free `<slug>-N`.
  defp retired_slug(slug) do
    base = suffixable(slug)

    Enum.find_value(2..50, slug, fn n ->
      candidate = "#{base}-#{n}"
      if slug_free?("group", candidate), do: candidate
    end)
  end

  # What archiving closes: standing credentials and in-flight work. Runs as
  # the server inside the athanor (an internal context focused on it —
  # cancellation is attributed to `system`); best effort, since the status
  # gates already refuse new work.
  defp close(%Athanor{id: id}) do
    Sanctum.ApiKey.revoke_all_for_athanor(id)
    cancel_running(id)
    :ok
  end

  defp cancel_running(athanor_id) do
    if Cyfr.Execution.available?() do
      ctx = Sanctum.internal_context(athanor_id: athanor_id, scope: :athanor)

      case Cyfr.Execution.list(ctx, status: :running, limit: 500) do
        {:ok, running} when is_list(running) ->
          Enum.each(running, fn %{id: id} -> Cyfr.Execution.cancel(ctx, id) end)

        _ ->
          :ok
      end
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "[Sanctum.Tenancy.Athanors] cancel on archive failed (#{Exception.message(e)})"
      )

      :ok
  end

  @doc """
  Delete an archived athanor's whole storage tree — the one verb that
  reclaims `athanors/{id}/` from the volume (or the bucket). Archiving never
  touches storage, precisely so `unarchive/1` reopens a furnace intact;
  purging is the separate, deliberate, final act. It refuses unless the
  athanor is archived, and a purged athanor that later reopens comes back
  with empty storage (its rows are untouched — this deletes blobs only).
  """
  @spec purge_storage(Athanor.t()) :: :ok | {:error, term()}
  def purge_storage(%Athanor{} = athanor) do
    with {:ok, current} <- get(athanor.id) do
      if current.status == "archived" do
        ctx = Sanctum.internal_context(athanor_id: current.id, scope: :athanor)

        with :ok <- Arca.delete_tree(ctx, []) do
          # The write gate invalidates the whole-tree counter, but the
          # empty path names no scope, so the per-scope pairs would
          # otherwise survive until their TTL — drop them all.
          Arca.Usage.invalidate(current.id)
        end
      else
        {:error, :not_archived}
      end
    end
  end

  @doc """
  Erase an archived athanor: its blobs AND its rows. Final.

  The one verb that actually deletes a tenant's data.
  `purge_storage/1` above reclaims the volume and leaves every row
  standing; `Cyfr.Retention` skips archived athanors because purging is
  supposed to be the reclaim. So nothing deleted rows at all, and after
  archive + purge every sealed vault payload, webhook secret, OAuth
  ciphertext, execution, message and log stayed in the database and in
  every backup taken afterwards.

  ## What it keeps, and why

  The `athanors` row itself survives as an archived tombstone. Home
  succession reads it (`home!/0` matches `home AND status = 'active'`, so
  a tombstoned Home already lets `ensure_home/0` mint a successor), and an
  audit trail that loses the fact an athanor ever existed cannot answer
  "what happened to it". Everything the tombstone owned is gone.

  ## What it refuses

  A **personal** athanor. `users.personal_athanor_id` is not an
  athanor-scoped column and would still name the tombstone: the unique
  index would then block minting a replacement, and
  `Users.unarchive_personal/1` would try to reopen a wiped shell. Erasing
  a person is a different act with different consequences —
  `Sanctum.Door`'s deny and `archive/1` are the person-level verbs.

  An athanor that is not archived, for the same reason `purge_storage/1`
  does: archiving is the reviewable step that precedes the irreversible
  one.
  """
  @spec destroy(Athanor.t()) :: {:ok, map()} | {:error, term()}
  def destroy(%Athanor{} = athanor) do
    with {:ok, current} <- get(athanor.id),
         :ok <- check_destroyable(current),
         :ok <- Arca.delete_tree(internal_ctx(current), []),
         {:ok, counts} <- Arca.TenantTables.delete_all_for(current.id) do
      Arca.Usage.invalidate(current.id)

      Logger.warning(
        "[Sanctum.Tenancy.Athanors] destroyed #{current.id}: " <>
          "#{counts |> Map.values() |> Enum.sum()} rows across #{map_size(counts)} tables"
      )

      {:ok, counts}
    end
  end

  defp check_destroyable(%Athanor{status: status}) when status != "archived",
    do: {:error, :not_archived}

  defp check_destroyable(%Athanor{id: id}) do
    if Sanctum.Tenancy.Users.personal_athanor?(id) do
      {:error, :personal_athanor}
    else
      :ok
    end
  end

  defp internal_ctx(%Athanor{id: id}),
    do: Sanctum.internal_context(athanor_id: id, scope: :athanor)

  @doc """
  Reopen an archived athanor, if the server still has room for it. A retired
  Home never reopens — it is the record of a furnace that ended;
  `ensure_home/0` mints its successor. Nor does an ended DM: a frozen
  estate is archived the moment either person leaves, so its husk holds
  one member, and reopening it would seat that person alone in a second
  You. Clicking the name again mints a new pair instead.
  """
  @spec unarchive(Athanor.t()) :: {:ok, Athanor.t()} | {:error, term()}
  def unarchive(%Athanor{} = athanor) do
    with {:ok, current} <- get(athanor.id) do
      cond do
        current.home ->
          {:error, :home_is_final}

        current.roster == "frozen" ->
          {:error, :frozen_is_final}

        current.status == "active" ->
          {:ok, current}

        true ->
          # An archived athanor freed its place against the server cap when it
          # closed; taking the place back has to ask for it, or archiving and
          # reopening would be the way past `CYFR_MAX_ATHANORS`.
          with :ok <- Caps.check_counted(:max_athanors, &count/0) do
            update(current, %{status: "active", archived_at: nil})
          end
      end
    end
  end

  @doc """
  Record that provisioning (seed + consents) completed — and forget any
  earlier failure recorded on the row.
  """
  @spec mark_provisioned(Athanor.t()) :: {:ok, Athanor.t()} | {:error, term()}
  def mark_provisioned(%Athanor{} = athanor) do
    settings = athanor |> settings() |> Map.delete("provisioning_error")

    update(athanor, %{
      provisioned_at: DateTime.utc_now(),
      settings: Jason.encode!(settings)
    })
  end

  @spec list_by_ids([String.t()]) :: [Athanor.t()]
  def list_by_ids([]), do: []

  def list_by_ids(ids) when is_list(ids) do
    # Deliberate default: a display batch-read over ids the caller already
    # holds — an outage renders an empty list, it grants or archives nothing.
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.list_by_ids", [], fn ->
      Arca.Repo.all(from(a in Athanor, where: a.id in ^ids, order_by: [asc: a.created_at]))
    end)
  end

  @doc """
  Every active athanor on the server, oldest first — the roster server-side
  scans walk (the tincture registry rebuilds itself from it). Uncapped: this
  is the server's own tenant roster, not a user page.
  """
  @spec list_active() :: [Athanor.t()]
  def list_active do
    # Deliberate default: the roster scan's read — a scan that sees [] this
    # cadence walks the full roster on the next one; nothing is deleted on it.
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.list_active", [], fn ->
      Arca.Repo.all(
        from(a in Athanor, where: a.status == "active", order_by: [asc: a.created_at])
      )
    end)
  end

  @doc """
  The active athanors a person may work in: their own, then every group an
  active membership grants, oldest first. Uncapped — a person's memberships
  are few, and a truncated list would hide a chat.

  One row per athanor without `DISTINCT`: the membership assignment index
  admits one active row per person and athanor, and Postgres refuses a
  `SELECT DISTINCT` ordered by an expression outside the select list.
  """
  @spec list_for_user(String.t()) :: [Athanor.t()]
  def list_for_user(user_id) when is_binary(user_id) do
    # Deliberate default: a person's sidebar roster — an outage shows fewer
    # rooms, never more; entering one still resolves membership strictly.
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.list_for_user", [], fn ->
      Arca.Repo.all(
        from(a in Athanor,
          join: m in Membership,
          on: m.athanor_id == a.id,
          where:
            m.user_id == ^user_id and m.scope == "athanor" and m.status == "active" and
              a.status == "active",
          order_by: [desc: a.kind == "person", asc: a.created_at, asc: a.id]
        )
      )
    end)
  end

  @doc "Whether the athanor exists and is active."
  @spec active?(String.t() | nil) :: boolean()
  def active?(id) when is_binary(id) and id != "" do
    case get(id) do
      {:ok, %Athanor{status: "active"}} -> true
      _ -> false
    end
  end

  def active?(_), do: false

  @doc """
  How many person athanors were minted after `since` — the mint-rate cap's
  measure; groups people create are bounded by their own cap. Strict: a
  count the store cannot answer is `{:error, :database_error}`, never a
  zero the cap would admit past its ceiling.
  """
  @spec count_created_since(DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_created_since(%DateTime{} = since) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.count_created_since", fn ->
      {:ok,
       Arca.Repo.one(
         from(a in Athanor,
           where: a.kind == "person" and a.created_at > ^since,
           select: count(a.id)
         )
       ) || 0}
    end)
  end

  @doc """
  How many active athanors this server holds — an archived one frees its
  place. Strict like `count_created_since/1`: the caps consult this, and
  an unanswerable count must refuse, not read as an empty server.
  """
  @spec count() :: {:ok, non_neg_integer()} | {:error, :database_error}
  def count do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.count", fn ->
      {:ok,
       Arca.Repo.one(from(a in Athanor, where: a.status == "active", select: count(a.id))) || 0}
    end)
  end

  @doc "The athanor's settings document (JSON on the row), as a map."
  @spec settings(Athanor.t()) :: map()
  def settings(%Athanor{settings: nil}), do: %{}

  def settings(%Athanor{settings: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc """
  Merge `patch` into the athanor's settings document, one level deep: a map
  under a key merges into the map already there (so a `"retention"` patch
  naming one window leaves the other windows alone), a `nil` deletes the
  key, anything else replaces (a `"provisioning_error"` is recorded whole).
  Every member's open views hear of the change on the athanor's notify
  topic.
  """
  @spec put_settings(Athanor.t(), map()) :: {:ok, Athanor.t()} | {:error, term()}
  def put_settings(%Athanor{} = athanor, patch) when is_map(patch) do
    put_settings_cas(athanor, patch, 3)
  end

  defp put_settings_cas(_athanor, _patch, 0), do: {:error, :settings_conflict}

  defp put_settings_cas(%Athanor{} = athanor, patch, attempts) do
    # Merge against the current row with compare-and-set to avoid lost updates.
    # If the read fails, fall back to the caller's copy.
    current =
      case get(athanor.id) do
        {:ok, fresh} -> fresh
        _ -> athanor
      end

    merged = deep_merge(settings(current), patch)
    encoded = Jason.encode!(merged)
    now = DateTime.utc_now()

    result =
      Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.put_settings", fn ->
        from(a in Athanor, where: a.id == ^current.id)
        |> settings_guard(current.settings)
        |> Arca.Repo.update_all(set: [settings: encoded, updated_at: now])
      end)

    case result do
      {1, _} ->
        with {:ok, updated} <- get(current.id) do
          Sanctum.Notify.broadcast(updated.id, :athanor_changed, %{name: updated.name})
          {:ok, updated}
        end

      {0, _} ->
        put_settings_cas(athanor, patch, attempts - 1)

      {:error, _} = error ->
        error
    end
  end

  defp settings_guard(query, nil), do: from(a in query, where: is_nil(a.settings))
  defp settings_guard(query, expected), do: from(a in query, where: a.settings == ^expected)

  defp deep_merge(base, patch) do
    Enum.reduce(patch, base, fn
      {key, nil}, acc ->
        Map.delete(acc, key)

      {key, value}, acc when is_map(value) ->
        case Map.get(acc, key) do
          existing when is_map(existing) -> Map.put(acc, key, deep_merge(existing, value))
          _ -> Map.put(acc, key, value)
        end

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  # ---- internal --------------------------------------------------------------

  defp status_gate({:ok, %Athanor{status: "active"} = athanor}, _opts), do: {:ok, athanor}

  defp status_gate({:ok, %Athanor{} = athanor}, opts) do
    if Keyword.get(opts, :include_archived, false),
      do: {:ok, athanor},
      else: {:error, :not_found}
  end

  defp status_gate(_, _opts), do: {:error, :not_found}

  defp validate_name(name) when byte_size(name) in 1..80, do: :ok
  defp validate_name(_), do: {:error, :invalid_name}

  # A slug given explicitly must be valid and free; one derived from the name
  # gets a numeric suffix when taken.
  defp resolve_slug(explicit, _name) when is_binary(explicit) do
    if Sanctum.Slug.valid?(explicit) and slug_free?("group", explicit),
      do: {:ok, explicit},
      else: {:error, :slug_taken_or_invalid}
  end

  defp resolve_slug(nil, name), do: derived_slug("group", name)

  @doc """
  A free slug for a person's own athanor: `hint` (their cyfr.run namespace,
  when they have one) if it is valid and free, else one derived from
  `name` with a numeric suffix. A person's athanor is minted at sign-in,
  before any namespace exists, so the slug is this server's — an address,
  not an identity — and a hint another person's athanor already holds is
  no refusal, it just is not the address.
  """
  @spec person_slug(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, term()}
  def person_slug(hint, name) do
    if is_binary(hint) and Sanctum.Slug.valid?(hint) and slug_free?("person", hint),
      do: {:ok, hint},
      else: derived_slug("person", name)
  end

  defp derived_slug(kind, name) do
    case Sanctum.Slug.from_name(name) do
      nil ->
        {:error, :invalid_name}

      base ->
        stem = suffixable(base)
        candidates = [base | Enum.map(2..50, &"#{stem}-#{&1}")]

        case Enum.find(candidates, &slug_free?(kind, &1)) do
          nil -> {:error, :slug_taken_or_invalid}
          slug -> {:ok, slug}
        end
    end
  end

  # The stem a numeric suffix is appended to: truncated to leave room, and
  # with any trailing hyphen removed. Cutting a slug at a fixed width lands
  # on a hyphen often enough, and `"...-" <> "-2"` is a double hyphen —
  # which the slug grammar (single hyphens only) then rejects, so the mint
  # fails with a format error rather than taking the next free name. Long
  # names hit this: a pair estate named from two email-derived display
  # names is over the limit before it starts.
  defp suffixable(base), do: base |> String.slice(0, 36) |> String.trim_trailing("-")

  # Per kind: the unique index is `[kind, slug]`, so a group slug never
  # collides with a person's and each is checked against its own kind.
  defp slug_free?(kind, slug), do: match?({:error, :not_found}, get_by_slug(kind, slug))

  # Only the groups a person deliberately made. A frozen pair is a
  # conversation, not a group they created, and counting DMs against
  # `CYFR_MAX_GROUPS_PER_PERSON` would make the cap mean "how many people
  # may you talk to" — which is not what an operator setting it intends.
  # DMs have their own ceiling, `CYFR_MAX_PAIRS_PER_PERSON`, counted by
  # `count_pairs_of/1` below.
  defp count_groups_created_by(user_id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.count_groups_created_by", fn ->
      {:ok,
       Arca.Repo.one(
         from(a in Athanor,
           where:
             a.kind == "group" and a.roster == "open" and
               a.created_by == ^user_id and a.status == "active",
           select: count(a.id)
         )
       ) || 0}
    end)
  end

  # Every ACTIVE pair a person sits in — the pair cap's measure. Counted by
  # membership, not by `created_by`: a pair is minted for two, and the one
  # who did not click holds it just the same. An ended pair is archived
  # and frees its place. Strict like the other counts the caps consult.
  defp count_pairs_of(user_id) do
    Arca.Repo.Errors.with_db_rescue("Sanctum.Tenancy.Athanors.count_pairs_of", fn ->
      {:ok,
       Arca.Repo.one(
         from(a in Athanor,
           join: m in Membership,
           on: m.athanor_id == a.id,
           where:
             m.user_id == ^user_id and m.scope == "athanor" and m.status == "active" and
               a.roster == "frozen" and a.status == "active",
           select: count(a.id)
         )
       ) || 0}
    end)
  end

  @doc """
  Whether `value` is an athanor id (`"ath_..."`) rather than a route slug.
  Discriminating by prefix is sound: the slug grammar (`Sanctum.Slug` /
  `Sanctum.ComponentRef.personal_slug_regex/0`) admits only lowercase
  alphanumerics and hyphens — a slug can never contain `"_"`.
  """
  @spec athanor_id?(term()) :: boolean()
  def athanor_id?(value), do: is_binary(value) and String.starts_with?(value, "ath_")

  defp generate_id, do: Cyfr.UUID7.generate_id("ath")
end
