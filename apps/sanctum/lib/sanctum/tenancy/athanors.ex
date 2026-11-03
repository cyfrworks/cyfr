# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Athanors do
  @moduledoc """
  Athanor rows: create, find, rename, archive.

  An athanor is the unit everything is owned by — one person's. Rows are
  created here, inside the person's admission's transaction
  (`Sanctum.Provisioning.mint_personal/1`), and archived, never deleted.
  Filling an athanor with components and consents is the caller's job
  (`Sanctum.Provisioning`), not this module's: a row is a name,
  provisioning is what fills it.

  An athanor is archived only by its person's denial
  (`Sanctum.Tenancy.Users.deny/1`) or by `archive/2` with `force: true`.

  ## What is decided here, and what is stored below

  The statements are `Arca.Athanors`'. What stays here is the deciding:
  which cap a mint must pass, what a slug may be, when an archive is
  refused, what an unanswerable read should read as, and who is told
  afterwards. Every call names the actor it runs as — the server
  (`Prima.Actor.system/0`) for the fabric reads that choose an athanor,
  and the server narrowed to one athanor for every write that must land
  in exactly that one.
  """

  require Logger

  alias Sanctum.Tenancy.Caps

  @typedoc "An athanor's row, as the plain map `Arca.Athanors` answers."
  @type athanor :: %{required(:id) => String.t(), optional(atom()) => term()}

  @doc """
  Insert an athanor. `attrs` must carry `:name`, `:slug`, `:owner_user_id`
  and `:created_by`. `:id` defaults to a
  fresh `ath_` id. The server-wide cap on athanors applies, counted in the
  transaction that inserts the row with the owner's row held
  (`Arca.Athanors.mint/2`), so two creations at the server's last place
  cannot both land.
  """
  @spec create(map()) :: {:ok, athanor()} | {:error, term()}
  def create(attrs) do
    attrs = Map.new(attrs)

    Arca.Athanors.mint(server(), hold: owner(attrs), caps: [:max_athanors], attrs: attrs)
  end

  defp owner(%{owner_user_id: user_id}) when is_binary(user_id), do: [user_id]
  defp owner(_attrs), do: []

  @doc """
  Mint a person's own athanor, inside their admission's transaction
  (`Sanctum.Provisioning.mint_personal/1`): the row, with the first slug of
  `slugs` no athanor holds, and its owner seated, in one
  `Arca.Athanors.mint/2` under the census lock, so two admissions cannot
  take one slug. It counts no cap: the admission counted the server-wide
  cap before the person's row (`personal_place/0`), or is the
  installation's administrator, minted past it.
  """
  @spec create_personal(map(), [String.t()]) :: {:ok, athanor()} | {:error, term()}
  def create_personal(%{owner_user_id: user_id} = attrs, slugs)
      when is_binary(user_id) and is_list(slugs) do
    Arca.Athanors.mint(server(),
      hold: [user_id],
      slugs: slugs,
      attrs: attrs,
      also: fn athanor ->
        case Sanctum.Tenancy.Members.create(%{
               user_id: user_id,
               scope: "athanor",
               athanor_id: athanor.id
             }) do
          {:ok, _seat} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  @doc """
  Inside an admission's transaction, before its person's row: the
  server-wide cap on athanors, counted under the census lock, which holds
  to the transaction's end so the place counted free stays free for the
  person's athanor (`Arca.Athanors.within_caps/2`).
  """
  @spec personal_place() :: :ok | {:error, term()}
  def personal_place, do: Arca.Athanors.within_caps(server(), [:max_athanors])

  @spec get(String.t()) :: {:ok, athanor()} | {:error, :not_found | :database_error}
  def get(id) when is_binary(id), do: Arca.Athanors.get(server(), id)

  @doc """
  A person's own athanor, by its owner. At most one exists per person
  (a unique index on `owner_user_id`).
  """
  @spec get_by_owner(String.t()) :: {:ok, athanor()} | {:error, :not_found | term()}
  def get_by_owner(user_id) when is_binary(user_id),
    do: Arca.Athanors.get_by_owner(server(), user_id)

  @doc "Find an athanor by slug."
  @spec get_by_slug(String.t()) :: {:ok, athanor()} | {:error, :not_found | :database_error}
  def get_by_slug(slug) when is_binary(slug), do: Arca.Athanors.get_by_slug(server(), slug)

  @doc """
  Resolve a route segment: `@<namespace>` names a person's athanor. Only
  active athanors resolve, unless the caller passes
  `include_archived: true` (a read that must still see an archived row —
  `athanor.get`, `unarchive`).
  """
  @spec by_route_slug(String.t(), keyword()) :: {:ok, athanor()} | {:error, :not_found}
  def by_route_slug(segment, opts \\ [])

  def by_route_slug("@" <> namespace, opts) when namespace != "" do
    get_by_slug(namespace) |> status_gate(opts)
  end

  def by_route_slug(_, _opts), do: {:error, :not_found}

  @doc "The route segment for an athanor: `@<slug>`."
  @spec route_slug(athanor()) :: String.t()
  def route_slug(%{slug: slug}), do: "@" <> slug

  @doc "Rename an athanor. The slug stays: it is an address."
  @spec rename(athanor(), String.t()) :: {:ok, athanor()} | {:error, term()}
  def rename(%{id: _} = athanor, name) when is_binary(name) do
    name = String.trim(name)

    with :ok <- validate_name(name) do
      Arca.Athanors.update(in_athanor(athanor.id), %{name: name})
    end
  end

  @doc """
  Mark an athanor archived. Nothing is deleted; every ingress gate refuses
  it, its API keys and its shares are revoked in the same transaction
  (`Arca.SecurityTransitions.archive_athanor/3`), whatever is running in
  it is cancelled, the established-context memo of its person is dropped
  and they are told — the same on every path that archives, so no path
  leaves work running in a furnace nobody may enter.
  The announcements follow the commit and are made from what it returned.

  It refuses unless `force: true`. An athanor already
  archived is archived again: its keys are revoked and checked again and
  its archival announced again, so a retry reaches whatever a lost
  announcement did not.
  """
  @spec archive(athanor(), keyword()) :: {:ok, athanor()} | {:error, term()}
  def archive(%{id: id} = athanor, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    verify = fn
      %{athanor: %{status: "active"}} when not force? ->
        {:error, :archive_not_forced}

      _rows ->
        :ok
    end

    with {:ok, change} <- Arca.SecurityTransitions.archive_athanor(server(), id, verify: verify) do
      announce_archived([id], change)
      Sanctum.Shares.announce_each(nil, :revoked, change.revoked_share_ids)
      {:ok, committed(athanor, change)}
    end
  end

  @doc """
  Announce athanors a committed transition archived, from the data it
  returned: each member's established-context memo is dropped, before
  this returns — the memo caches an AUTHORIZATION decision, so an archive
  that only flipped the status would leave every member working inside
  the shut furnace until their memo aged out — and the archival is
  announced, which is what stops in-flight work
  (`Opus.ArchiveWatch`) and the processes serving the athanor
  from outside any tenant topic; the status gates already refuse new work
  either way. Athanors the transition actually moved tell their members'
  open views.
  """
  @spec announce_archived([String.t()], map()) :: :ok
  def announce_archived(ids, %{member_user_ids: members, athanors: moved}) do
    for id <- ids do
      members |> Map.get(id, []) |> Enum.each(&Sanctum.Session.invalidate_memo_for_user/1)
      Sanctum.Telemetry.athanor_archived(id)
    end

    for %{id: id, name: name, status: "archived"} <- moved do
      Sanctum.Notify.broadcast(id, :athanor_changed, %{name: name})
    end

    :ok
  end

  # The row the caller named, as the transition left it: reread after
  # commit, and — should that read fail — the caller's copy carrying the
  # standing the commit returned, never an error for what did commit.
  defp committed(%{id: id} = athanor, change) do
    case get(id) do
      {:ok, current} ->
        current

      {:error, _reason} ->
        case Enum.find(change.athanors, &(&1.id == id)) do
          nil ->
            athanor

          moved ->
            %{
              athanor
              | status: moved.status,
                archived_at: moved.archived_at,
                security_generation: moved.security_generation
            }
        end
    end
  end

  @doc """
  Delete an archived athanor's whole storage tree — the one verb that
  reclaims `athanors/{id}/` from the volume (or the bucket). Archiving never
  touches storage, precisely so `unarchive/1` reopens a furnace intact;
  purging is the separate, deliberate, final act. It refuses unless the
  athanor is archived, and a purged athanor that later reopens comes back
  with empty storage (its rows are untouched — this deletes blobs only).
  """
  @spec purge_storage(athanor()) :: :ok | {:error, term()}
  def purge_storage(%{id: _} = athanor) do
    with {:ok, current} <- get(athanor.id) do
      if current.status == "archived" do
        ctx = Sanctum.Context.internal(athanor_id: current.id, scope: :athanor)

        with :ok <- Arca.delete_tree(Sanctum.Context.actor(ctx), []) do
          # The write gate invalidates the whole-tree counter, but the
          # empty path names no scope, so the per-scope pairs would
          # otherwise survive until their TTL — drop them all.
          Arca.Usage.invalidate(internal_actor(current))
        end
      else
        {:error, :not_archived}
      end
    end
  end

  @doc """
  Erase an archived athanor: its blobs AND its rows. Final.

  The one verb that deletes a tenant's rows. `purge_storage/1` above
  reclaims the volume and leaves every row standing, and retention
  (`Cyfr.RetentionScheduler`) skips archived athanors, so after archive
  and purge alone every sealed vault payload, webhook secret, OAuth
  ciphertext, execution, message and log stays in the database and in
  every backup taken afterwards.

  ## What it keeps, and why

  The `athanors` row itself survives as an archived tombstone: an audit
  trail that loses the fact an athanor ever existed cannot answer "what
  happened to it". Everything the tombstone owned is gone.

  ## What it refuses

  A **personal** athanor. `users.personal_athanor_id` is not an
  athanor-scoped column and would still name the tombstone: the unique
  index would then block minting a replacement, and
  `Users.allow/1` would try to reopen a wiped shell. Erasing
  a person is a different act with different consequences —
  `Sanctum.Door`'s deny and `archive/1` are the person-level verbs.

  An athanor that is not archived, for the same reason `purge_storage/1`
  does: archiving is the reviewable step that precedes the irreversible
  one.
  """
  @spec destroy(athanor()) :: {:ok, map()} | {:error, term()}
  def destroy(%{id: _} = athanor) do
    with {:ok, current} <- get(athanor.id),
         :ok <- check_destroyable(current),
         :ok <- Arca.delete_tree(internal_actor(current), []),
         {:ok, counts} <- Arca.TenantTables.delete_all_for(internal_actor(current)) do
      Arca.Usage.invalidate(internal_actor(current))

      Logger.warning(
        "[Sanctum.Tenancy.Athanors] destroyed #{current.id}: " <>
          "#{counts |> Map.values() |> Enum.sum()} rows across #{map_size(counts)} tables"
      )

      {:ok, counts}
    end
  end

  defp check_destroyable(%{status: status}) when status != "archived",
    do: {:error, :not_archived}

  defp check_destroyable(%{id: id}) do
    if Sanctum.Tenancy.Users.personal_athanor?(id) do
      {:error, :personal_athanor}
    else
      :ok
    end
  end

  # The server's own actor narrowed to this athanor: `system: true` is
  # what lets the purge reach the whole tree, `scope: :athanor` is what
  # keeps it inside this one athanor.
  defp internal_actor(%{id: id}),
    do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

  @doc """
  Reopen an archived athanor, if the server still has room for it
  (`Arca.SecurityTransitions.unarchive_athanor/3`). Its revoked keys stay
  revoked; the reopen raises the athanor's generation, so a context read
  before the archive cannot issue a credential in it afterwards.
  """
  @spec unarchive(athanor()) :: {:ok, athanor()} | {:error, term()}
  def unarchive(%{id: id} = athanor) do
    with {:ok, change} <-
           Arca.SecurityTransitions.unarchive_athanor(server(), id, verify: &reopenable/1) do
      {:ok, committed(athanor, change)}
    end
  end

  # An archived athanor freed its place against the server cap when it
  # closed; taking the place back has to ask for it, or archiving and
  # reopening would be the way past `CYFR_MAX_ATHANORS`. The count runs
  # inside the transition, with the athanor locked and the census lock
  # held (`Arca.AthanorCensus`), so a reopen and a mint at the last place
  # cannot both land.
  defp reopenable(%{athanor: %{status: "archived"}}),
    do: Caps.check_counted(:max_athanors, &count/0)

  defp reopenable(_rows), do: :ok

  @doc "The last failed fill on the row, or nil: `%{step, detail, at}`."
  @spec provisioning_failure(athanor()) ::
          %{step: String.t(), detail: String.t(), at: DateTime.t()} | nil
  def provisioning_failure(%{provisioning_failed_at: %DateTime{} = at} = athanor) do
    case Jason.decode(athanor.provisioning_failure || "") do
      {:ok, %{"step" => step, "detail" => detail}} -> %{step: step, detail: detail, at: at}
      _ -> %{step: "unknown", detail: "", at: at}
    end
  end

  def provisioning_failure(%{}), do: nil

  @spec list_by_ids([String.t()]) :: [athanor()]
  def list_by_ids([]), do: []

  def list_by_ids(ids) when is_list(ids) do
    # Deliberate default: a display batch-read over ids the caller already
    # holds — an outage renders an empty list, it grants or archives nothing.
    rows_or_empty(Arca.Athanors.list_by_ids(server(), ids))
  end

  @doc """
  Every active athanor on the server, oldest first — the roster server-side
  scans walk (the tincture registry rebuilds itself from it). Uncapped: this
  is the server's own tenant roster, not a user page.
  """
  @spec list_active() :: [athanor()]
  def list_active do
    # Deliberate default: the roster scan's read — a scan that sees [] this
    # cadence walks the full roster on the next one; nothing is deleted on it.
    rows_or_empty(Arca.Athanors.list_active(server()))
  end

  @doc """
  The athanors a person works in: their own, when it is active, else none.
  """
  @spec list_for_user(String.t()) :: [athanor()]
  def list_for_user(user_id) when is_binary(user_id) do
    # Deliberate default: an outage shows none; entering one still resolves
    # membership strictly.
    case get_by_owner(user_id) do
      {:ok, %{status: "active"} = athanor} -> [athanor]
      _ -> []
    end
  end

  @doc "Whether the athanor exists and is active."
  @spec active?(String.t() | nil) :: boolean()
  def active?(id) when is_binary(id) and id != "" do
    case get(id) do
      {:ok, %{status: "active"}} -> true
      _ -> false
    end
  end

  def active?(_), do: false

  @doc """
  How many athanors were minted after `since` — the mint-rate cap's
  measure. Strict: a
  count the store cannot answer is `{:error, :database_error}`, never a
  zero the cap would admit past its ceiling.
  """
  @spec count_created_since(DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_created_since(%DateTime{} = since),
    do: Arca.Athanors.count_created_since(server(), since)

  @doc """
  How many active athanors this server holds — an archived one frees its
  place. Strict like `count_created_since/1`: the caps consult this, and
  an unanswerable count must refuse, not read as an empty server.
  """
  @spec count() :: {:ok, non_neg_integer()} | {:error, :database_error}
  def count, do: Arca.Athanors.count_active(server())

  @doc "The athanor's settings document (JSON on the row), as a map."
  @spec settings(athanor()) :: map()
  def settings(%{settings: nil}), do: %{}

  def settings(%{settings: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc """
  Merge `patch` into the athanor's settings document, one level deep: a map
  under a key merges into the map already there (so an `"approvals"` patch
  naming one value leaves the others alone), a `nil` deletes the key,
  anything else replaces. Retention settings are not here: they are the
  storage layer's own rows (`Arca.RetentionSettings`).
  Every member's open views hear of the change on the athanor's notify
  topic.
  """
  @spec put_settings(athanor(), map()) :: {:ok, athanor()} | {:error, term()}
  def put_settings(%{id: _} = athanor, patch) when is_map(patch) do
    put_settings_cas(athanor, patch, 3)
  end

  defp put_settings_cas(_athanor, _patch, 0), do: {:error, :settings_conflict}

  defp put_settings_cas(%{id: _} = athanor, patch, attempts) do
    # Merge against the current row with compare-and-set to avoid lost updates.
    # If the read fails, fall back to the caller's copy.
    current =
      case get(athanor.id) do
        {:ok, fresh} -> fresh
        _ -> athanor
      end

    merged = deep_merge(settings(current), patch)

    case Arca.Athanors.put_settings(
           in_athanor(current.id),
           current.settings,
           Jason.encode!(merged),
           DateTime.utc_now()
         ) do
      :ok ->
        with {:ok, updated} <- get(current.id) do
          Sanctum.Notify.broadcast(updated.id, :athanor_changed, %{name: updated.name})
          {:ok, updated}
        end

      :stale ->
        put_settings_cas(athanor, patch, attempts - 1)

      {:error, _} = error ->
        error
    end
  end

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

  # The tenancy fabric reads as the server: which athanor a caller works
  # in is what these reads decide, so they cannot be filtered by one.
  defp server, do: Prima.Actor.system()

  # The server narrowed to one athanor — the actor a write that must land
  # in exactly that athanor, and nowhere else, runs as.
  defp in_athanor(id), do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

  defp rows_or_empty({:ok, rows}), do: rows
  defp rows_or_empty({:error, _}), do: []

  defp status_gate({:ok, %{status: "active"} = athanor}, _opts), do: {:ok, athanor}

  defp status_gate({:ok, %{id: _} = athanor}, opts) do
    if Keyword.get(opts, :include_archived, false),
      do: {:ok, athanor},
      else: {:error, :not_found}
  end

  defp status_gate(_, _opts), do: {:error, :not_found}

  defp validate_name(name) when byte_size(name) in 1..80, do: :ok
  defp validate_name(_), do: {:error, :invalid_name}

  @doc """
  A free slug for a person's own athanor: `hint` (their cyfr.run namespace,
  when they have one) if it is valid and free, else one derived from
  `name` with a numeric suffix. A person's athanor is minted at admission,
  before any namespace exists, so the slug is this server's — an address,
  not an identity — and a hint another person's athanor already holds is
  no refusal, it just is not the address.
  """
  @spec person_slug(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, term()}
  def person_slug(hint, name) do
    if is_binary(hint) and Sanctum.Slug.valid?(hint) and slug_free?(hint),
      do: {:ok, hint},
      else: derived_slug(name)
  end

  @doc """
  The candidates for a person athanor's slug, in order of preference:
  `hint` when it is a valid slug, then those derived from `name` with a
  numeric suffix. The mint takes the first one free in its own
  transaction (`create_personal/2`).
  """
  @spec person_slugs(String.t() | nil, String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def person_slugs(hint, name) do
    case Sanctum.Slug.from_name(name) do
      nil ->
        {:error, :invalid_name}

      base ->
        hinted = if is_binary(hint) and Sanctum.Slug.valid?(hint), do: [hint], else: []
        {:ok, hinted ++ derived_candidates(base)}
    end
  end

  defp derived_slug(name) do
    case Sanctum.Slug.from_name(name) do
      nil ->
        {:error, :invalid_name}

      base ->
        case Enum.find(derived_candidates(base), &slug_free?/1) do
          nil -> {:error, :slug_taken_or_invalid}
          slug -> {:ok, slug}
        end
    end
  end

  defp derived_candidates(base) do
    stem = suffixable(base)
    [base | Enum.map(2..50, &"#{stem}-#{&1}")]
  end

  # The stem a numeric suffix is appended to: truncated to leave room, and
  # with any trailing hyphen removed. Cutting a slug at a fixed width lands
  # on a hyphen often enough, and `"...-" <> "-2"` is a double hyphen —
  # which the slug grammar (single hyphens only) then rejects, so the mint
  # fails with a format error rather than taking the next free name.
  defp suffixable(base), do: base |> String.slice(0, 36) |> String.trim_trailing("-")

  defp slug_free?(slug), do: match?({:error, :not_found}, get_by_slug(slug))

  @doc """
  Whether `value` is an athanor id (`"ath_..."`) rather than a route slug.
  Discriminating by prefix is sound: the slug grammar (`Sanctum.Slug` /
  `Prima.ComponentRef.personal_slug_regex/0`) admits only lowercase
  alphanumerics and hyphens — a slug can never contain `"_"`.
  """
  @spec athanor_id?(term()) :: boolean()
  def athanor_id?(value), do: is_binary(value) and String.starts_with?(value, "ath_")
end
