# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Overlay do
  @moduledoc """
  The seeded roots the layout table marks `:overlay` — `components/` and
  `aqua/` — as the athanor's own tree, filled from the seed tree, the
  shipped default.

  An ADAPTER DECORATOR, not a facade layer: this module implements the
  `Arca.Storage` behaviour, wrapping the configured tenant adapter. Every
  read answers from the athanor's tree alone; the seed tree — install
  media, read-only, on local disk — is where shipped units are copied
  FROM: at provisioning (`materialize_shipped/2`), when a person pulls a
  shipped version or restores a unit to what ships (`pull_shipped/2`,
  `revert_copy/2`). A release that ships newer versions changes nothing
  in an estate; the newer units read as `:available` until pulled.

  ## Shadow units — the domain's grammar, not a depth

  Where a root's units sit and how they are shaped is the answer of its
  `Arca.Storage.UnitLocator` (`Arca.Storage.locate/1`): a component
  version directory is a directory unit sentinel'd by its manifest, an
  aqua agent a file unit, an aqua skill a directory unit sentinel'd by
  `SKILL.md`. The grammar is pure — shape is known before any file
  exists — so nothing here ever probes the tree to learn what kind of
  unit a path belongs to.

  ## The sentinel — crash-safe unit commits

  "Completed" is a fact the tree itself records: every valid directory
  unit carries its sentinel file, and `commit_unit/4` — the one way a
  unit lands, for scaffold, fork, the tincture store, publish, OCI pull
  and the shipped copy alike — writes it LAST. A crash or failure
  mid-commit leaves the unit without its sentinel, so it keeps reading
  as incomplete, and an error return rolls the partial back; the next
  commit replaces whatever remains wholesale. No hidden marker file: the
  sentinel is an ordinary, digest-counted member of the unit. A file
  unit is atomic by construction — a single put — and counts as
  completed when the tenant file exists.

  ## Marks — whose work a unit is, and whether it was edited

  Bytes alone cannot say whether a unit is a copy of what shipped or the
  athanor's own work at a path a release also ships, nor whether a copy
  has been edited since it landed. Two objects under the reserved `meta/`
  root record each fact, one per unit: `meta/origin/{unit…}` marks a unit
  this decorator copied from the seed, and `meta/edited/{unit…}` marks a
  copy a member has written into since. Each is a single put to record
  and a single delete to clear, so concurrent copies never lose each
  other's marks and there is no index file to corrupt. `unit_status/2`
  answers `:shipped` for a marked, unedited copy and `:modified` for an
  edited one; an unmarked complete unit over a shipped counterpart is
  `:own_shadowing` — the athanor's own work, which no restore touches.
  Marks are advisory and fail toward the athanor owning its bytes.

  `meta/` is a reserved tenant root (`Arca.Storage.reserved_roots/0`):
  only this module's internal-write scope or an `auth_method: :system`
  context may mutate it, so a member-level write can never forge a mark.

  ## Deletes

  A shipped copy is restored, never deleted: `delete/2` and
  `delete_tree/2` at a marked unit refuse as `{:error, :bundled}`, and
  `drop_unit/2` says the same. A write or delete inside a shipped copy is
  an edit and marks it so. The athanor's own units delete plainly.

  ## The internal-write scope

  Shipped copies write back through the `Arca` facade — so every copied
  byte passes the same usage accounting as any other write — inside
  `with_internal_writes/1`, a lexical, process-local scope that exempts
  exactly those writes from the edit marks, the `:bundled` refusal and
  the reserved-`meta/` gate. The exemption cannot be reached by
  constructing any context shape; the internal context's
  `user_id: "_overlay"` is attribution only.
  """

  @behaviour Arca.Storage

  require Logger

  alias Sanctum.Context

  # One mark per copied unit at `meta/origin/{unit…}`, one per edited copy
  # at `meta/edited/{unit…}` — under a reserved, non-overlaid root of the
  # layout table (the match asserts the layout still reserves it):
  # invisible to every diff, honestly counted by the cap, mutable only by
  # the internal-write scope.
  @meta_root "meta"
  true = @meta_root in Arca.Storage.reserved_roots()
  @origin_root [@meta_root, "origin"]
  @edited_root [@meta_root, "edited"]

  @internal_writes_key {__MODULE__, :internal_writes}

  @typedoc """
  What one shadow unit holds: `:available` (the seed ships it, the athanor
  holds no complete copy — pull it), `:shipped` (the athanor's marked copy,
  unedited since it was copied), `:modified` (the athanor's marked copy,
  written into since), `:own` (the athanor's content, no seed
  counterpart), `:own_shadowing` (the athanor's own work at a path the seed
  also ships), `:absent` (neither side).
  """
  @type unit_status :: :available | :shipped | :modified | :own | :own_shadowing | :absent

  # ---------------------------------------------------------------------------
  # The internal-write scope
  # ---------------------------------------------------------------------------

  @doc """
  Run `fun` with this process exempt from the edit marks, the `:bundled`
  delete refusal, and the reserved-`meta/` write gate — the shipped
  copy's own scope, lexical and process-local (`try/after`), so no
  context shape can carry the exemption. Per-process by design: work
  handed to another process does not inherit it and refuses loudly.
  """
  @spec with_internal_writes((-> result)) :: result when result: term()
  def with_internal_writes(fun) when is_function(fun, 0) do
    prev = Process.put(@internal_writes_key, true)

    try do
      fun.()
    after
      if prev, do: :ok, else: Process.delete(@internal_writes_key)
    end
  end

  @doc false
  @spec internal_writes?() :: boolean()
  def internal_writes?, do: Process.get(@internal_writes_key, false)

  # ---------------------------------------------------------------------------
  # Arca.Storage callbacks — reads answer from the athanor's tree alone;
  # writes ride the unit lock and mark edits of shipped copies.
  # ---------------------------------------------------------------------------

  @impl true
  def get(%Context{} = ctx, path), do: tenant().get(ctx, path)

  @impl true
  def put(%Context{} = ctx, path, content) do
    with_unit_lock(ctx, path, fn ->
      with :ok <- prepare_write(ctx, path) do
        tenant().put(ctx, path, content)
      end
    end)
  end

  @impl true
  def append(%Context{} = ctx, path, content) do
    with_unit_lock(ctx, path, fn ->
      with :ok <- prepare_write(ctx, path) do
        tenant().append(ctx, path, content)
      end
    end)
  end

  @impl true
  def delete(%Context{} = ctx, path) do
    with_unit_lock(ctx, path, fn -> do_delete(ctx, path) end)
  end

  defp do_delete(%Context{} = ctx, path) do
    with :ok <- deletable(ctx, path),
         :ok <- mark_delete(ctx, path),
         :ok <- tenant().delete(ctx, path) do
      # A single-object delete can only retire a file-shaped unit; a file
      # inside a directory unit leaves the copy standing, edited.
      case Arca.Storage.locate(path) do
        {:file, unit} when unit == path -> clear_marks(ctx, unit)
        _inside_or_outside -> :ok
      end
    end
  end

  @impl true
  def delete_tree(%Context{} = ctx, path) do
    with_unit_lock(ctx, path, fn -> do_delete_tree(ctx, path) end)
  end

  defp do_delete_tree(%Context{} = ctx, path) do
    with :ok <- tree_deletable(ctx, path),
         :ok <- deletable(ctx, path),
         :ok <- mark_delete(ctx, path),
         :ok <- tenant().delete_tree(ctx, path) do
      clear_marks_after_delete_tree(ctx, path)
    end
  end

  # Tree deletion above units is allowed only when no tenant units exist
  # beneath the path; otherwise it returns `{:error, :above_unit}`.
  # Clear populated subtrees one unit at a time under each unit's lock.
  # The empty-tree check and deletion are not atomic with a new unit commit.
  # Internal writes may delete marks beneath a cleared root.
  defp tree_deletable(%Context{} = ctx, path) do
    if not internal_writes?() and Arca.Storage.locate(path) == :above_unit do
      case tenant().list_recursive(ctx, path) do
        {:ok, leaves} ->
          if Enum.any?(leaves, &leaf_loc/1), do: {:error, :above_unit}, else: :ok

        {:error, _} = error ->
          error
      end
    else
      :ok
    end
  end

  @impl true
  def exists?(%Context{} = ctx, path), do: tenant().exists?(ctx, path)

  @impl true
  def usage(%Context{} = ctx, path), do: tenant().usage(ctx, path)

  @impl true
  def serve_to_conn(conn, %Context{} = ctx, path, opts),
    do: tenant().serve_to_conn(conn, ctx, path, opts)

  @impl true
  def list_typed(%Context{} = ctx, path), do: tenant().list_typed(ctx, path)

  @impl true
  def list_recursive(%Context{} = ctx, path), do: tenant().list_recursive(ctx, path)

  # No read_subtree here: the facade's shared algorithm
  # (`Arca.Storage.read_subtree_via/4`) runs over this module's
  # `list_recursive/2` + `get/2`.

  # ---------------------------------------------------------------------------
  # Unit status — the public questions the tree can answer about itself.
  # `Compendium.Provenance` and the status/reset surfaces consume these.
  # ---------------------------------------------------------------------------

  @doc """
  What one shadow unit holds — see `t:unit_status/0`. A path below a unit
  is answered for its unit; a path above any unit (or outside the seeded
  roots) is `{:ok, :absent}`. A tenant-adapter outage answers
  `{:error, term}` — a status surface must not misreport the athanor's
  own units as shipped.
  """
  @spec unit_status(Context.t(), Arca.Storage.path()) ::
          {:ok, unit_status()} | {:error, term()}
  def unit_status(%Context{} = ctx, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:ok, :absent}

      loc ->
        # The same classification the batch form applies over its walked
        # leaf sets — the parity test in overlay_test pins the two
        # together.
        unit = unit_of(loc)

        with {:ok, state} <- tenant_unit_state(ctx, loc) do
          {:ok,
           classify(
             state,
             seed_unit_present?(loc),
             origin_mark?(ctx, unit),
             edited_mark?(ctx, unit)
           )}
        end
    end
  end

  @doc """
  Every unit under a seeded root, mapped to its status — the batch form
  of `unit_status/2`: four listings total (tenant, seed, the two mark
  roots), no per-unit probes — classifying a leaf is a pure locator call.
  `:absent` units are, by definition, not in the map; `:available` ones
  are, so a caller can see what the seed ships that the athanor lacks. A
  tenant listing outage answers `{:error, term}`, never a seed-only map.
  """
  @spec unit_statuses(Context.t(), String.t()) ::
          {:ok, %{Arca.Storage.path() => unit_status()}} | {:error, term()}
  def unit_statuses(%Context{} = ctx, root) when is_binary(root) do
    if root in Arca.Storage.overlay_roots() do
      with {:ok, tenant_leaves} <- tenant().list_recursive(ctx, [root]),
           {:ok, seed_leaves} <- seed_list_recursive([root]) do
        origins = marks(ctx, @origin_root)
        edits = marks(ctx, @edited_root)

        seed_locs = MapSet.new(for leaf <- seed_leaves, loc = leaf_loc(leaf), do: loc)

        tenant_by_loc =
          tenant_leaves
          |> Enum.group_by(&Arca.Storage.locate/1)
          |> Map.drop([:above_unit, :not_overlaid])

        all_locs = MapSet.union(seed_locs, MapSet.new(Map.keys(tenant_by_loc)))

        statuses =
          Map.new(all_locs, fn loc ->
            unit = unit_of(loc)
            leaves = Map.get(tenant_by_loc, loc, [])

            state =
              cond do
                completed_in_leaves?(loc, leaves) -> :complete
                leaves != [] -> :partial
                true -> :empty
              end

            {unit,
             classify(
               state,
               MapSet.member?(seed_locs, loc),
               MapSet.member?(origins, unit),
               MapSet.member?(edits, unit)
             )}
          end)

        {:ok, statuses}
      end
    else
      {:ok, %{}}
    end
  end

  # One classification for both status forms. Without a seed counterpart a
  # complete unit is the athanor's own, marks or not: a release that
  # stopped shipping a unit leaves the copy as the athanor's to keep.
  defp classify(:complete, false, _origin?, _edited?), do: :own
  defp classify(:complete, true, true, true), do: :modified
  defp classify(:complete, true, true, false), do: :shipped
  defp classify(:complete, true, false, _edited?), do: :own_shadowing
  defp classify(_incomplete, true, _origin?, _edited?), do: :available
  defp classify(:partial, false, _origin?, _edited?), do: :own
  defp classify(:empty, false, _origin?, _edited?), do: :absent

  @doc """
  How a unit's copy differs from its seed counterpart, as relative paths:
  `added` (tenant-only), `removed` (seed-only), `changed` (both, bytes
  differ). The seed side is filtered by the same droppings exclusion the
  shipped copy uses, so a pristine copy diffs empty. A file unit diffs as
  the single relative path `[]`. Memory-bounded to one unit — the same
  bound as a copy.
  """
  @spec diff_unit(Context.t(), Arca.Storage.path()) ::
          {:ok,
           %{
             added: [Arca.Storage.path()],
             removed: [Arca.Storage.path()],
             changed: [Arca.Storage.path()]
           }}
          | {:error, term()}
  def diff_unit(%Context{} = ctx, path) do
    case Arca.Storage.locate(path) do
      :not_overlaid ->
        {:error, :not_overlaid}

      :above_unit ->
        {:error, :not_a_unit}

      {:file, unit} ->
        with {:ok, tenant_pairs} <- file_pairs(fn -> tenant().get(ctx, unit) end),
             {:ok, seed_pairs} <- file_pairs(fn -> seed_get(unit) end) do
          {:ok, diff_pairs(tenant_pairs, seed_pairs)}
        end

      {:dir, unit, _sentinel} ->
        with {:ok, tenant_pairs} <-
               subtree_pairs(fn -> Arca.Storage.read_subtree_via(tenant(), ctx, unit) end),
             {:ok, seed_pairs} <- subtree_pairs(fn -> seed_read_subtree(unit) end) do
          {:ok, diff_pairs(tenant_pairs, seed_pairs)}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # The seed as the shipped default: what it ships, and copying it in.
  # ---------------------------------------------------------------------------

  @doc """
  Every unit the seed ships under a seeded root, as unit paths — what
  provisioning copies and a release offers. Install media that cannot be
  listed is a fault, never an empty bundle.
  """
  @spec shipped_units(String.t()) :: {:ok, [Arca.Storage.path()]} | {:error, term()}
  def shipped_units(root) when is_binary(root) do
    if root in Arca.Storage.overlay_roots() do
      with {:ok, seed_leaves} <- seed_list_recursive([root]) do
        units =
          for leaf <- seed_leaves, loc = leaf_loc(leaf), uniq: true, do: unit_of(loc)

        {:ok, Enum.sort(units)}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Copy one shipped unit into the athanor, whole — the seed's bytes,
  droppings excluded, the sentinel last, origin-marked and its edit mark
  cleared — replacing whatever copy stood there. What provisioning does
  for every shipped unit, what a pull of a shipped version does for one,
  and what a restore does over an edited copy. Shipped media is not
  capped: an estate must always be able to hold what the server ships.

  The athanor's own work at the path is never replaced: an unmarked
  complete unit refuses as `{:error, :own_work}`. A unit the seed does
  not ship refuses as `{:error, :not_shipped}`; a path that is not a unit
  as `{:error, :not_a_unit}`.
  """
  @spec pull_shipped(Context.t(), Arca.Storage.path()) ::
          :ok | {:error, :own_work | :not_shipped | :not_a_unit | :not_overlaid | term()}
  def pull_shipped(%Context{} = ctx, unit) do
    case Arca.Storage.locate(unit) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        cond do
          unit_of(loc) != unit ->
            {:error, :not_a_unit}

          not seed_unit_present?(loc) ->
            {:error, :not_shipped}

          true ->
            # Under the unit's lock: the own-work probe and the copy must
            # not straddle a member's write landing between them.
            with_unit_lock_at(ctx, unit, fn ->
              if completed?(ctx, loc) and not origin_mark?(ctx, unit) do
                {:error, :own_work}
              else
                do_pull_shipped(ctx, loc)
              end
            end)
        end
    end
  end

  defp do_pull_shipped(ctx, {:dir, unit, sentinel}) do
    seed_dir = seed(unit)

    with :ok <- seed_sentinel_present(seed_dir, sentinel),
         {:ok, _written} <-
           do_commit_dir_unit(
             ctx,
             unit,
             sentinel,
             {:tree, seed_dir, exclude: &excluded?/1},
             :exempt,
             :seed,
             nil
           ),
         :ok <- clear_edited(ctx, unit) do
      Logger.info("[Arca.Overlay] copied shipped #{Enum.join(unit, "/")} for #{ctx.athanor_id}")
      :ok
    end
  end

  # A file unit lands as one put. Mark-first: the put is the completion
  # event and the overlay has no hook after it, so a mark that failed to
  # land afterwards would never be retried and the copy would read as
  # member work forever. A crash in between leaves a mark without a file,
  # which every reader ignores (fails toward `:available`), and the
  # completing retry re-marks idempotently.
  defp do_pull_shipped(ctx, {:file, unit}) do
    with_internal_writes(fn ->
      with {:ok, bytes} <- seed_get(unit),
           :ok <- record_origin(ctx, unit),
           :ok <- Arca.put(ctx, unit, bytes, cap: :exempt),
           :ok <- clear_edited(ctx, unit) do
        Logger.info("[Arca.Overlay] copied shipped #{Enum.join(unit, "/")} for #{ctx.athanor_id}")
        :ok
      end
    end)
  end

  @doc """
  Copy every shipped unit under `root` the athanor does not hold — the
  `:available` ones — leaving copies, edits and the athanor's own work
  alone. What fills a fresh estate at provisioning and what heals an
  estate whose tree lost a copy. Answers the units copied; stops at the
  first unit that cannot be copied.
  """
  @spec materialize_shipped(Context.t(), String.t()) ::
          {:ok, [Arca.Storage.path()]} | {:error, term()}
  def materialize_shipped(%Context{} = ctx, root) when is_binary(root) do
    with {:ok, statuses} <- unit_statuses(ctx, root) do
      statuses
      |> Enum.filter(fn {_unit, status} -> status == :available end)
      |> Enum.map(fn {unit, _status} -> unit end)
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn unit, {:ok, copied} ->
        case pull_shipped(ctx, unit) do
          :ok -> {:cont, {:ok, [unit | copied]}}
          {:error, reason} -> {:halt, {:error, {:materialize_failed, unit, reason}}}
        end
      end)
      |> case do
        {:ok, copied} -> {:ok, Enum.reverse(copied)}
        error -> error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The revert verbs — the product meanings of "make it go away", so no
  # product tool re-derives deletion policy from status atoms.
  # ---------------------------------------------------------------------------

  @doc """
  Restore an edited copy to exactly what the release ships — what
  `component.reset` and `aqua.reset` mean. Only a `:modified` unit
  restores: an unedited copy answers `{:error, :pristine}`, the athanor's
  own work refuses as `{:error, :not_a_copy}` (`:own` and
  `:own_shadowing` alike — a restore never destroys member work), a unit
  the athanor does not hold as `{:error, :not_found}`.
  """
  @spec revert_copy(Context.t(), Arca.Storage.path()) ::
          :ok | {:error, :pristine | :not_a_copy | :not_found | :not_overlaid | term()}
  def revert_copy(%Context{} = ctx, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        case unit_status(ctx, path) do
          {:ok, :modified} -> pull_shipped(ctx, unit_of(loc))
          {:ok, :shipped} -> {:error, :pristine}
          {:ok, own} when own in [:own, :own_shadowing] -> {:error, :not_a_copy}
          {:ok, _available_or_absent} -> {:error, :not_found}
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  Delete one unit the athanor made itself, explicitly (`aqua.delete`,
  `reset all: true`): `{:ok, :deleted}` for its own work, shadowing a
  shipped counterpart or not. A shipped copy, edited or not, refuses as
  `{:error, :bundled}` — it is restored, never deleted — and a unit the
  athanor does not hold as `{:error, :not_found}`. The same disposition
  vocabulary `Compendium.Registry.delete/4` speaks.
  """
  @spec drop_unit(Context.t(), Arca.Storage.path()) ::
          {:ok, :deleted} | {:error, :bundled | :not_found | :not_overlaid | term()}
  def drop_unit(%Context{} = ctx, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        case unit_status(ctx, path) do
          {:ok, own} when own in [:own, :own_shadowing] ->
            with :ok <- delete_unit_locked(ctx, loc), do: {:ok, :deleted}

          {:ok, copy} when copy in [:shipped, :modified] ->
            {:error, :bundled}

          {:ok, _available_or_absent} ->
            {:error, :not_found}

          {:error, _} = error ->
            error
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Commit — the one way a unit lands: whole, or not at all.
  # ---------------------------------------------------------------------------

  @typedoc """
  What a unit commit writes: explicit relative files — bytes, or a lazy
  read for sources streamed from outside Arca (a scratch dir) — or
  another Arca tree, streamed one file at a time.
  """
  @type commit_source ::
          {:files,
           [
             {relative :: Arca.Storage.path(), binary() | (-> {:ok, binary()} | {:error, term()})}
           ]}
          | {:tree, src :: Arca.Storage.path(), [{:exclude, (Arca.Storage.path() -> boolean())}]}

  @doc """
  Land one whole unit: refuse-or-replace, write the non-sentinel files,
  sentinel LAST, origin mark only for the shipped copy — and on any
  error, delete the partial. Every ingress that lays a unit (scaffold,
  fork, the tincture store, publish, OCI pull, the shipped copy) commits
  through here, so sentinel-last, rollback, cap policy and usage
  accounting are one implementation, not a discipline each caller
  re-spells.

  Options:

    * `cap:` (required) — `:exempt` or `{:checked, bytes}`. Every call
      site states its policy, so the uncapped-by-design set stays
      explicit (`Sanctum.Tenancy.Caps` documents the roster).
    * `sentinel:` — the sentinel's bytes, overriding any sentinel entry
      the source carries (a fork's re-stamped manifest, a pull's
      authoritative config blob). A dir-unit commit with sentinel bytes
      from neither place refuses as `{:error, :missing_sentinel}` before
      any write.
    * `origin: :seed` — stamp the origin mark after the sentinel: the
      shipped copy's option, nobody else's (`:none` default).
    * `if_absent: true` — create, never replace: the athanor's tree is
      asked for the unit INSIDE its lock, and a complete unit already
      there refuses as `{:error, :exists}` before any write. A probe
      outside the lock (`exists?`, then commit) is a check-then-act race:
      two creators of one name could both pass it, and the second would
      silently replace the first.

  A file unit commits as one plain facade put — atomic by construction —
  and refuses `sentinel:`/`origin:`. A dir-unit commit over existing
  tenant content replaces it whole (stale files from a prior partial or
  an overwritten pull do not survive), and clears the unit's marks unless
  it is the shipped copy re-marking itself.

  Returns the written relatives in write order, sentinel last.
  """
  @spec commit_unit(Context.t(), Arca.Storage.path(), commit_source(), keyword()) ::
          {:ok, [Arca.Storage.path()]} | {:error, term()}
  def commit_unit(%Context{} = ctx, unit, source, opts) do
    cap = Keyword.fetch!(opts, :cap)
    origin = Keyword.get(opts, :origin, :none)
    override = Keyword.get(opts, :sentinel)
    if_absent? = Keyword.get(opts, :if_absent, false)

    case Arca.Storage.locate(unit) do
      {:file, ^unit} ->
        commit_file_unit(ctx, unit, source, cap, origin, override, if_absent?)

      {:dir, ^unit, sentinel} ->
        commit_dir_unit(ctx, unit, sentinel, source, cap, origin, override, if_absent?)

      other ->
        raise ArgumentError,
              "commit_unit needs a unit path; #{inspect(unit)} locates to #{inspect(other)}"
    end
  end

  @doc """
  One locked read-modify-write at a path inside a unit. `fun` receives
  the bytes at `path` and answers `{:ok, bytes}` to write them — a plain
  facade put, so the edit mark and the storage cap apply as for any write
  — or `{:error, reason}` to write nothing and answer that. The read and
  the write ride one hold of the unit's lock, so of two concurrent
  updates the second reads what the first wrote instead of overwriting
  it. `{:error, :not_found}` when nothing is at `path`,
  `{:error, :not_overlaid}` for a path no unit covers — there is no lock
  to hold there, and this must not promise one.
  """
  @spec update(
          Context.t(),
          Arca.Storage.path(),
          (binary() -> {:ok, binary()} | {:error, term()})
        ) :: :ok | {:error, term()}
  def update(%Context{} = ctx, path, fun) when is_function(fun, 1) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        with_unit_lock_at(ctx, unit_of(loc), fn ->
          with {:ok, current} <- Arca.get(ctx, path) do
            case fun.(current) do
              {:ok, bytes} when is_binary(bytes) -> Arca.put(ctx, path, bytes)
              {:error, _reason} = error -> error
            end
          end
        end)
    end
  end

  # A file unit's completing write IS the caller's one atomic put: no
  # sentinel, no rollback (failure leaves the previous bytes), and the
  # plain facade path so the edit mark applies untouched.
  defp commit_file_unit(ctx, unit, {:files, [{[], content}]}, cap, :none, nil, if_absent?) do
    # `cap: :exempt` on the put because the commit's own required policy
    # was just applied above — the caller stated it, and the one check is
    # this commit's, not the write gate's.
    with {:ok, bytes} <- resolve_content(content),
         :ok <- check_commit_cap(ctx, cap),
         :ok <- put_file_unit(ctx, unit, bytes, if_absent?) do
      {:ok, [[]]}
    end
  end

  defp commit_file_unit(_ctx, unit, _source, _cap, _origin, _override, _if_absent?) do
    raise ArgumentError,
          "a file unit (#{Enum.join(unit, "/")}) commits as {:files, [{[], bytes}]} " <>
            "with no sentinel:/origin: — the put is the commit"
  end

  # The presence probe and the put ride one hold of the unit's lock; the
  # nested facade put passes through the held-unit register.
  defp put_file_unit(ctx, unit, bytes, if_absent?) do
    with_unit_lock_at(ctx, unit, fn ->
      with :ok <- refuse_present(ctx, {:file, unit}, if_absent?) do
        Arca.put(ctx, unit, bytes, cap: :exempt)
      end
    end)
  end

  # Under the unit's lock: `clean_slate/2` clears the whole unit, so two of
  # these interleaving means the second one deletes the first one's files —
  # including files a caller has already been told were written. Nothing
  # inside a single commit can detect that; they simply must not overlap.
  defp commit_dir_unit(ctx, unit, sentinel, source, cap, origin, override, if_absent?) do
    with_unit_lock_at(ctx, unit, fn ->
      with :ok <- refuse_present(ctx, {:dir, unit, sentinel}, if_absent?) do
        do_commit_dir_unit(ctx, unit, sentinel, source, cap, origin, override)
      end
    end)
  end

  # `if_absent:` — a unit is present when the athanor holds a completed
  # copy. A partial (a crashed commit: no sentinel) is not — the commit
  # replaces it whole, as any commit would. What the seed ships is not
  # the athanor's until pulled, so it never counts as present here.
  defp refuse_present(_ctx, _loc, false), do: :ok

  defp refuse_present(ctx, loc, true) do
    if completed?(ctx, loc), do: {:error, :exists}, else: :ok
  end

  # The lock is per athanor and per unit: two athanors publishing the same
  # component name are different trees and never contend.
  defp lock_key(%Context{athanor_id: athanor_id}, unit), do: {athanor_id, unit}

  # ---------------------------------------------------------------------------
  # The unit lock, taken by the mutating callbacks themselves
  # ---------------------------------------------------------------------------

  # Serialize writes, appends and deletes under the containing unit's lock.
  # Materialization and the resulting write must share that lock.
  #
  # UnitLock is not reentrant. Track locks held by this process so nested
  # Arca writes reuse the outer acquisition.
  #
  # Deletes above units are allowed only when no units remain beneath them.
  # To clear a subtree, drop each unit under its own lock first.
  @held_units_key {__MODULE__, :held_unit_locks}

  defp with_unit_lock(%Context{} = ctx, path, fun) do
    case Arca.Storage.locate(path) do
      {:file, unit} -> with_unit_lock_at(ctx, unit, fun)
      {:dir, unit, _sentinel} -> with_unit_lock_at(ctx, unit, fun)
      _not_overlaid_or_above_unit -> fun.()
    end
  end

  defp with_unit_lock_at(%Context{} = ctx, unit, fun) do
    key = lock_key(ctx, unit)
    held = Process.get(@held_units_key, MapSet.new())

    if MapSet.member?(held, key) do
      fun.()
    else
      Arca.Overlay.UnitLock.with_lock(key, fn ->
        Process.put(@held_units_key, MapSet.put(held, key))

        try do
          fun.()
        after
          Process.put(@held_units_key, held)
        end
      end)
    end
  end

  defp do_commit_dir_unit(ctx, unit, sentinel, source, cap, origin, override) do
    internal = internal_ctx(ctx)

    with {:ok, sentinel_content} <- sentinel_bytes(internal, sentinel, source, override),
         :ok <- check_commit_cap(ctx, cap) do
      result =
        with_internal_writes(fn ->
          with :ok <- clean_slate(internal, unit),
               {:ok, written} <- write_source(internal, unit, sentinel, source),
               # The completion mark: the sentinel lands last, so a crash
               # anywhere above leaves the unit reading as incomplete and
               # the rollback (or the next commit) clears the remains.
               :ok <- Arca.put(internal, unit ++ [sentinel], sentinel_content),
               :ok <- maybe_record_origin(internal, unit, origin),
               :ok <- maybe_clear_marks(internal, unit, origin) do
            {:ok, written ++ [[sentinel]]}
          end
        end)

      case result do
        {:ok, _written} = ok ->
          ok

        {:error, reason} = error ->
          with_internal_writes(fn -> rollback(ctx, unit, reason) end)
          error
      end
    end
  end

  # Resolved before any write: a commit that could never be completed
  # must not move a byte.
  defp sentinel_bytes(_internal, _sentinel, _source, override) when is_binary(override),
    do: {:ok, override}

  defp sentinel_bytes(_internal, sentinel, {:files, files}, nil) do
    case List.keyfind(files, [sentinel], 0) do
      {_rel, content} -> resolve_content(content)
      nil -> {:error, :missing_sentinel}
    end
  end

  defp sentinel_bytes(internal, sentinel, {:tree, src, _opts}, nil) do
    case Arca.get(internal, src ++ [sentinel]) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :not_found} -> {:error, :missing_sentinel}
      {:error, _} = error -> error
    end
  end

  defp resolve_content(bytes) when is_binary(bytes), do: {:ok, bytes}
  defp resolve_content(thunk) when is_function(thunk, 0), do: thunk.()

  defp check_commit_cap(_ctx, :exempt), do: :ok

  defp check_commit_cap(ctx, {:checked, bytes}) when is_integer(bytes) and bytes >= 0,
    do: Sanctum.Tenancy.Caps.check_storage(ctx, bytes)

  # A commit replaces the unit whole: stale files from a prior partial or
  # an overwritten pull must not survive beside the new content. Probed
  # first so a fresh-target commit never invalidates the usage counters
  # for nothing.
  defp clean_slate(internal, unit) do
    case tenant().list_typed(internal, unit) do
      {:ok, [_ | _]} -> Arca.delete_tree(internal, unit)
      {:ok, []} -> :ok
      # A file where the unit's tree belongs — replaced like any content.
      {:error, :enotdir} -> Arca.delete(internal, unit)
      {:error, _} = error -> error
    end
  end

  defp write_source(internal, unit, sentinel, {:files, files}) do
    files
    |> Enum.reject(fn {rel, _content} -> rel == [sentinel] end)
    |> Enum.reduce_while({:ok, []}, fn {rel, content}, {:ok, acc} ->
      with {:ok, bytes} <- resolve_content(content),
           :ok <- Arca.put(internal, unit ++ rel, bytes) do
        {:cont, {:ok, [rel | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, written} -> {:ok, Enum.reverse(written)}
      {:error, _} = error -> error
    end
  end

  defp write_source(internal, unit, sentinel, {:tree, src, opts}) do
    exclude = Keyword.get(opts, :exclude, fn _relative -> false end)

    Arca.copy_tree(internal, src, unit,
      exclude: fn relative -> relative == [sentinel] or exclude.(relative) end
    )
  end

  # Directory units write the completeness sentinel before the origin mark.
  # A crash between them leaves :own_shadowing and preserves the bytes;
  # a failed mark write triggers rollback. File units require mark-then-put.
  defp maybe_record_origin(_internal, _unit, :none), do: :ok
  defp maybe_record_origin(internal, unit, :seed), do: record_origin(internal, unit)

  # A commit that is not the shipped copy lands the athanor's own bytes:
  # whatever marks the previous occupant carried no longer describe it.
  defp maybe_clear_marks(internal, unit, :none), do: clear_marks(internal, unit)
  defp maybe_clear_marks(_internal, _unit, :seed), do: :ok

  # An internal context focused on the caller's athanor, writing back
  # THROUGH the facade so every committed byte passes the facade's usage
  # accounting like any other write. The user_id is attribution only —
  # the exemption is the lexical internal-write scope.
  defp internal_ctx(%Context{} = ctx) do
    Sanctum.internal_context(user_id: "_overlay", athanor_id: ctx.athanor_id, scope: :athanor)
  end

  # ---------------------------------------------------------------------------
  # Edits of shipped copies, and the delete refusal
  # ---------------------------------------------------------------------------

  # A write inside a shipped copy is an edit, and the copy is marked so
  # BEFORE the write lands: a mark that failed to land after the write
  # would leave an edited copy reading as pristine, the direction that
  # hides member work from a restore. A spurious mark from a write that
  # then failed only means a restore that changes nothing. Only the
  # internal-write scope is exempt — the shipped copy re-marks itself.
  defp prepare_write(%Context{} = ctx, path) do
    if internal_writes?() do
      :ok
    else
      case Arca.Storage.locate(path) do
        loc when loc in [:not_overlaid, :above_unit] ->
          :ok

        {:file, unit} when unit != path ->
          # Below a file unit: a file has no interior to write into.
          {:error, :invalid_path}

        {:dir, unit, _sentinel} when unit == path ->
          # A put exactly at a directory unit would drop a file where the
          # unit's tree belongs.
          {:error, :invalid_path}

        loc ->
          mark_edit(ctx, loc)
      end
    end
  end

  # A delete inside a shipped copy is an edit; a delete of the unit itself
  # is `deletable/2`'s question and marks nothing.
  defp mark_delete(%Context{} = ctx, path) do
    if internal_writes?() do
      :ok
    else
      case Arca.Storage.locate(path) do
        {:dir, unit, _sentinel} = loc when unit != path -> mark_edit(ctx, loc)
        _unit_itself_above_or_outside -> :ok
      end
    end
  end

  defp mark_edit(ctx, loc) do
    unit = unit_of(loc)

    if completed?(ctx, loc) and origin_mark?(ctx, unit) and not edited_mark?(ctx, unit),
      do: record_edited(ctx, unit),
      else: :ok
  end

  # Refuse deleting a shipped copy whole: `{:error, :bundled}` for a
  # delete AT a marked unit. A file inside a directory unit deletes as an
  # edit; the athanor's own unit deletes normally. Only the internal-write
  # scope is exempt (its rollback and its replace delete what it lays).
  defp deletable(%Context{} = ctx, path) do
    if internal_writes?() do
      :ok
    else
      case Arca.Storage.locate(path) do
        {:file, unit} when unit == path ->
          refuse_marked(ctx, unit)

        {:dir, unit, _sentinel} when unit == path ->
          refuse_marked(ctx, unit)

        _inside_above_or_outside ->
          :ok
      end
    end
  end

  defp refuse_marked(ctx, unit) do
    if origin_mark?(ctx, unit), do: {:error, :bundled}, else: :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # The inner tenant adapter — the configured one. This module is the
  # decorator the facade always wraps around it; configured as the
  # adapter itself it would recurse without bound, so refuse loudly.
  defp tenant do
    case Arca.Storage.configured_adapter() do
      __MODULE__ ->
        raise ArgumentError,
              ":storage_adapter must name a real adapter (Local or S3) — " <>
                "Arca.Overlay is the decorator the facade already wraps around it"

      adapter ->
        adapter
    end
  end

  defp unit_of({:file, unit}), do: unit
  defp unit_of({:dir, unit, _sentinel}), do: unit

  defp leaf_loc(path) do
    case Arca.Storage.locate(path) do
      {:file, _} = loc -> loc
      {:dir, _, _} = loc -> loc
      _above_or_outside -> nil
    end
  end

  # The completeness test: is the athanor's copy of the unit COMPLETE? A
  # directory copy is complete when it holds its sentinel file; a file
  # unit when the tenant file exists. `exists?/2` is total by the adapter
  # contract, so these probes cannot carry an outage: they serve the
  # write gates, whose failure directions are safe. Status surfaces ask
  # `tenant_unit_state/2` instead — the error-carrying form.
  defp completed?(ctx, {:file, unit}), do: tenant().exists?(ctx, unit)

  defp completed?(ctx, {:dir, unit, sentinel}),
    do: tenant().exists?(ctx, unit ++ [sentinel])

  # The status-surface probe: what the athanor's own tree holds at the
  # unit, with the error channel the total `exists?/2` probes cannot
  # carry — a status answer must not misreport a copy as `:available`
  # during an adapter outage. `:enotdir` is a real answer (a file where a
  # tree belongs): content, but never a complete copy.
  defp tenant_unit_state(ctx, {:file, unit}) do
    parent = Enum.drop(unit, -1)
    name = List.last(unit)

    case tenant().list_typed(ctx, parent) do
      {:ok, entries} ->
        {:ok, if({name, :file} in entries, do: :complete, else: :empty)}

      {:error, :enotdir} ->
        {:ok, :empty}

      {:error, _} = error ->
        error
    end
  end

  defp tenant_unit_state(ctx, {:dir, unit, sentinel}) do
    case tenant().list_typed(ctx, unit) do
      {:ok, entries} ->
        cond do
          {sentinel, :file} in entries -> {:ok, :complete}
          entries != [] -> {:ok, :partial}
          true -> {:ok, :empty}
        end

      {:error, :enotdir} ->
        {:ok, :partial}

      {:error, _} = error ->
        error
    end
  end

  # Whether the seed ships the unit — shaped as the grammar declares it,
  # so a stray seed file where a directory unit belongs reads as absent
  # (broken install media is never copied anyway).
  defp seed_unit_present?({:file, unit}), do: seed_exists?(unit)

  defp seed_unit_present?({:dir, unit, _sentinel}) do
    case seed_list_typed(unit) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  # A failed commit must not linger: without its sentinel the partial unit
  # already reads as incomplete, but its bytes would count against the
  # cap and confuse direct reads of paths the write never reached. If the
  # rollback itself fails, the unit is stuck holding a partial — say so
  # loudly; the next successful commit replaces it wholesale.
  defp rollback(ctx, unit_dir, reason) do
    case Arca.delete_tree(internal_ctx(ctx), unit_dir) do
      :ok ->
        :ok

      {:error, rollback_reason} ->
        Logger.error(
          "[Arca.Overlay] unit commit at #{Enum.join(unit_dir, "/")} failed " <>
            "(#{inspect(reason)}) AND its rollback failed (#{inspect(rollback_reason)}) — " <>
            "a partial remains until the next commit replaces it"
        )

        :ok
    end
  end

  # A seed unit without its sentinel is broken install media — the copy
  # could never be marked complete, so refuse before moving a byte.
  defp seed_sentinel_present(seed_dir, sentinel) do
    if Arca.Adapters.Local.exists?(seed_ctx(), seed_dir ++ [sentinel]) do
      :ok
    else
      {:error, {:materialize_failed, :seed_sentinel_missing}}
    end
  end

  # Through the facade, so accounting applies as for any caller; this
  # decorator's own delete callbacks clear the unit's marks.
  defp delete_unit(ctx, {:file, unit}), do: Arca.delete(ctx, unit)
  defp delete_unit(ctx, {:dir, unit, _sentinel}), do: Arca.delete_tree(ctx, unit)

  # Serialize whole-unit deletion with commits using the same unit lock.
  defp delete_unit_locked(ctx, loc) do
    with_unit_lock_at(ctx, unit_of(loc), fn -> delete_unit(ctx, loc) end)
  end

  # ---------------------------------------------------------------------------
  # Marks
  # ---------------------------------------------------------------------------

  defp origin_mark?(ctx, unit), do: tenant().exists?(ctx, @origin_root ++ unit)
  defp edited_mark?(ctx, unit), do: tenant().exists?(ctx, @edited_root ++ unit)

  # The batch read of one mark root: one listing, each leaf a marked
  # unit. An unreadable listing degrades every marked unit to
  # `:own_shadowing` — visible, and the direction that never destroys the
  # athanor's bytes.
  defp marks(ctx, root) do
    case tenant().list_recursive(ctx, root) do
      {:ok, mark_leaves} ->
        MapSet.new(mark_leaves, &Enum.drop(&1, length(root)))

      {:error, reason} ->
        Logger.warning(
          "[Arca.Overlay] #{Enum.join(root, "/")} marks unreadable for #{ctx.athanor_id}: " <>
            inspect(reason)
        )

        MapSet.new()
    end
  end

  # One put records a mark, one delete clears it — no read-modify-write,
  # so concurrent copies never lose each other's marks. All ride the
  # internal-write scope: `meta/` is reserved, and the caller's own
  # context stays the author for accounting and audit.
  defp record_origin(ctx, unit), do: record_mark(ctx, @origin_root ++ unit, ~s({"origin":"seed"}))
  defp record_edited(ctx, unit), do: record_mark(ctx, @edited_root ++ unit, ~s({"edited":true}))

  defp record_mark(ctx, mark_path, bytes) do
    result = with_internal_writes(fn -> Arca.put(ctx, mark_path, bytes) end)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Arca.Overlay] mark write failed for #{ctx.athanor_id} " <>
            "at #{Enum.join(mark_path, "/")}: #{inspect(reason)}"
        )

        {:error, {:origin_mark, reason}}
    end
  end

  # Clearing is best-effort against a delete or replace that already
  # succeeded: a failure is loud (a stale mark could later misclassify the
  # athanor's own work as a copy) but does not undo anything.
  defp clear_marks(ctx, unit) do
    with :ok <- clear_mark(ctx, @origin_root ++ unit), do: clear_edited(ctx, unit)
  end

  defp clear_edited(ctx, unit), do: clear_mark(ctx, @edited_root ++ unit)

  defp clear_mark(ctx, mark_path) do
    result =
      with_internal_writes(fn ->
        case Arca.delete(ctx, mark_path) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          {:error, _} = error -> error
        end
      end)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Arca.Overlay] mark clear failed for #{ctx.athanor_id} " <>
            "at #{Enum.join(mark_path, "/")}: #{inspect(reason)} — " <>
            "a stale mark remains until the unit is next deleted"
        )

        :ok
    end
  end

  # After a delete_tree: a unit-level delete retires that unit's marks; a
  # wider delete inside a seeded root retires every mark beneath it.
  # Non-overlaid paths (the whole-tree purge included — `meta/` goes with
  # the tree) have no marks to clear.
  defp clear_marks_after_delete_tree(ctx, path) do
    case Arca.Storage.locate(path) do
      {:file, unit} when unit == path ->
        clear_marks(ctx, unit)

      {:dir, unit, _sentinel} when unit == path ->
        clear_marks(ctx, unit)

      :above_unit ->
        with_internal_writes(fn ->
          for root <- [@origin_root, @edited_root] do
            case Arca.delete_tree(ctx, root ++ path) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.error(
                  "[Arca.Overlay] mark sweep failed for #{ctx.athanor_id} " <>
                    "under #{Enum.join(root ++ path, "/")}: #{inspect(reason)}"
                )
            end
          end

          :ok
        end)

      _inside_unit_or_not_overlaid ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Diff plumbing and the seed side
  # ---------------------------------------------------------------------------

  # A file unit's side as pairs: the single relative path `[]`, or none.
  defp file_pairs(get_fun) do
    case get_fun.() do
      {:ok, bytes} -> {:ok, [{[], bytes}]}
      {:error, :not_found} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  # A directory unit's side as pairs; an absent side is no pairs at all.
  defp subtree_pairs(subtree_fun) do
    case subtree_fun.() do
      {:ok, pairs} -> {:ok, pairs}
      {:error, :not_found} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  defp diff_pairs(tenant_pairs, seed_pairs) do
    tenant_map = Map.new(tenant_pairs)
    seed_map = Map.new(Enum.reject(seed_pairs, fn {rel, _} -> excluded?(rel) end))

    added = Map.keys(tenant_map) -- Map.keys(seed_map)
    removed = Map.keys(seed_map) -- Map.keys(tenant_map)

    changed =
      for {rel, bytes} <- tenant_map,
          Map.has_key?(seed_map, rel) and Map.fetch!(seed_map, rel) != bytes,
          do: rel

    %{added: Enum.sort(added), removed: Enum.sort(removed), changed: Enum.sort(changed)}
  end

  # Unit completeness from an already-walked leaf list (the batch form of
  # `completed?/2`): a file unit is its own leaf; a directory unit is
  # complete when its sentinel leaf is present.
  defp completed_in_leaves?({:file, unit}, unit_leaves), do: unit in unit_leaves

  defp completed_in_leaves?({:dir, unit, sentinel}, unit_leaves),
    do: (unit ++ [sentinel]) in unit_leaves

  defp excluded?(relative), do: Arca.Storage.build_dropping?(relative)

  defp seed([root | rest]), do: Arca.Storage.seed_prefix(root) ++ rest

  # The seed side is always the Local adapter, reading install media in
  # place — whatever tenant adapter is configured.
  defp seed_get(path), do: Arca.Adapters.Local.get(seed_ctx(), seed(path))
  defp seed_exists?(path), do: Arca.Adapters.Local.exists?(seed_ctx(), seed(path))
  defp seed_list_typed(path), do: Arca.Adapters.Local.list_typed(seed_ctx(), seed(path))

  # Total in practice (Local answers {:ok, []} for a missing tree), but
  # the adapter tuple propagates — install media that cannot be listed is
  # a fault, not an empty union.
  defp seed_list_recursive(path) do
    with {:ok, leaves} <- Arca.Adapters.Local.list_recursive(seed_ctx(), seed(path)) do
      {:ok, Enum.map(leaves, &Arca.Storage.seed_logical/1)}
    end
  end

  defp seed_read_subtree(path),
    do: Arca.Storage.read_subtree_via(Arca.Adapters.Local, seed_ctx(), seed(path))

  # The context the overlay's DIRECT `Arca.Adapters.Local` seed reads run
  # under — the one read path that does not pass through the `Arca` facade.
  # Its safety rests on three facts stated in three modules, gathered here:
  # the facade's `authorize_path/2` would admit a system context anyway
  # (`Arca.Storage`), the adapter itself refuses seed WRITES
  # (`Arca.Adapters.Local.refuse_seed_write!/1`), and the seed tree is
  # tracked source, never tenant data. If any of the three moves, this
  # bypass must move with it.
  defp seed_ctx, do: Sanctum.system_context()
end
