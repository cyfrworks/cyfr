# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageGC do
  @moduledoc """
  Collection and repair of an estate's staging areas: the revision
  prefixes `Arca.Overlay`'s write protocol stages under
  (`Arca.Storage.UnitLocator.revision_prefix/2`).

  Only staging is ever collected. A served location is removed by the
  unit's drop (`Arca.StorageUnits.retire/3` and the overlay's delete
  path) and by nothing here.

  ## Roots

  A revision prefix is kept while any of these names it:

    * **the pointer** — the `current_revision` of a committed
      `storage_units` row: a commit whose move to the served location has
      not finished, which `repair/2` finishes;
    * **a live draft** — the unit's row holds a writer token registered
      within `Arca.StorageUnits.draft_ttl_ms/0` plus the grace, and the
      prefix carries its in-progress marker. The row does not say which
      revision its writer stages, so every marked prefix of the unit is
      kept while the draft lives;
    * **a pin** — `pin/4` recorded a holder against the revision, and the
      holder's row is live: an open turn, or a build still `started`. The
      pin is an object beside the revision prefixes and its life is the
      holder's row, so a holder that died pins nothing.

  ## Collection order

  `sweep/2` runs `roots/1`, `candidates/3` and `collect/3`:

    1. snapshot the roots;
    2. list every key under each root's staging area;
    3. a prefix is a candidate when the snapshot does not root it, its
       marker is absent or its unit's draft is dead past the lifetime plus
       the grace, and it is older than the grace;
    4. for one candidate, immediately before its deletion: a draft dead
       past the grace is retired, so its writer can never commit the
       revision; then the pointer, the draft and the pins of that one
       prefix are read again, and any of them keeps it;
    5. its objects are deleted, then its marker, last;
    6. the emptied revision directory is removed where the adapter has
       directories, with the dead pins recorded against it.

  After step 4 no commit can name the revision: a commit needs the draft
  token its writer registered, and the row no longer holds it. A reader
  pins before it resolves the pointer (`pin/4`), so its pin is either
  seen by step 4 or refused because the pointer has moved on. A crash at
  any step leaves a prefix a later sweep collects, or nothing: the marker
  outlives the objects, and it dates what is left.

  ## Repair

  `repair/2` restores what a committed row names and nothing else. The
  staged objects of the row's revision are moved to the served location
  only when the journal's newest commit is that revision and the staged
  objects hash to the content identity the journal recorded: a prefix a
  failed removal left partial is never served over a complete unit. That
  guard is `Arca.Overlay.repair_unit/2`'s, so it holds for every caller
  of it and not only for this sweep, which reads the same two things to
  tell a pending move from an unrecoverable row before it asks. Objects
  alone never make or move a pointer: a complete prefix no row names is
  collected after the grace like any other.

  A sweep finishes the same moves once they have outlived the grace, and
  is stricter, since nobody asked for it: it moves only over a served
  location that is incomplete, or that holds exactly that revision or the
  one before it. Anything else has been written to since, and is left
  for `repair/2`.

  ## Tenancy

  Every function takes the `Cyfr.Actor` first, refuses one with no
  athanor as `{:error, :no_athanor}` before any query or listing, and
  lists and deletes only inside that athanor's tree. The walk across
  estates belongs to the caller that owns the roster
  (`Cyfr.Retention.cleanup_all/1`).
  """

  import Ecto.Query, only: [from: 2]
  import Arca.QueryHelpers, only: [where_athanor: 2]

  require Logger

  alias Arca.Schemas.{BuildRecord, StorageCommit, StorageUnit, Turn}
  alias Arca.Storage.UnitLocator
  alias Arca.StorageUnits

  @default_grace_ms :timer.hours(24)
  @default_limit 200
  @pins ".pins"
  @holder_kinds ~w(turn build)

  @type refusal :: {:error, :no_athanor | :unavailable}
  @type holder :: {:turn | :build, String.t()}
  @type revision_key :: {root :: String.t(), unit_key :: String.t(), revision :: String.t()}

  @typedoc "The roots of one estate, as `roots/1` read them."
  @type roots :: %{
          current: MapSet.t(revision_key()),
          drafts: %{{String.t(), String.t()} => DateTime.t()},
          pins: MapSet.t(revision_key())
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
  reason; `pending` the rooted prefixes left for a later repair, with why;
  `unaged` the prefixes that carried no date and were given one;
  `unrecognized` the keys in a staging area that are no revision's.
  """
  @type report :: %{
          examined: non_neg_integer(),
          collected: non_neg_integer(),
          kept: %{atom() => non_neg_integer()},
          repaired: non_neg_integer(),
          pending: [{Arca.Storage.path(), term()}],
          unaged: non_neg_integer(),
          unrecognized: non_neg_integer(),
          errors: [{Arca.Storage.path(), term()}]
        }

  @doc "How long a dead prefix is kept before it is collected, by default."
  @spec default_grace_ms() :: pos_integer()
  def default_grace_ms, do: @default_grace_ms

  # ---------------------------------------------------------------------------
  # Pins
  # ---------------------------------------------------------------------------

  @doc """
  Pin `revision` of `unit` for a reader: `{:turn, id}` or `{:build, id}`,
  the row whose life is the pin's. The pin is written first and the
  pointer read after it, so a pin that answers `:ok` is one every later
  collection sees; a pointer that has moved on answers
  `{:error, :stale_revision}` and leaves no pin — the reader resolves the
  row again.
  """
  @spec pin(Cyfr.Actor.t(), Arca.Storage.path(), String.t(), holder()) ::
          :ok | {:error, :stale_revision | :invalid_holder | term()} | refusal()
  def pin(%Cyfr.Actor{} = actor, unit, revision, holder) when is_binary(revision) do
    with {:ok, _athanor} <- tenant(actor),
         {:ok, path} <- pin_path(unit, revision, holder) do
      inner = internal_actor(actor)
      {root, key} = UnitLocator.unit_key(unit)

      with :ok <- internally(fn -> Arca.put(inner, path, pin_body(holder), cap: :exempt) end) do
        case StorageUnits.current(actor, root, key) do
          {:ok, %{current_revision: ^revision}} ->
            :ok

          {:ok, _moved_on} ->
            remove(inner, path)
            {:error, :stale_revision}

          {:error, :not_found} ->
            remove(inner, path)
            {:error, :stale_revision}

          {:error, _} = error ->
            remove(inner, path)
            error
        end
      end
    end
  end

  @doc "Give a pin back. Idempotent."
  @spec unpin(Cyfr.Actor.t(), Arca.Storage.path(), String.t(), holder()) ::
          :ok | {:error, :invalid_holder | term()} | refusal()
  def unpin(%Cyfr.Actor{} = actor, unit, revision, holder) when is_binary(revision) do
    with {:ok, _athanor} <- tenant(actor),
         {:ok, path} <- pin_path(unit, revision, holder) do
      remove(internal_actor(actor), path)
    end
  end

  # ---------------------------------------------------------------------------
  # Collection
  # ---------------------------------------------------------------------------

  @doc """
  One bounded sweep of the actor's estate, in the moduledoc's order.

  Options: `grace_ms:` (default a day), `limit:` — how many prefixes one
  sweep collects or repairs, oldest first (default #{@default_limit}) —
  and `dry_run: true`, which counts what the snapshot would collect and
  touches nothing.
  """
  @spec sweep(Cyfr.Actor.t(), keyword()) :: {:ok, report()} | {:error, term()} | refusal()
  def sweep(%Cyfr.Actor{} = actor, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, athanor} <- tenant(actor),
         {:ok, roots, listing} <- snapshot(actor),
         {:ok, candidates} <- candidates(actor, roots, Keyword.put(opts, :listing, listing)) do
      limit = Keyword.get(opts, :limit, @default_limit)
      dry_run = Keyword.get(opts, :dry_run, false)
      {now, grace_ms} = clock(opts)

      report =
        %{
          examined: map_size(listing.groups),
          collected: 0,
          kept: %{},
          repaired: 0,
          pending: [],
          unaged: 0,
          unrecognized: listing.unrecognized,
          errors: []
        }
        |> collect_each(actor, Enum.take(candidates, limit), opts, dry_run)

      report =
        if dry_run do
          report
        else
          budget = max(limit - report.collected, 0)

          report
          |> date_unaged(actor, listing, roots)
          |> finish_moves(actor, overdue_moves(listing, roots, now, grace_ms), budget)
          |> drop_dead_pins(actor, listing)
        end

      :telemetry.execute(
        [:cyfr, :storage_gc, :sweep],
        %{
          examined: report.examined,
          collected: report.collected,
          kept: report.kept |> Map.values() |> Enum.sum(),
          repaired: report.repaired,
          pending: length(report.pending),
          errors: length(report.errors),
          duration_ms: System.monotonic_time(:millisecond) - started
        },
        %{athanor_id: athanor, dry_run: dry_run}
      )

      {:ok, report}
    end
  end

  @doc """
  The roots of the actor's estate, read now: the committed pointers, the
  units whose draft is held (with when it was registered), and the
  revisions a live holder pins.

  The rows are read before the pins are listed. A pin stands only if the
  pointer still named its revision after the pin was written, so a
  snapshot whose rows show a later pointer lists after every pin on the
  earlier one was written, and sees it.
  """
  @spec roots(Cyfr.Actor.t()) :: {:ok, roots()} | {:error, term()} | refusal()
  def roots(%Cyfr.Actor{} = actor) do
    with {:ok, roots, _listing} <- snapshot(actor), do: {:ok, roots}
  end

  # Step 1 and step 2 off one listing: the rows, then the keys.
  defp snapshot(actor) do
    with {:ok, athanor} <- tenant(actor),
         {:ok, rows} <- rescuing_db("roots", fn -> {:ok, rooted_rows(athanor)} end),
         {:ok, listing} <- listing(actor),
         {:ok, pins} <- live_pins(athanor, listing.pins) do
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
         pins: pins
       }, listing}
    end
  end

  @doc """
  The prefixes `roots` does not keep, oldest first: not the pointer's and
  not pinned, the marker absent or the unit's draft dead past the
  lifetime plus the grace, and older than the grace. A prefix that
  carries no date is not a candidate.
  """
  @spec candidates(Cyfr.Actor.t(), roots(), keyword()) ::
          {:ok, [candidate()]} | {:error, term()} | refusal()
  def candidates(%Cyfr.Actor{} = actor, %{current: _, drafts: _, pins: _} = roots, opts \\ []) do
    with {:ok, _athanor} <- tenant(actor),
         {:ok, listing} <- given_listing(actor, opts) do
      {now, grace_ms} = clock(opts)
      inner = internal_actor(actor)

      found =
        for {{root, key, revision} = id, keys} <- listing.groups,
            not MapSet.member?(roots.current, id),
            not MapSet.member?(roots.pins, id),
            unit = UnitLocator.unit_path(root, key),
            {:ok, marker?} = {:ok, marker?(keys)},
            not (marker? and live_draft?(Map.get(roots.drafts, {root, key}), now, grace_ms)),
            older_than?(started_at(inner, unit, revision, marker?), now, grace_ms) do
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
  pointer, the draft and the pins are read again here, whatever the
  snapshot said. Answers `:collected`, or `{:kept, reason}` with
  `:committed`, `:live_draft` or `:pinned`.
  """
  @spec collect(Cyfr.Actor.t(), candidate(), keyword()) ::
          :collected | {:kept, :committed | :live_draft | :pinned} | {:error, term()} | refusal()
  def collect(%Cyfr.Actor{} = actor, %{unit: unit, revision: revision} = candidate, opts \\ [])
      when is_binary(revision) do
    with {:ok, athanor} <- tenant(actor) do
      {now, grace_ms} = clock(opts)
      inner = internal_actor(actor)

      with :ok <- retire_dead_draft(actor, athanor, candidate, now, grace_ms),
           :ok <- unrooted(athanor, inner, candidate, now, grace_ms) do
        delete_prefix(inner, unit, revision)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Repair
  # ---------------------------------------------------------------------------

  @doc """
  Audit every committed unit of the actor's estate against its journal
  and its objects, and finish the moves that did not finish.

  Answers, by unit path: `repaired` — the staged revision the row names
  was moved to the served location; `intact` (a count) — nothing staged,
  the completion object served; `left` — staged objects that were not
  moved, with why (`:journal_mismatch`, `:staged_incomplete`,
  `{:repair_failed, reason}`); `unrecoverable` — a
  row whose revision is neither staged nor served, reported and left as
  it is; `orphan_commits` — journal rows whose unit row is gone, reported
  and left.
  """
  @spec repair(Cyfr.Actor.t(), keyword()) ::
          {:ok,
           %{
             repaired: [Arca.Storage.path()],
             intact: non_neg_integer(),
             left: [{Arca.Storage.path(), term()}],
             unrecoverable: [Arca.Storage.path()],
             orphan_commits: [String.t()]
           }}
          | {:error, term()}
          | refusal()
  def repair(%Cyfr.Actor{} = actor, _opts \\ []) do
    with {:ok, athanor} <- tenant(actor),
         {:ok, {rows, orphans}} <-
           rescuing_db("repair", fn ->
             {:ok, {committed_rows(athanor), orphan_commits(athanor)}}
           end),
         {:ok, listing} <- listing(actor) do
      inner = internal_actor(actor)
      report = %{repaired: [], intact: 0, left: [], unrecoverable: [], orphan_commits: orphans}

      {:ok,
       Enum.reduce(rows, report, fn row, acc ->
         unit = UnitLocator.unit_path(row.root, row.unit_key)
         staged = Map.get(listing.groups, {row.root, row.unit_key, row.current_revision}, [])

         case audit(athanor, inner, row, unit, staged) do
           :repaired -> %{acc | repaired: [unit | acc.repaired]}
           :intact -> %{acc | intact: acc.intact + 1}
           :unrecoverable -> %{acc | unrecoverable: [unit | acc.unrecoverable]}
           {:left, reason} -> %{acc | left: [{unit, reason} | acc.left]}
         end
       end)}
    end
  end

  defp audit(athanor, inner, row, unit, staged) do
    if Enum.any?(staged, &(not marker_key?(&1))) do
      finish_move(athanor, inner, row, unit, :asked)
    else
      case served_complete?(inner, unit) do
        true ->
          :intact

        false ->
          Logger.error(
            "[Arca.StorageGC] #{Enum.join(unit, "/")} is committed at #{row.current_revision} " <>
              "and that revision is neither staged nor served; the row is left as it is"
          )

          :unrecoverable
      end
    end
  end

  # The one promotion there is: the revision the row names, proven against
  # the journal before a byte moves.
  defp finish_move(athanor, inner, %StorageUnit{} = row, unit, asked) do
    with {:ok, newest, prior} <- journal_of(athanor, row),
         :ok <- staged_as_committed(inner, unit, row.current_revision, newest),
         :ok <- if(asked == :asked, do: :ok, else: served_replaceable(inner, unit, newest, prior)) do
      case Arca.Overlay.repair_unit(inner, unit) do
        {:ok, _repaired_or_nothing_pending} -> :repaired
        {:error, reason} -> {:left, {:repair_failed, reason}}
      end
    else
      {:left, _reason} = left -> left
      {:error, reason} -> {:left, {:repair_failed, reason}}
    end
  end

  defp journal_of(athanor, %StorageUnit{id: id, current_revision: revision}) do
    rescuing_db("journal_of", fn ->
      commits =
        from(c in where_athanor(StorageCommit, athanor),
          where: c.storage_unit_id == ^id,
          order_by: [desc: c.committed_at, desc: c.id],
          limit: 2
        )
        |> Arca.Repo.all()

      case commits do
        [%StorageCommit{new_revision: ^revision} = newest | rest] ->
          {:ok, newest, Enum.find(rest, &(&1.new_revision == newest.prior_revision))}

        _no_commit_names_the_pointer ->
          {:left, :journal_mismatch}
      end
    end)
  end

  defp staged_as_committed(inner, unit, revision, %StorageCommit{content_identity: committed}) do
    prefix = UnitLocator.revision_prefix(unit, revision)

    with {:ok, keys} <- list_under(inner, prefix),
         {:ok, identity} <-
           identity_of(
             inner,
             Enum.reject(keys, &marker_key?/1),
             &staged_relative(unit, prefix, &1)
           ) do
      if identity == committed, do: :ok, else: {:left, :staged_incomplete}
    end
  end

  # An incomplete served location is what a move that stopped leaves. A
  # complete one is replaced only when it is, byte for byte, this revision
  # or the one before it: anything else has been written to since, and a
  # move over it would take those writes.
  defp served_replaceable(inner, unit, newest, prior) do
    if served_complete?(inner, unit) do
      known = [newest.content_identity | List.wrap(prior && prior.content_identity)]

      with {:ok, keys} <- served_keys(inner, unit),
           {:ok, identity} <- identity_of(inner, keys, &served_relative(unit, &1)) do
        if identity in known, do: :ok, else: {:left, :served_diverged}
      end
    else
      :ok
    end
  end

  defp served_keys(inner, unit) do
    case Arca.Storage.locate(unit) do
      {:file, ^unit} -> {:ok, [unit]}
      {:dir, ^unit, _sentinel} -> Arca.list_recursive(inner, unit)
    end
  end

  defp served_complete?(inner, unit) do
    case Arca.Storage.locate(unit) do
      {:file, ^unit} -> Arca.exists?(inner, unit)
      {:dir, ^unit, sentinel} -> Arca.exists?(inner, unit ++ [sentinel])
      _not_a_unit -> false
    end
  end

  # A file unit is one object whose relative path is `[]`, staged under
  # its own name.
  defp staged_relative(unit, prefix, key) do
    case Arca.Storage.locate(unit) do
      {:file, ^unit} -> []
      _dir -> Enum.drop(key, length(prefix))
    end
  end

  defp served_relative(unit, key), do: Enum.drop(key, length(unit))

  # The content identity of a set of objects, read one at a time and
  # framed by `Arca.Overlay.content_identity/1` — the framing a commit
  # recorded, stated once, there.
  defp identity_of(inner, keys, relative) do
    keys
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      case Arca.get(inner, key) do
        {:ok, bytes} ->
          {:cont, {:ok, [{relative.(key), Cyfr.Digest.sha256(bytes), byte_size(bytes)} | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, manifest} -> {:ok, Arca.Overlay.content_identity(manifest)}
      {:error, _} = error -> error
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
  # of its age. It is given a marker now, and a later sweep reads it.
  defp date_unaged(report, actor, listing, roots) do
    inner = internal_actor(actor)

    undated =
      for {{root, key, revision} = id, keys} <- listing.groups,
          not MapSet.member?(roots.current, id),
          not marker?(keys),
          revision_time(revision) == :error,
          do: UnitLocator.marker_path(UnitLocator.unit_path(root, key), revision)

    Enum.each(undated, fn path ->
      body = Jason.encode!(%{"observed_at" => DateTime.to_iso8601(DateTime.utc_now())})
      internally(fn -> Arca.put(inner, path, body, cap: :exempt) end)
    end)

    %{report | unaged: length(undated)}
  end

  # The pointer's own prefixes that have outlived the grace: commits whose
  # writer never finished the move.
  defp overdue_moves(listing, roots, now, grace_ms) do
    for {{root, key, revision} = id, keys} <- listing.groups,
        MapSet.member?(roots.current, id),
        Enum.any?(keys, &(not marker_key?(&1))),
        older_than?(revision_time(revision), now, grace_ms),
        do: {root, key}
  end

  defp finish_moves(report, actor, moves, budget) do
    {:ok, athanor} = tenant(actor)
    inner = internal_actor(actor)

    moves
    |> Enum.take(budget)
    |> Enum.reduce(report, fn {root, key}, acc ->
      unit = UnitLocator.unit_path(root, key)

      case rescuing_db("finish_moves", fn -> {:ok, fetch(athanor, root, key)} end) do
        {:ok, %StorageUnit{state: "committed"} = row} ->
          case finish_move(athanor, inner, row, unit, :unasked) do
            :repaired -> %{acc | repaired: acc.repaired + 1}
            {:left, reason} -> %{acc | pending: [{unit, reason} | acc.pending]}
          end

        {:ok, _dropped_since} ->
          acc

        {:error, reason} ->
          %{acc | errors: [{unit, reason} | acc.errors]}
      end
    end)
  end

  # A pin whose holder is no longer live holds nothing.
  defp drop_dead_pins(report, actor, listing) do
    {:ok, athanor} = tenant(actor)
    inner = internal_actor(actor)
    holders = for {_id, holder, _path} <- listing.pins, do: holder

    with {:ok, live} <- live_holders(athanor, holders) do
      for {_id, holder, path} <- listing.pins, not MapSet.member?(live, holder) do
        remove(inner, path)
      end
    end

    report
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
         :ok <- not_the_pointer(row, candidate.revision),
         :ok <- no_live_draft(inner, row, candidate, now, grace_ms) do
      not_pinned(athanor, inner, candidate)
    end
  end

  defp not_the_pointer(%StorageUnit{state: "committed", current_revision: revision}, revision),
    do: {:kept, :committed}

  defp not_the_pointer(_row, _revision), do: :ok

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

  defp not_pinned(athanor, inner, %{unit: unit, revision: revision}) do
    with {:ok, keys} <- list_under(inner, pins_prefix(unit) ++ [revision]),
         holders = for(key <- keys, {:ok, holder} <- [parse_holder(List.last(key))], do: holder),
         {:ok, live} <- live_holders(athanor, holders) do
      if Enum.any?(holders, &MapSet.member?(live, &1)), do: {:kept, :pinned}, else: :ok
    end
  end

  # Steps 5 and 6. The marker outlives every object, so what a crash leaves
  # is still a dated prefix.
  defp delete_prefix(inner, unit, revision) do
    prefix = UnitLocator.revision_prefix(unit, revision)
    marker = UnitLocator.marker_path(unit, revision)

    with {:ok, keys} <- list_under(inner, prefix),
         :ok <- remove_each(inner, Enum.reject(keys, &(&1 == marker))),
         :ok <- remove(inner, marker),
         :ok <- internally(fn -> Arca.delete_tree(inner, prefix) end),
         :ok <- internally(fn -> Arca.delete_tree(inner, pins_prefix(unit) ++ [revision]) end) do
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

  # Every key under the estate's staging areas, sorted into revision
  # prefixes, pins and the rest. One listing per overlaid root, inside the
  # actor's athanor.
  defp listing(actor) do
    inner = internal_actor(actor)

    Enum.reduce_while(
      Arca.Storage.overlay_roots(),
      {:ok, %{groups: %{}, pins: [], unrecognized: 0}},
      fn root, {:ok, acc} ->
        case list_under(inner, staging_area(root)) do
          {:ok, keys} -> {:cont, {:ok, Enum.reduce(keys, acc, &sort_key(root, &1, &2))}}
          {:error, _} = error -> {:halt, error}
        end
      end
    )
  end

  defp sort_key(root, [root, _staging, @pins | rest] = path, acc) do
    case staged_at(root, rest) do
      {:ok, key, revision, [name]} ->
        case parse_holder(name) do
          {:ok, holder} -> %{acc | pins: [{{root, key, revision}, holder, path} | acc.pins]}
          :error -> %{acc | unrecognized: acc.unrecognized + 1}
        end

      _not_a_pin ->
        %{acc | unrecognized: acc.unrecognized + 1}
    end
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

  # The staging area of a whole root: what every unit's staging prefix
  # starts with.
  defp staging_area(root), do: [root, "unit"] |> UnitLocator.staging_prefix() |> Enum.drop(-1)

  defp pins_prefix([root | rest]), do: staging_area(root) ++ [@pins | rest]

  # Every adapter answers the prefix listing (`c:Arca.Storage.list_prefix/2`),
  # so a staging area is read as keys, never walked as a tree.
  defp list_under(inner, prefix), do: Arca.Storage.list_prefix(inner, prefix)

  defp marker?(keys), do: Enum.any?(keys, &marker_key?/1)
  defp marker_key?(key), do: List.last(key) == UnitLocator.marker_name()

  # ---------------------------------------------------------------------------
  # Ages
  # ---------------------------------------------------------------------------

  defp clock(opts) do
    {Keyword.get(opts, :now, DateTime.utc_now()), Keyword.get(opts, :grace_ms, @default_grace_ms)}
  end

  defp live_draft?(nil, _now, _grace_ms), do: false

  defp live_draft?(%DateTime{} = registered, now, grace_ms) do
    DateTime.diff(now, registered, :millisecond) <= StorageUnits.draft_ttl_ms() + grace_ms
  end

  defp older_than?({:ok, %DateTime{} = at}, now, grace_ms),
    do: DateTime.diff(now, at, :millisecond) > grace_ms

  defp older_than?(:error, _now, _grace_ms), do: false

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
  # Pins and their holders
  # ---------------------------------------------------------------------------

  defp pin_path(unit, revision, {kind, id})
       when kind in [:turn, :build] and is_binary(id) and is_list(unit) do
    case Arca.Storage.locate(unit) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :invalid_holder}

      _unit ->
        if segment?(id) and segment?(revision),
          do: {:ok, pins_prefix(unit) ++ [revision, "#{kind}.#{id}"]},
          else: {:error, :invalid_holder}
    end
  end

  defp pin_path(_unit, _revision, _holder), do: {:error, :invalid_holder}

  defp pin_body({kind, id}) do
    Jason.encode!(%{
      "holder" => "#{kind}.#{id}",
      "pinned_at" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp parse_holder(name) do
    with [kind, id] when kind in @holder_kinds <- String.split(name, ".", parts: 2),
         true <- segment?(id) do
      {:ok, {String.to_existing_atom(kind), id}}
    else
      _ -> :error
    end
  end

  # A holder id and a revision are each one path segment of a pin's key.
  defp segment?(name), do: Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, name)

  defp live_pins(athanor, pins) do
    with {:ok, live} <- live_holders(athanor, for({_id, holder, _path} <- pins, do: holder)) do
      {:ok,
       for({id, holder, _path} <- pins, MapSet.member?(live, holder), into: MapSet.new(), do: id)}
    end
  end

  # A pin lives as long as its holder's row does: an open turn, a build
  # still started.
  defp live_holders(_athanor, []), do: {:ok, MapSet.new()}

  defp live_holders(athanor, holders) do
    turn_ids = for {:turn, id} <- holders, do: id
    build_ids = for {:build, id} <- holders, do: id

    rescuing_db("live_holders", fn ->
      turns =
        from(t in where_athanor(Turn, athanor),
          where: t.id in ^turn_ids and t.status in ^Arca.TurnStorage.open_statuses(),
          select: t.id
        )
        |> Arca.Repo.all()

      builds =
        from(b in where_athanor(BuildRecord, athanor),
          where: b.id in ^build_ids and b.status == "started",
          select: b.id
        )
        |> Arca.Repo.all()

      {:ok, MapSet.new(Enum.map(turns, &{:turn, &1}) ++ Enum.map(builds, &{:build, &1}))}
    end)
  end

  # ---------------------------------------------------------------------------
  # Rows
  # ---------------------------------------------------------------------------

  defp fetch(athanor, root, key) do
    from(u in where_athanor(StorageUnit, athanor), where: u.root == ^root and u.unit_key == ^key)
    |> Arca.Repo.one()
  end

  defp rooted_rows(athanor) do
    from(u in where_athanor(StorageUnit, athanor),
      where: u.state == "committed" or not is_nil(u.draft_writer_token)
    )
    |> Arca.Repo.all()
  end

  defp committed_rows(athanor) do
    from(u in where_athanor(StorageUnit, athanor),
      where: u.state == "committed" and not is_nil(u.current_revision),
      order_by: [asc: u.root, asc: u.unit_key]
    )
    |> Arca.Repo.all()
  end

  # The composite foreign key makes these impossible; a store restored
  # from parts is where one could appear.
  defp orphan_commits(athanor) do
    from(c in where_athanor(StorageCommit, athanor),
      left_join: u in StorageUnit,
      on: u.id == c.storage_unit_id and u.athanor_id == c.athanor_id,
      where: is_nil(u.id),
      select: c.id
    )
    |> Arca.Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Tenancy and the outage spelling
  # ---------------------------------------------------------------------------

  # The refusal that precedes every query and every listing.
  defp tenant(%Cyfr.Actor{athanor_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp tenant(%Cyfr.Actor{}), do: {:error, :no_athanor}

  defp rescuing_db(entry, fun) do
    case Arca.Repo.Errors.with_db_rescue("Arca.StorageGC.#{entry}", fun) do
      {:error, :database_error} -> {:error, :unavailable}
      answer -> answer
    end
  end

  defp internally(fun), do: Arca.Overlay.with_internal_writes(fun)

  # Focused on the actor's athanor and no other; the user_id is
  # attribution only. The server's own actor NARROWED to this athanor:
  # `system: true` is what lets the sweep write the pin and date files
  # under a reserved root, and `scope: :athanor` is what keeps its
  # listings inside the one estate. A bare `Cyfr.Actor.system/0` here
  # would widen every sweep to platform scope with nothing to fail.
  defp internal_actor(%Cyfr.Actor{athanor_id: athanor}) do
    %{Cyfr.Actor.system() | athanor_id: athanor, scope: :athanor, user_id: "_storage_gc"}
  end
end
