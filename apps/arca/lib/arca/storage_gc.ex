# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageGC do
  @moduledoc """
  Collection of an athanor's staging areas: the revision
  prefixes `Arca.Overlay`'s write protocol stages under and serves from
  (`Arca.Storage.UnitLocator.revision_prefix/2`).

  Only a prefix no root keeps is ever collected. The pointer's prefix is
  the unit as readers read it and is removed by the unit's drop
  (`Arca.StorageUnits.retire/3` and the overlay's delete path), by
  nothing here.

  ## Roots

  A revision prefix is kept while any of these names it:

    * **the pointer** — the `current_revision` of a committed
      `storage_units` row: the revision readers resolve the row to, for
      as long as the row names it;
    * **a live draft** — the unit's row holds a writer token registered
      within `Arca.StorageUnits.draft_ttl_ms/0` plus the grace, and the
      prefix carries its in-progress marker. The row does not say which
      revision its writer stages, so every marked prefix of the unit is
      kept while the draft lives.

  Every age is judged on the cell's clock (`Arca.ServerMetaStorage.now!/0`),
  read once as a sweep begins, before its snapshot: a draft's
  registration and the commit that left a revision are written from that
  clock (`Arca.StorageUnits`), so a member whose own clock has drifted
  neither keeps a dead draft nor takes a live one. A caller may name the
  instant (`now:`), as the tests do.

  ## Collection order

  `sweep/2` runs `roots/1`, `candidates/3` and `collect/3`:

    1. snapshot the roots;
    2. list every key under each root's staging area;
    3. a prefix is a candidate when the snapshot does not root it, its
       marker is absent or its unit's draft is dead past the lifetime plus
       the grace, and it is older than the grace — counted from when it
       was begun or from the commit that left it, whichever is later;
    4. for one candidate, immediately before its deletion: a draft dead
       past the grace is retired, so its writer can never commit the
       revision; then the pointer, the draft and the commit that replaced
       the revision are read again, and any of them keeps it — a revision
       the pointer left since the snapshot stands through the grace after
       the commit that left it;
    5. its objects are deleted, then its marker, last;
    6. the emptied revision directory is removed where the adapter has
       directories.

  After step 4 no commit can name the revision: a commit needs the draft
  token its writer registered, and the row no longer holds it. A crash at
  any step leaves a prefix a later sweep collects, or nothing: the marker
  outlives the objects, and it dates what is left. The previous
  revision's prefix becomes a candidate at the next commit and is aged
  from that commit, so it is collected once the grace has passed since
  the pointer left it: what an athanor holds of a unit is its current
  revision and, inside the grace, the one before it. A reader that
  resolved the row before a commit reads the revision it resolved through
  that grace, and no longer: the grace is the whole of what a reader
  across a commit is given. A unit's removal deletes the retired
  revision's prefix at once (`Arca.Overlay`'s delete path), and a reader
  across it reads `{:error, :not_found}` from then on, as at any unit no
  committed row names.

  ## Tenancy

  Every function takes the `Prima.Actor` first, refuses one with no
  athanor as `{:error, :no_athanor}` before any query or listing, and
  lists and deletes only inside that athanor's tree. The walk across
  athanors belongs to the caller that owns the roster
  (`Cyfr.RetentionScheduler`).
  """

  import Ecto.Query, only: [from: 2]
  import Arca.QueryHelpers, only: [where_athanor: 2]

  alias Arca.Schemas.{StorageCommit, StorageUnit}
  alias Arca.Storage.UnitLocator
  alias Arca.StorageUnits

  @default_grace_ms :timer.hours(24)
  @default_limit 200

  @type refusal :: {:error, :no_athanor | :unavailable}
  @type revision_key :: {root :: String.t(), unit_key :: String.t(), revision :: String.t()}

  @typedoc """
  The roots of one athanor, as `roots/1` read them, and when each
  revision a later commit replaced stopped being the pointer.
  """
  @type roots :: %{
          current: MapSet.t(revision_key()),
          drafts: %{{String.t(), String.t()} => DateTime.t()},
          superseded: %{revision_key() => DateTime.t()}
        }

  @typedoc "One revision prefix the snapshot does not root."
  @type candidate :: %{
          root: String.t(),
          unit_key: String.t(),
          unit: Arca.Storage.path(),
          revision: String.t(),
          prefix: Arca.Storage.path(),
          marker?: boolean()
        }

  @typedoc """
  What a sweep did. `kept` counts the candidates a recheck saved, by
  reason; `unaged` the prefixes that carried no date and were given one;
  and `unrecognized` the keys in a staging area that are no revision's.
  """
  @type report :: %{
          examined: non_neg_integer(),
          collected: non_neg_integer(),
          kept: %{atom() => non_neg_integer()},
          unaged: non_neg_integer(),
          unrecognized: non_neg_integer(),
          errors: [{Arca.Storage.path(), term()}]
        }

  @doc "How long a dead prefix is kept before it is collected, by default."
  @spec default_grace_ms() :: pos_integer()
  def default_grace_ms, do: @default_grace_ms

  # ---------------------------------------------------------------------------
  # Collection
  # ---------------------------------------------------------------------------

  @doc """
  One bounded sweep of the actor's athanor, in the moduledoc's order.

  Options: `grace_ms:` (default a day), `now:` (default the cell's
  clock), `limit:` — how many prefixes one sweep collects,
  oldest first (default #{@default_limit}) — and `dry_run: true`, which
  counts what the snapshot would collect and touches nothing.
  """
  @spec sweep(Prima.Actor.t(), keyword()) :: {:ok, report()} | {:error, term()} | refusal()
  def sweep(%Prima.Actor{} = actor, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, athanor} <- tenant(actor),
         {:ok, {now, _grace_ms}} <- clock(opts),
         opts = Keyword.put(opts, :now, now),
         {:ok, roots, listing} <- snapshot(actor),
         {:ok, candidates} <- candidates(actor, roots, Keyword.put(opts, :listing, listing)) do
      limit = Keyword.get(opts, :limit, @default_limit)
      dry_run = Keyword.get(opts, :dry_run, false)

      report =
        %{
          examined: map_size(listing.groups),
          collected: 0,
          kept: %{},
          unaged: 0,
          unrecognized: listing.unrecognized,
          errors: []
        }
        |> collect_each(actor, Enum.take(candidates, limit), opts, dry_run)

      report =
        if dry_run,
          do: report,
          else: date_unaged(report, actor, listing, roots, now)

      :telemetry.execute(
        [:cyfr, :storage_gc, :sweep],
        %{
          examined: report.examined,
          collected: report.collected,
          kept: report.kept |> Map.values() |> Enum.sum(),
          errors: length(report.errors),
          duration_ms: System.monotonic_time(:millisecond) - started
        },
        %{athanor_id: athanor, dry_run: dry_run}
      )

      {:ok, report}
    end
  end

  @doc """
  The roots of the actor's athanor, read now: the committed pointers and
  the units whose draft is held (with when it was registered); with them,
  when each revision a later commit replaced stopped being the pointer,
  which dates its prefix for collection.
  """
  @spec roots(Prima.Actor.t()) :: {:ok, roots()} | {:error, term()} | refusal()
  def roots(%Prima.Actor{} = actor) do
    with {:ok, roots, _listing} <- snapshot(actor), do: {:ok, roots}
  end

  # Step 1 and step 2 off one listing: the rows, then the keys.
  defp snapshot(actor) do
    with {:ok, athanor} <- tenant(actor),
         {:ok, {rows, superseded}} <-
           rescuing_db("roots", fn -> {:ok, {rooted_rows(athanor), superseded_at(athanor)}} end),
         {:ok, listing} <- listing(actor) do
      {:ok,
       %{
         current:
           for(
             %StorageUnit{state: "committed", current_revision: revision} = row <- rows,
             is_binary(revision),
             into: MapSet.new(),
             do: {row.root, row.unit_key, revision}
           ),
         drafts:
           for(
             %StorageUnit{draft_writer_token: token} = row <- rows,
             is_binary(token),
             into: %{},
             do: {{row.root, row.unit_key}, row.updated_at}
           ),
         superseded: superseded
       }, listing}
    end
  end

  @doc """
  The prefixes `roots` does not keep, oldest first: not the pointer's,
  the marker absent or the unit's draft dead past the lifetime plus the
  grace, and older than the grace. A prefix that carries no date is not
  a candidate.
  """
  @spec candidates(Prima.Actor.t(), roots(), keyword()) ::
          {:ok, [candidate()]} | {:error, term()} | refusal()
  def candidates(%Prima.Actor{} = actor, %{current: _, drafts: _} = roots, opts \\ []) do
    with {:ok, _athanor} <- tenant(actor),
         {:ok, {now, grace_ms}} <- clock(opts),
         {:ok, listing} <- given_listing(actor, opts) do
      inner = internal_actor(actor)

      found =
        for {{root, key, revision} = id, keys} <- listing.groups,
            not MapSet.member?(roots.current, id),
            unit = UnitLocator.unit_path(root, key),
            {:ok, marker?} = {:ok, marker?(keys)},
            not (marker? and live_draft?(Map.get(roots.drafts, {root, key}), now, grace_ms)),
            older_than?(aged_from(inner, unit, revision, marker?, roots), now, grace_ms) do
          %{
            root: root,
            unit_key: key,
            unit: unit,
            revision: revision,
            prefix: UnitLocator.revision_prefix(unit, revision),
            marker?: marker?
          }
        end

      {:ok, Enum.sort_by(found, & &1.revision)}
    end
  end

  @doc """
  Collect one candidate, or keep it: the moduledoc's steps 4 to 6. The
  pointer, the draft and the commit that replaced the revision are read
  again here, whatever the snapshot said. Answers `:collected`, or
  `{:kept, reason}` with `:committed`, `:live_draft` or `:replaced` — the
  pointer left the revision inside the grace.
  """
  @spec collect(Prima.Actor.t(), candidate(), keyword()) ::
          :collected
          | {:kept, :committed | :live_draft | :replaced}
          | {:error, term()}
          | refusal()
  def collect(%Prima.Actor{} = actor, %{unit: unit, revision: revision} = candidate, opts \\ [])
      when is_binary(revision) do
    with {:ok, athanor} <- tenant(actor),
         {:ok, {now, grace_ms}} <- clock(opts) do
      inner = internal_actor(actor)

      with :ok <- retire_dead_draft(actor, athanor, candidate, now, grace_ms),
           :ok <- unrooted(athanor, inner, candidate, now, grace_ms),
           :ok <- outside_replacement_grace(athanor, candidate, now, grace_ms) do
        delete_prefix(inner, unit, revision)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The sweep's passes
  # ---------------------------------------------------------------------------

  defp collect_each(report, _actor, candidates, _opts, true),
    do: %{report | collected: length(candidates)}

  defp collect_each(report, actor, candidates, opts, false) do
    Enum.reduce(candidates, report, fn candidate, acc ->
      case collect(actor, candidate, opts) do
        :collected -> %{acc | collected: acc.collected + 1}
        {:kept, reason} -> %{acc | kept: Map.update(acc.kept, reason, 1, &(&1 + 1))}
        {:error, reason} -> %{acc | errors: [{candidate.prefix, reason} | acc.errors]}
      end
    end)
  end

  # A prefix with neither a marker nor a dated revision name says nothing
  # of its age. It is given a marker now, dated on the sweep's clock, and
  # a later sweep reads it.
  defp date_unaged(report, actor, listing, roots, now) do
    inner = internal_actor(actor)
    body = Jason.encode!(%{"observed_at" => DateTime.to_iso8601(now)})

    undated =
      for {{root, key, revision} = id, keys} <- listing.groups,
          not MapSet.member?(roots.current, id),
          not marker?(keys),
          revision_time(revision) == :error,
          do: UnitLocator.marker_path(UnitLocator.unit_path(root, key), revision)

    Enum.each(undated, fn path ->
      internally(fn -> Arca.put(inner, path, body, cap: :exempt) end)
    end)

    %{report | unaged: length(undated)}
  end

  # ---------------------------------------------------------------------------
  # One candidate
  # ---------------------------------------------------------------------------

  # Step 4's first half. A token older than the lifetime plus the grace is
  # a writer that died or stalled; giving its draft back means the revision
  # it staged can never be committed. A draft registered since is left.
  defp retire_dead_draft(actor, athanor, %{root: root, unit_key: key}, now, grace_ms) do
    with {:ok, row} <-
           rescuing_db("retire_dead_draft", fn -> {:ok, fetch(athanor, root, key)} end) do
      case row do
        %StorageUnit{draft_writer_token: token, updated_at: registered} when is_binary(token) ->
          if live_draft?(registered, now, grace_ms),
            do: :ok,
            else: StorageUnits.abandon_draft(actor, row, token)

        _no_row_or_no_draft ->
          :ok
      end
    end
  end

  # Step 4's second half: the roots of this one prefix, read now.
  defp unrooted(athanor, inner, %{root: root, unit_key: key} = candidate, now, grace_ms) do
    with {:ok, row} <- rescuing_db("unrooted", fn -> {:ok, fetch(athanor, root, key)} end),
         :ok <- not_the_pointer(row, candidate.revision) do
      no_live_draft(inner, row, candidate, now, grace_ms)
    end
  end

  defp not_the_pointer(%StorageUnit{state: "committed", current_revision: revision}, revision),
    do: {:kept, :committed}

  defp not_the_pointer(_row, _revision), do: :ok

  # Step 4's last look, read after the draft is retired so no commit can
  # name the candidate afterwards: a candidate the pointer has left since
  # the snapshot is aged from the commit that replaced it, as the
  # snapshot aged it — a reader that resolved the row before that commit
  # reads the revision through the grace.
  defp outside_replacement_grace(
         athanor,
         %{root: root, unit_key: key, revision: revision},
         now,
         grace_ms
       ) do
    rescuing_db("replacement_grace", fn ->
      replaced_at =
        from(c in where_athanor(StorageCommit, athanor),
          join: u in StorageUnit,
          on: u.id == c.storage_unit_id and u.athanor_id == ^athanor,
          where: u.root == ^root and u.unit_key == ^key and c.prior_revision == ^revision,
          select: max(c.committed_at)
        )
        |> Arca.Repo.one()

      if is_nil(replaced_at) or DateTime.diff(now, replaced_at, :millisecond) > grace_ms,
        do: :ok,
        else: {:kept, :replaced}
    end)
  end

  # The marker is looked for again: a prefix listed without one may be a
  # writer's that had not created it yet on a store that lists late.
  defp no_live_draft(
         inner,
         %StorageUnit{draft_writer_token: token, updated_at: registered},
         candidate,
         now,
         grace_ms
       )
       when is_binary(token) do
    marked? = Arca.exists?(inner, UnitLocator.marker_path(candidate.unit, candidate.revision))

    if marked? and live_draft?(registered, now, grace_ms), do: {:kept, :live_draft}, else: :ok
  end

  defp no_live_draft(_inner, _row, _candidate, _now, _grace_ms), do: :ok

  # Steps 5 and 6. The marker outlives every object, so what a crash leaves
  # is still a dated prefix.
  defp delete_prefix(inner, unit, revision) do
    prefix = UnitLocator.revision_prefix(unit, revision)
    marker = UnitLocator.marker_path(unit, revision)

    with {:ok, keys} <- list_under(inner, prefix),
         :ok <- remove_each(inner, Enum.reject(keys, &(&1 == marker))),
         :ok <- remove(inner, marker),
         :ok <- internally(fn -> Arca.delete_tree(inner, prefix) end) do
      :collected
    end
  end

  defp remove_each(inner, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case remove(inner, key) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp remove(inner, path) do
    case internally(fn -> Arca.delete(inner, path) end) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # The staging listing
  # ---------------------------------------------------------------------------

  defp given_listing(actor, opts) do
    case Keyword.fetch(opts, :listing) do
      {:ok, listing} -> {:ok, listing}
      :error -> listing(actor)
    end
  end

  # Every key under the athanor's staging areas, sorted into revision
  # prefixes and the rest. One listing per overlaid root, inside the
  # actor's athanor.
  defp listing(actor) do
    inner = internal_actor(actor)

    Enum.reduce_while(
      Arca.Storage.overlay_roots(),
      {:ok, %{groups: %{}, unrecognized: 0}},
      fn root, {:ok, acc} ->
        case list_under(inner, staging_area(root)) do
          {:ok, keys} -> {:cont, {:ok, Enum.reduce(keys, acc, &sort_key(root, &1, &2))}}
          {:error, _} = error -> {:halt, error}
        end
      end
    )
  end

  defp sort_key(root, [root, _staging | rest] = path, acc) do
    case staged_at(root, rest) do
      {:ok, key, revision, _object} ->
        %{acc | groups: Map.update(acc.groups, {root, key, revision}, [path], &[path | &1])}

      :error ->
        %{acc | unrecognized: acc.unrecognized + 1}
    end
  end

  # A staged key is its unit's path, the revision, then the object. The
  # unit is the root's grammar's answer, so no depth is assumed here.
  defp staged_at(root, rest) do
    case Arca.Storage.locate([root | rest]) do
      {:file, unit} -> split_at_unit(unit, rest)
      {:dir, unit, _sentinel} -> split_at_unit(unit, rest)
      _above_or_outside -> :error
    end
  end

  defp split_at_unit([_root | unit_rest] = unit, rest) do
    case Enum.drop(rest, length(unit_rest)) do
      [revision, _ | _] = tail -> {:ok, elem(UnitLocator.unit_key(unit), 1), revision, tl(tail)}
      _no_object_under_a_revision -> :error
    end
  end

  defp staging_area(root), do: UnitLocator.staging_area(root)

  # Every adapter answers the prefix listing (`c:Arca.Storage.list_prefix/2`),
  # so a staging area is read as keys, never walked as a tree.
  defp list_under(inner, prefix), do: Arca.Storage.list_prefix(inner, prefix)

  defp marker?(keys), do: Enum.any?(keys, &marker_key?/1)
  defp marker_key?(key), do: List.last(key) == UnitLocator.marker_name()

  # ---------------------------------------------------------------------------
  # Ages
  # ---------------------------------------------------------------------------

  # The sweep's clock and grace: the cell's clock
  # (`Arca.ServerMetaStorage.now!/0`), the one every lease is written
  # from, unless the caller names the instant. A store that cannot answer
  # is `{:error, :unavailable}`.
  defp clock(opts) do
    rescuing_db("clock", fn ->
      {:ok,
       {Keyword.get_lazy(opts, :now, &Arca.ServerMetaStorage.now!/0),
        Keyword.get(opts, :grace_ms, @default_grace_ms)}}
    end)
  end

  defp live_draft?(nil, _now, _grace_ms), do: false

  defp live_draft?(%DateTime{} = registered, now, grace_ms) do
    DateTime.diff(now, registered, :millisecond) <= StorageUnits.draft_ttl_ms() + grace_ms
  end

  defp older_than?({:ok, %DateTime{} = at}, now, grace_ms),
    do: DateTime.diff(now, at, :millisecond) > grace_ms

  defp older_than?(:error, _now, _grace_ms), do: false

  # When a prefix's age counts from: when it was begun, or, for a revision
  # a later commit replaced, that commit — whichever is later — so the
  # revision a reader resolved just before a commit stands through the
  # grace after it, however long it had been the pointer's.
  defp aged_from(inner, unit, revision, marker?, roots) do
    {root, key} = UnitLocator.unit_key(unit)
    left = Map.fetch(Map.get(roots, :superseded, %{}), {root, key, revision})

    case {started_at(inner, unit, revision, marker?), left} do
      {{:ok, began}, {:ok, at}} -> {:ok, Enum.max([began, at], DateTime)}
      {:error, {:ok, at}} -> {:ok, at}
      {began, :error} -> began
    end
  end

  # When a prefix was begun: its marker says, and a revision name
  # (`Arca.StorageUnits.new_revision/0`) carries its own time.
  defp started_at(inner, unit, revision, true) do
    with {:ok, body} <- Arca.get(inner, UnitLocator.marker_path(unit, revision)),
         {:ok, %{} = marker} <- Jason.decode(body),
         stamp when is_binary(stamp) <- marker["started_at"] || marker["observed_at"],
         {:ok, at, _offset} <- DateTime.from_iso8601(stamp) do
      {:ok, at}
    else
      _unreadable -> revision_time(revision)
    end
  end

  defp started_at(_inner, _unit, revision, false), do: revision_time(revision)

  # The millisecond timestamp a UUIDv7 opens with.
  defp revision_time(
         "rev_" <> <<high::binary-size(8), "-", low::binary-size(4), "-7", _::binary>>
       ) do
    case Integer.parse(high <> low, 16) do
      {ms, ""} -> DateTime.from_unix(ms, :millisecond) |> ok_or_error()
      _not_hex -> :error
    end
  end

  defp revision_time(_revision), do: :error

  defp ok_or_error({:ok, %DateTime{}} = ok), do: ok
  defp ok_or_error(_), do: :error

  # ---------------------------------------------------------------------------
  # Rows
  # ---------------------------------------------------------------------------

  defp fetch(athanor, root, key) do
    from(u in where_athanor(StorageUnit, athanor), where: u.root == ^root and u.unit_key == ^key)
    |> Arca.Repo.one()
  end

  # When each revision the journal names as a commit's prior stopped being
  # the pointer: that commit's time, keyed as a revision prefix is.
  defp superseded_at(athanor) do
    from(c in where_athanor(StorageCommit, athanor),
      join: u in StorageUnit,
      on: u.id == c.storage_unit_id and u.athanor_id == ^athanor,
      where: not is_nil(c.prior_revision),
      select: {u.root, u.unit_key, c.prior_revision, c.committed_at}
    )
    |> Arca.Repo.all()
    |> Map.new(fn {root, key, revision, at} -> {{root, key, revision}, at} end)
  end

  defp rooted_rows(athanor) do
    from(u in where_athanor(StorageUnit, athanor),
      where: u.state == "committed" or not is_nil(u.draft_writer_token)
    )
    |> Arca.Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Tenancy and the outage spelling
  # ---------------------------------------------------------------------------

  # The refusal that precedes every query and every listing.
  defp tenant(%Prima.Actor{athanor_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp tenant(%Prima.Actor{}), do: {:error, :no_athanor}

  defp rescuing_db(entry, fun) do
    case Arca.Repo.Errors.with_db_rescue("Arca.StorageGC.#{entry}", fun) do
      {:error, :database_error} -> {:error, :unavailable}
      answer -> answer
    end
  end

  defp internally(fun), do: Arca.Overlay.with_internal_writes(fun)

  # Focused on the actor's athanor and no other; the user_id is
  # attribution only. The server's own actor NARROWED to this athanor:
  # `system: true` is what lets the sweep write the date files under a
  # reserved root, and `scope: :athanor` is what keeps its
  # listings inside the one athanor. A bare `Prima.Actor.system/0` here
  # would widen every sweep to platform scope with nothing to fail.
  defp internal_actor(%Prima.Actor{athanor_id: athanor}) do
    %{Prima.Actor.system() | athanor_id: athanor, scope: :athanor, user_id: "_storage_gc"}
  end
end
