# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Athanors do
  @moduledoc """
  Athanor rows: create and find.

  An athanor is the unit everything is owned by — one person's. Rows are
  created here, inside the person's admission's transaction
  (`Sanctum.Provisioning.mint_personal/1`), and archived, never deleted.
  Filling an athanor with components and consents is the caller's job
  (`Sanctum.Provisioning`), not this module's: a row is a name,
  provisioning is what fills it.

  An athanor is archived only by its person's denial
  (`Sanctum.Tenancy.Users.deny/1`), and reopened only by their allow.

  ## What is decided here, and what is stored below

  The statements are `Arca.Athanors`'. What stays here is the deciding:
  which cap a mint must pass, what a slug may be, what an unanswerable
  read should read as, and who is told afterwards. Every call names the actor it runs as — the server
  (`Prima.Actor.system/0`) for the fabric reads that choose an athanor,
  and the server narrowed to one athanor for every write that must land
  in exactly that one.
  """

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
  `slugs` no athanor holds, in one
  `Arca.Athanors.mint/2` under the census lock, so two admissions cannot
  take one slug. It counts no cap: the admission counted the server-wide
  cap before the person's row (`personal_place/0`), or is the
  installation's administrator, minted past it.
  """
  @spec create_personal(map(), [String.t()]) :: {:ok, athanor()} | {:error, term()}
  def create_personal(%{owner_user_id: user_id} = attrs, slugs)
      when is_binary(user_id) and is_list(slugs) do
    Arca.Athanors.mint(server(), hold: [user_id], slugs: slugs, attrs: attrs)
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

  @doc """
  Announce athanors a committed denial archived, from the data it
  returned: its person's established-context memo is dropped, before
  this returns — the memo caches an AUTHORIZATION decision, so an archive
  that only flipped the status would leave them working inside
  the shut furnace until their memo aged out — and the archival is
  announced, which is what stops in-flight work
  (`Opus.ArchiveWatch`) and the processes serving the athanor
  from outside any tenant topic; the status gates already refuse new work
  either way. Athanors the transition actually moved tell their person's
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
    # Deliberate default: an outage shows none; entering one still reads
    # its owner strictly.
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
