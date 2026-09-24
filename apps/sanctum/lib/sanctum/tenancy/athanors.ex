# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Athanors do
  @moduledoc """
  Athanor rows: create, find, rename, archive.

  An athanor is the unit everything is owned by — a person's or a group's.
  Rows are created here (a person's on first authorized sign-in, a group's
  when a member creates it) and archived, never deleted. Filling an athanor with components and consents is the caller's
  job (`Sanctum.Provisioning`), not this module's: a row is a name,
  provisioning is what fills it.

  A person's athanor is archived only by their denial
  (`Sanctum.Tenancy.Users.deny/1`) or by `archive/2` with `force: true`; a
  group is archived by its members or by its last member leaving.

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

  @slug_attempts 3

  @doc """
  Insert an athanor. `attrs` must carry `:kind`, `:name`, `:slug` and
  `:created_by`; a person athanor also `:owner_user_id`. `:id` defaults to a
  fresh `ath_` id. The server-wide cap on athanors applies.
  """
  @spec create(map()) :: {:ok, athanor()} | {:error, term()}
  def create(attrs) do
    with :ok <- Caps.check_counted(:max_athanors, &count/0) do
      Arca.Athanors.insert(server(), Map.new(attrs))
    end
  end

  @doc """
  Mint an athanor for a person the server admits as its operator, exempt
  from the server caps.

  `CYFR_MINT_PER_HOUR` bounds how fast strangers arrive and
  `CYFR_MAX_ATHANORS` how many estates the server holds; an operator named
  in `CYFR_PLATFORM_ADMIN_EMAILS` is neither a stranger nor optional — a
  server at capacity must still admit the person who can act on it. Every
  other mint goes through `create/1` and is capped.
  """
  @spec create_for_operator(map()) :: {:ok, athanor()} | {:error, term()}
  def create_for_operator(attrs) when is_map(attrs),
    do: Arca.Athanors.insert(server(), Map.new(attrs))

  @doc """
  Mint a group athanor for `creator_user_id`: the row, its slug (from the
  name, or `:slug`), and the creator's membership — nobody else is added.
  The per-person cap on groups applies. All of it lands or none does.
  """
  @spec create_group(String.t(), String.t(), keyword()) ::
          {:ok, athanor()} | {:error, term()}
  def create_group(creator_user_id, name, opts \\ [])
      when is_binary(creator_user_id) and is_binary(name) do
    name = String.trim(name)

    with :ok <- validate_name(name),
         {:ok, athanor} <-
           mint_group(creator_user_id, name, Keyword.get(opts, :slug), @slug_attempts) do
      Sanctum.Tenancy.Members.broadcast_change(creator_user_id, athanor.id, :joined)
      {:ok, athanor}
    end
  end

  # The cap, the slug, the row and the creator's seat in one transaction,
  # serialized per creator by a write to their user row: two creations by
  # one person cannot both pass the cap, and a seat that fails leaves no
  # group. A derived slug another creation took first is derived again.
  defp mint_group(creator_user_id, name, explicit_slug, attempts) do
    result =
      Arca.Athanors.mint(server(),
        hold: [creator_user_id],
        guards: [
          fn ->
            Caps.check_counted(:max_groups_per_person, fn ->
              Arca.Athanors.count_groups_created_by(server(), creator_user_id)
            end)
          end,
          fn -> Caps.check_counted(:max_athanors, &count/0) end
        ],
        attrs: fn ->
          with {:ok, slug} <- resolve_slug(explicit_slug, name) do
            {:ok, %{kind: "group", name: name, slug: slug, created_by: creator_user_id}}
          end
        end,
        seats: fn athanor ->
          with {:ok, _} <-
                 Sanctum.Tenancy.Members.create(%{
                   user_id: creator_user_id,
                   scope: "athanor",
                   athanor_id: athanor.id,
                   added_by: creator_user_id
                 }) do
            :ok
          end
        end
      )

    case result do
      {:error, :slug_taken} when is_nil(explicit_slug) and attempts > 1 ->
        mint_group(creator_user_id, name, nil, attempts - 1)

      result ->
        result
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
  racer reads the winner rather than reporting a conflict. Two people
  double-clicking each other's names get one tape.

  The per-person cap on pairs applies to a mint, and to both people: a
  pair is minted for two, so either one at `CYFR_MAX_PAIRS_PER_PERSON`
  refuses it with `{:error, {:limit_reached, :max_pairs_per_person, cap}}`.
  Finding the existing pair is not a mint and is never capped.

  The row only — it is deliberately **not** provisioned here. A pair that
  owns nothing needs no registry pull, no component scan and no consent
  bootstrap to exist; `Sanctum.Provisioning.start_provisioning/1` fills it
  at first need instead, so clicking a name opens a chat immediately
  instead of waiting on the network.
  """
  @spec create_pair(String.t(), String.t()) :: {:ok, athanor()} | {:error, term()}
  def create_pair(user_a, user_b)
      when is_binary(user_a) and is_binary(user_b) and user_a != user_b do
    key = pair_key(user_a, user_b)

    case get_by_pair_key(key) do
      {:ok, athanor} ->
        {:ok, athanor}

      {:error, :not_found} ->
        mint_pair(key, user_a, user_b)

      {:error, _} = err ->
        err
    end
  end

  def create_pair(_, _), do: {:error, :invalid_pair}

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
  @spec get_by_pair_key(String.t()) :: {:ok, athanor()} | {:error, :not_found | :database_error}
  def get_by_pair_key(key) when is_binary(key),
    do: Arca.Athanors.get_by_pair_key(server(), key)

  # A pair is minted for two, so the cap is asked for both, inside the mint
  # with both people's rows held (in one order, so two mints cannot
  # deadlock). Without it one member of a large room could mint an estate
  # per co-member from the wire — a DM asks nobody else's consent — and
  # spend `CYFR_MAX_ATHANORS` for everyone.
  defp mint_pair(key, user_a, user_b) do
    name = pair_name(user_a, user_b)

    result =
      Arca.Athanors.mint(server(),
        hold: [user_a, user_b],
        guards:
          Enum.map([user_a, user_b], fn user_id ->
            fn ->
              Caps.check_counted(:max_pairs_per_person, fn ->
                Arca.Athanors.count_pairs_of(server(), user_id)
              end)
            end
          end) ++ [fn -> Caps.check_counted(:max_athanors, &count/0) end],
        attrs: fn ->
          with {:ok, slug} <- resolve_slug(nil, name) do
            {:ok,
             %{
               kind: "group",
               roster: "frozen",
               pair_key: key,
               name: name,
               slug: slug,
               created_by: user_a
             }}
          end
        end,
        seats: fn athanor ->
          Enum.reduce_while([user_a, user_b], :ok, fn user_id, :ok ->
            case seat(athanor, user_id) do
              {:ok, _} -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end
          end)
        end
      )

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
  @spec pair_label(athanor(), String.t() | nil) :: String.t()
  def pair_label(%{roster: "frozen", id: id, name: name}, user_id)
      when is_binary(user_id) do
    with {:ok, rows} <- Sanctum.Tenancy.Members.list_by_athanor(id),
         %{user_id: other} <- Enum.find(rows, &other_seat?(&1, user_id)) do
      Sanctum.Tenancy.Users.display_name(other)
    else
      _ -> name
    end
  end

  def pair_label(%{name: name}, _user_id), do: name

  defp other_seat?(%{user_id: other, status: "active"}, user_id) when is_binary(other),
    do: other != user_id

  defp other_seat?(_row, _user_id), do: false

  @spec get(String.t()) :: {:ok, athanor()} | {:error, :not_found | :database_error}
  def get(id) when is_binary(id), do: Arca.Athanors.get(server(), id)

  @doc """
  A person's own athanor, by its owner. At most one exists per person
  (a partial unique index on `owner_user_id` where `kind = 'person'`).
  """
  @spec get_by_owner(String.t()) :: {:ok, athanor()} | {:error, :not_found | term()}
  def get_by_owner(user_id) when is_binary(user_id),
    do: Arca.Athanors.get_by_owner(server(), user_id)

  @doc "Find an athanor by kind and slug."
  @spec get_by_slug(String.t(), String.t()) ::
          {:ok, athanor()} | {:error, :not_found | :database_error}
  def get_by_slug(kind, slug) when is_binary(kind) and is_binary(slug),
    do: Arca.Athanors.get_by_slug(server(), kind, slug)

  @doc """
  Resolve a route segment: `@<namespace>` names a person's athanor, a bare
  slug a group's. Only active athanors resolve, unless the caller passes
  `include_archived: true` (a read that must still see an archived row —
  `athanor.get`, `unarchive`).
  """
  @spec by_route_slug(String.t(), keyword()) :: {:ok, athanor()} | {:error, :not_found}
  def by_route_slug(segment, opts \\ [])

  def by_route_slug("@" <> namespace, opts) when namespace != "" do
    get_by_slug("person", namespace) |> status_gate(opts)
  end

  def by_route_slug(slug, opts) when is_binary(slug) and slug != "" do
    get_by_slug("group", slug) |> status_gate(opts)
  end

  def by_route_slug(_, _opts), do: {:error, :not_found}

  @doc "The route segment for an athanor: `@<slug>` for a person, the slug for a group."
  @spec route_slug(athanor()) :: String.t()
  def route_slug(%{kind: "person", slug: slug}), do: "@" <> slug
  def route_slug(%{slug: slug}), do: slug

  @spec update(athanor(), map()) :: {:ok, athanor()} | {:error, term()}
  def update(%{id: id}, attrs), do: Arca.Athanors.update(in_athanor(id), Map.new(attrs))

  @doc "Rename an athanor. The slug stays: it is an address."
  @spec rename(athanor(), String.t()) :: {:ok, athanor()} | {:error, term()}
  def rename(%{id: _} = athanor, name) when is_binary(name) do
    name = String.trim(name)

    with :ok <- validate_name(name) do
      update(athanor, %{name: name})
    end
  end

  @doc """
  Mark an athanor archived. Nothing is deleted; every ingress gate refuses
  it, its API keys are revoked in the same transaction
  (`Arca.SecurityTransitions.archive_athanor/3`), whatever is running in
  it is cancelled, the established-context memo of every member is dropped
  and its members are told — the same on every path that archives (a
  member's `athanor.archive`, the last member leaving, a person being
  denied), so no path leaves work running in a furnace nobody may enter.
  The announcements follow the commit and are made from what it returned.

  A person's athanor refuses unless `force: true`. An athanor already
  archived is archived again: its keys are revoked and checked again and
  its archival announced again, so a retry reaches whatever a lost
  announcement did not.
  """
  @spec archive(athanor(), keyword()) :: {:ok, athanor()} | {:error, term()}
  def archive(%{id: id} = athanor, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    verify = fn
      %{athanor: %{kind: "person", status: "active"}} when not force? ->
        {:error, :person_athanor_cannot_be_archived}

      _rows ->
        :ok
    end

    with {:ok, change} <- Arca.SecurityTransitions.archive_athanor(server(), id, verify: verify) do
      announce_archived([id], change)
      {:ok, committed(athanor, change)}
    end
  end

  @doc """
  Announce estates a committed transition archived, from the data it
  returned: each member's established-context memo is dropped, before
  this returns — the memo caches an AUTHORIZATION decision, so an archive
  that only flipped the status would leave every member working inside
  the shut furnace until their memo aged out — and the archival is
  announced, which is what stops in-flight work
  (`Crucible.ArchiveWatch`) and the processes serving the estate
  from outside any tenant topic; the status gates already refuse new work
  either way. Estates the transition actually moved tell their members'
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
        ctx = Sanctum.internal_context(athanor_id: current.id, scope: :athanor)

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

  The one verb that actually deletes a tenant's data.
  `purge_storage/1` above reclaims the volume and leaves every row
  standing; retention (`Cyfr.RetentionScheduler`) skips archived athanors
  because purging is supposed to be the reclaim. So nothing deleted rows
  at all, and after archive + purge every sealed vault payload, webhook
  secret, OAuth ciphertext, execution, message and log stayed in the
  database and in every backup taken afterwards.

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
  # keeps it inside this one estate.
  defp internal_actor(%{id: id}),
    do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

  @doc """
  Reopen an archived athanor, if the server still has room for it
  (`Arca.SecurityTransitions.unarchive_athanor/3`). Its revoked keys stay
  revoked; the reopen raises the estate's generation, so a context read
  before the archive cannot issue a credential in it afterwards. An ended
  DM never reopens: a frozen estate is archived the moment either person
  leaves, so its husk holds one member, and reopening it would seat that
  person alone in a second You. Clicking the name again mints a new pair
  instead.
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
  # inside the transition, with the estate locked.
  defp reopenable(%{athanor: %{roster: "frozen"}}), do: {:error, :frozen_is_final}

  defp reopenable(%{athanor: %{status: "archived"}}),
    do: Caps.check_counted(:max_athanors, &count/0)

  defp reopenable(_rows), do: :ok

  @doc """
  Record that provisioning (seed + consents) completed — and forget any
  earlier failure recorded on the row.
  """
  @spec mark_provisioned(athanor()) :: {:ok, athanor()} | {:error, term()}
  def mark_provisioned(%{id: _} = athanor) do
    now = DateTime.utc_now()

    set_provisioning(athanor,
      provisioned_at: now,
      provisioning_failed_at: nil,
      provisioning_failure: nil,
      updated_at: now
    )
  end

  @doc """
  Record that a fill failed: when, at which `step`, and `detail`. The
  record is the server's own — no settings patch writes or clears it — and
  a completed fill clears it. Members' open views hear of the change.
  """
  @spec record_provisioning_failure(athanor(), atom() | String.t(), String.t()) ::
          {:ok, athanor()} | {:error, term()}
  def record_provisioning_failure(%{id: _} = athanor, step, detail) when is_binary(detail) do
    now = DateTime.utc_now()

    set_provisioning(athanor,
      provisioning_failed_at: now,
      provisioning_failure: Jason.encode!(%{"step" => to_string(step), "detail" => detail}),
      updated_at: now
    )
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

  defp set_provisioning(%{id: id}, set) do
    with :ok <- Arca.Athanors.set(in_athanor(id), set),
         {:ok, updated} <- get(id) do
      Sanctum.Notify.broadcast(id, :athanor_changed, %{name: updated.name})
      {:ok, updated}
    end
  end

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
  The active athanors a person may work in: their own, then every group an
  active membership grants, oldest first. Uncapped — a person's memberships
  are few, and a truncated list would hide a chat.
  """
  @spec list_for_user(String.t()) :: [athanor()]
  def list_for_user(user_id) when is_binary(user_id) do
    # Deliberate default: a person's sidebar roster — an outage shows fewer
    # rooms, never more; entering one still resolves membership strictly.
    rows_or_empty(Arca.Athanors.list_for_user(server(), user_id))
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
  How many person athanors were minted after `since` — the mint-rate cap's
  measure; groups people create are bounded by their own cap. Strict: a
  count the store cannot answer is `{:error, :database_error}`, never a
  zero the cap would admit past its ceiling.
  """
  @spec count_created_since(DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_created_since(%DateTime{} = since),
    do: Arca.Athanors.count_people_created_since(server(), since)

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

  @doc """
  Whether `value` is an athanor id (`"ath_..."`) rather than a route slug.
  Discriminating by prefix is sound: the slug grammar (`Sanctum.Slug` /
  `Prima.ComponentRef.personal_slug_regex/0`) admits only lowercase
  alphanumerics and hyphens — a slug can never contain `"_"`.
  """
  @spec athanor_id?(term()) :: boolean()
  def athanor_id?(value), do: is_binary(value) and String.starts_with?(value, "ath_")
end
