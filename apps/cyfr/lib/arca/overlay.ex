# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Overlay do
  @moduledoc """
  Seed overlay for the roots the layout table marks `:overlay` — today
  `components/` and `aqua/`: the athanor's own tree is the upper layer,
  the seed tree the lower, and every reader sees their union.

  An ADAPTER DECORATOR, not a facade layer: this module implements the
  `Arca.Storage` behaviour, wrapping the configured tenant adapter and the
  Local-pinned seed side. `Arca` dispatches every non-seed path here; a
  path outside the overlaid roots delegates to the configured adapter
  verbatim, so the facade knows nothing about the union — it keeps
  authorization, normalization, the write gates and usage accounting, and
  the overlay keeps the overlay.

  ## Shadow units — the domain's grammar, not a depth

  Where a root's units sit and how they are shaped is the answer of its
  `Arca.Storage.UnitLocator` (`Arca.Storage.locate/1`): a component
  version directory is a directory unit sentinel'd by its manifest, an
  aqua agent a file unit, an aqua skill a directory unit sentinel'd by
  `SKILL.md`. The grammar is pure — shape is known before any file
  exists — so nothing here ever probes the tree to learn what kind of
  unit a path belongs to.

  An athanor's *completed* copy of a unit fully shadows its seed
  counterpart; an uncompleted one reads through to the seed — which stays
  read-only, on local disk, exactly as install media. A write inside an
  unmaterialized seed unit materializes the whole unit into the athanor
  first (copy-on-write, build droppings excluded, the storage cap
  consulted for the materialization bytes), then lands. Deleting an
  unmaterialized bundle path is refused as `{:error, :bundled}`.

  ## The sentinel — crash-safe materialization

  "Completed" is a fact the tree itself records: every valid directory
  unit carries its sentinel file, and materialization copies it LAST. A
  crash or failure mid-copy leaves the unit without its sentinel, so it
  keeps reading as unmaterialized — the seed stays fully visible, and the
  partial copy's bytes are the seed's own, so even direct reads stay
  consistent — and the next write simply re-copies over the partial
  remains (an error return also rolls the partial copy back). No hidden
  marker file: the sentinel is an ordinary, digest-counted member of the
  unit. A file unit is atomic by construction — a single put — and counts
  as completed when the tenant file exists.

  Provisioning therefore copies nothing: a new athanor's overlaid scopes
  are empty on disk and complete through the facade, and the storage cap
  measures only what the athanor actually owns (`usage/2` is deliberately
  tenant-only).

  ## Origin marks — whose work is a complete unit

  Completeness alone cannot say who a complete unit belongs to: a
  copy-on-write of a shipped unit and a unit the athanor created itself
  that a LATER release also ships at the same path are byte-for-byte
  alike. The overlay therefore marks each unit it materializes with one
  object under the reserved `meta/origin/` prefix — one mark per unit, a
  single put to record and a single delete to clear, so concurrent
  materializations can never lose each other's marks and there is no
  index file to corrupt. `unit_status/2` answers `:materialized` only for
  a marked unit; an unmarked complete copy over a seed counterpart is
  `:own_shadowing` — the athanor's own work hiding a shipped counterpart,
  which reset refuses to touch. Marks are advisory, consulted only while
  a unit is complete with a seed counterpart, so a stale or missing mark
  fails toward the athanor owning its bytes — never toward destroying
  them. Deletes clear marks in this decorator itself: a unit delete
  removes the unit's mark, a wider `delete_tree` inside an overlaid root
  removes every mark beneath it, and the whole-tree purge takes `meta/`
  with everything else.

  `meta/` is a reserved tenant root (`Arca.Storage.reserved_roots/0`):
  only this module's internal-write scope or an `auth_method: :system`
  context may mutate it, so a member-level write can never forge a mark
  and turn "reset to shipped" into deleting member work.

  ## The internal-write scope

  Materialization writes back through the `Arca` facade — so every copied
  byte passes the same usage accounting as any other write — inside
  `with_internal_writes/1`, a lexical, process-local scope that exempts
  exactly those writes from copy-on-write and from the `:bundled` delete
  refusal (its rollback deletes a partial, sentinel-less copy — the shape
  refused for everyone else). The exemption cannot be reached by
  constructing any context shape; the internal context's
  `user_id: "_overlay"` is attribution only. Every other writer, system
  contexts included, copy-on-writes like any caller.
  """

  @behaviour Arca.Storage

  require Logger

  alias Sanctum.Context

  # One origin mark per materialized unit, at `meta/origin/{unit...}` —
  # under the reserved, non-overlaid `meta/` root: invisible to every
  # union merge and diff, honestly counted by the cap, mutable only by
  # the internal-write scope.
  @origin_root ["meta", "origin"]

  @internal_writes_key {__MODULE__, :internal_writes}

  @typedoc """
  What one shadow unit holds, as the union serves it: `:seed` (reads come
  from the bundle), `:materialized` (the athanor's marked copy of a
  shipped unit shadows it), `:own` (the athanor's content, no seed
  counterpart), `:own_shadowing` (the athanor's own work hiding a shipped
  counterpart at the same path), `:absent` (neither side).
  """
  @type unit_status :: :seed | :materialized | :own | :own_shadowing | :absent

  # ---------------------------------------------------------------------------
  # The internal-write scope
  # ---------------------------------------------------------------------------

  @doc """
  Run `fun` with this process exempt from copy-on-write, the `:bundled`
  delete refusal, and the reserved-`meta/` write gate — the
  materializer's own scope, lexical and process-local (`try/after`), so
  no context shape can carry the exemption. Per-process by design: work
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
  # Arca.Storage callbacks — reads union, writes copy-on-write.
  # ---------------------------------------------------------------------------

  @impl true
  def get(%Context{} = ctx, path) do
    case tenant().get(ctx, path) do
      {:error, :not_found} = miss ->
        if fall_through?(ctx, path) do
          case seed_get(path) do
            {:ok, _content} = hit -> hit
            {:error, _} -> miss
          end
        else
          miss
        end

      other ->
        other
    end
  end

  @impl true
  def put(%Context{} = ctx, path, content) do
    with :ok <- prepare_write(ctx, path) do
      tenant().put(ctx, path, content)
    end
  end

  @impl true
  def append(%Context{} = ctx, path, content) do
    with :ok <- prepare_write(ctx, path) do
      tenant().append(ctx, path, content)
    end
  end

  @impl true
  def delete(%Context{} = ctx, path) do
    with :ok <- deletable(ctx, path),
         :ok <- tenant().delete(ctx, path) do
      # A single-object delete can only retire a file-shaped unit; a file
      # inside a directory unit leaves the copy standing (modified).
      case Arca.Storage.locate(path) do
        {:file, unit} when unit == path -> clear_origin(ctx, unit)
        _inside_or_outside -> :ok
      end
    end
  end

  @impl true
  def delete_tree(%Context{} = ctx, path) do
    with :ok <- deletable(ctx, path),
         :ok <- tenant().delete_tree(ctx, path) do
      clear_origin_after_delete_tree(ctx, path)
    end
  end

  @impl true
  def exists?(%Context{} = ctx, path) do
    tenant().exists?(ctx, path) or
      (fall_through?(ctx, path) and seed_exists?(path))
  end

  # Deliberately NOT unioned: the union costs the athanor nothing until it
  # materializes — the storage cap measures only what it owns.
  @impl true
  def usage(%Context{} = ctx, path), do: tenant().usage(ctx, path)

  @impl true
  def serve_to_conn(conn, %Context{} = ctx, path, opts) do
    case tenant().serve_to_conn(conn, ctx, path, opts) do
      {:error, :not_found} = miss ->
        if fall_through?(ctx, path) do
          case Arca.Adapters.Local.serve_to_conn(conn, seed_ctx(), seed(path), opts) do
            {:ok, _conn} = served -> served
            {:error, _} -> miss
          end
        else
          miss
        end

      other ->
        other
    end
  end

  # At or below the shadow unit the two layers never mix — a completed
  # copy answers alone, an unmaterialized seed unit reads through, and a
  # tenant-only unit answers its own content; above it, names union (the
  # athanor's kind wins a collision).
  @impl true
  def list_typed(%Context{} = ctx, path) do
    tenant_result = tenant().list_typed(ctx, path)

    case Arca.Storage.locate(path) do
      :not_overlaid ->
        tenant_result

      :above_unit ->
        # A union answer needs both sides to have answered: absence is
        # already `{:ok, []}` on either side, so an error here is an
        # outage — answering the other side alone would be a plausible
        # listing that silently omits real entries.
        with {:ok, tenant_entries} <- tenant_result,
             {:ok, seed_entries} <- seed_list_typed(path) do
          names = MapSet.new(tenant_entries, fn {name, _kind} -> name end)

          merged =
            tenant_entries ++ Enum.reject(seed_entries, &MapSet.member?(names, elem(&1, 0)))

          {:ok, merged}
        end

      loc ->
        at_unit_result(ctx, loc, tenant_result, fn -> seed_list_typed(path) end)
    end
  end

  @impl true
  def list_recursive(%Context{} = ctx, path) do
    tenant_result = tenant().list_recursive(ctx, path)

    case Arca.Storage.locate(path) do
      :not_overlaid ->
        tenant_result

      :above_unit ->
        with {:ok, tenant_leaves} <- tenant_result,
             {:ok, seed_leaves} <- seed_list_recursive(path) do
          {:ok, Enum.uniq(merge_above_unit(ctx, tenant_leaves, seed_leaves, & &1))}
        end

      loc ->
        at_unit_result(ctx, loc, tenant_result, fn -> seed_list_recursive(path) end)
    end
  end

  # No read_subtree here: the facade's shared algorithm
  # (`Arca.Storage.read_subtree_via/4`) runs over this module's
  # `list_recursive/2` + `get/2`, so the union emerges compositionally.

  # ---------------------------------------------------------------------------
  # Unit status — the public questions the union can answer about itself.
  # `Compendium.Provenance` and the status/reset surfaces consume these.
  # ---------------------------------------------------------------------------

  @doc """
  What one shadow unit holds, as the union serves it — see
  `t:unit_status/0`. A path below a unit is answered for its unit; a path
  above any unit (or outside the overlaid roots) is `{:ok, :absent}`.
  A tenant-adapter outage answers `{:error, term}` — a status surface
  must not misreport the athanor's own units as shipped.
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
        seed? = seed_unit_present?(loc)

        with {:ok, state} <- tenant_unit_state(ctx, loc) do
          status =
            cond do
              state == :complete ->
                cond do
                  not seed? -> :own
                  origin_mark?(ctx, unit_of(loc)) -> :materialized
                  true -> :own_shadowing
                end

              seed? ->
                :seed

              state == :partial ->
                :own

              true ->
                :absent
            end

          {:ok, status}
        end
    end
  end

  @doc """
  Every unit under an overlaid root, mapped to its status — the batch form
  of `unit_status/2`: three listings total (tenant, seed, origin marks),
  no per-unit probes — classifying a leaf is a pure locator call.
  `:absent` units are, by definition, not in the map. A tenant listing
  outage answers `{:error, term}`, never a seed-only map.
  """
  @spec unit_statuses(Context.t(), String.t()) ::
          {:ok, %{Arca.Storage.path() => unit_status()}} | {:error, term()}
  def unit_statuses(%Context{} = ctx, root) when is_binary(root) do
    if root in Arca.Storage.overlay_roots() do
      with {:ok, tenant_leaves} <- tenant().list_recursive(ctx, [root]),
           {:ok, seed_leaves} <- seed_list_recursive([root]) do
        marks = origin_marks(ctx)

        seed_locs = MapSet.new(for leaf <- seed_leaves, loc = leaf_loc(leaf), do: loc)

        tenant_by_loc =
          tenant_leaves
          |> Enum.group_by(&Arca.Storage.locate/1)
          |> Map.drop([:above_unit, :not_overlaid])

        all_locs = MapSet.union(seed_locs, MapSet.new(Map.keys(tenant_by_loc)))

        statuses =
          Map.new(all_locs, fn loc ->
            unit = unit_of(loc)

            status =
              cond do
                completed_in_leaves?(loc, Map.get(tenant_by_loc, loc, [])) ->
                  cond do
                    not MapSet.member?(seed_locs, loc) -> :own
                    MapSet.member?(marks, unit) -> :materialized
                    true -> :own_shadowing
                  end

                MapSet.member?(seed_locs, loc) ->
                  :seed

                true ->
                  :own
              end

            {unit, status}
          end)

        {:ok, statuses}
      end
    else
      {:ok, %{}}
    end
  end

  @doc """
  How a unit's tenant copy differs from its seed counterpart, as relative
  paths: `added` (tenant-only), `removed` (seed-only), `changed` (both,
  bytes differ). The seed side is filtered by the same droppings exclusion
  materialization uses, so a pristine copy diffs empty. A file unit diffs
  as the single relative path `[]`. Memory-bounded to one unit — the same
  bound as materialization.
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
  # The revert verbs — the three product meanings of "make it go away",
  # so no product tool re-derives deletion policy from status atoms.
  # ---------------------------------------------------------------------------

  @doc """
  Revert a materialized copy so the shipped unit shows through again —
  what `component.reset` and `aqua.reset` mean. Only a `:materialized`
  unit reverts: the athanor's own work refuses as `{:error, :not_a_copy}`
  (`:own` and `:own_shadowing` alike — reset never destroys member work),
  an unmaterialized shipped unit as `{:error, :bundled}` (already
  pristine), nothing at all as `{:error, :not_found}`.
  """
  @spec revert_copy(Context.t(), Arca.Storage.path()) ::
          :ok | {:error, :not_a_copy | :bundled | :not_found | :not_overlaid | term()}
  def revert_copy(%Context{} = ctx, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        case unit_status(ctx, path) do
          {:ok, :materialized} -> delete_unit(ctx, loc)
          {:ok, own} when own in [:own, :own_shadowing] -> {:error, :not_a_copy}
          {:ok, :seed} -> {:error, :bundled}
          {:ok, :absent} -> {:error, :not_found}
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  Delete one unit the athanor holds — a materialized copy or its own
  work, explicitly (`aqua.delete`, `reset all: true`). Where a seed
  counterpart exists it shows through afterwards — deleting an
  `:own_shadowing` unit is how the shipped one is revealed. An
  unmaterialized shipped unit refuses as `{:error, :bundled}` (there is
  nothing of the athanor's to delete), nothing at all as
  `{:error, :not_found}`.
  """
  @spec drop_unit(Context.t(), Arca.Storage.path()) ::
          :ok | {:error, :bundled | :not_found | :not_overlaid | term()}
  def drop_unit(%Context{} = ctx, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        case unit_status(ctx, path) do
          {:ok, :seed} -> {:error, :bundled}
          {:ok, :absent} -> {:error, :not_found}
          {:ok, _materialized_or_own} -> delete_unit(ctx, loc)
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  Collapse a pristine copy: delete the tenant unit iff it is
  `:materialized` and `diff_unit/2` is empty — boot maintenance, so a
  byte-identical copy goes back to tracking the release. `:kept` when the
  copy has real edits or the unit is the athanor's own work, `:absent`
  when there is nothing materialized to collapse.
  """
  @spec collapse_unit(Context.t(), Arca.Storage.path()) ::
          :collapsed | :kept | :absent | {:error, term()}
  def collapse_unit(%Context{} = ctx, path) do
    case unit_status(ctx, path) do
      {:ok, :materialized} ->
        loc = Arca.Storage.locate(path)

        case diff_unit(ctx, unit_of(loc)) do
          {:ok, %{added: [], removed: [], changed: []}} ->
            case delete_unit(ctx, loc) do
              :ok -> :collapsed
              {:error, _} = error -> error
            end

          {:ok, _diff} ->
            :kept

          {:error, _} = error ->
            error
        end

      {:ok, own} when own in [:own, :own_shadowing] ->
        :kept

      {:ok, _seed_or_absent} ->
        :absent

      {:error, _} = error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Copy-on-write and the delete refusal
  # ---------------------------------------------------------------------------

  # A write inside an unmaterialized seed directory unit materializes the
  # whole unit first (droppings excluded, the storage cap asked about the
  # materialization bytes, the sentinel copied last). A write AT a file
  # unit that shadows a seed file for the first time records its origin
  # mark — before the put, so a crash in between leaves a mark without a
  # completed file, which every reader ignores (fails toward :seed). Only
  # the internal-write scope is exempt — that is what keeps the copy from
  # recursing.
  defp prepare_write(%Context{} = ctx, path) do
    if internal_writes?() do
      :ok
    else
      case Arca.Storage.locate(path) do
        loc when loc in [:not_overlaid, :above_unit] ->
          :ok

        {:file, unit} when unit == path ->
          loc = {:file, unit}

          if seed_unit_present?(loc) and not completed?(ctx, loc) do
            record_origin(ctx, unit)
          else
            :ok
          end

        {:file, _unit} ->
          # Below a file unit: a file has no interior to write into.
          {:error, :invalid_path}

        {:dir, unit, _sentinel} when unit == path ->
          # A put exactly at a directory unit would drop a file where the
          # unit's tree belongs.
          {:error, :invalid_path}

        {:dir, _unit, _sentinel} = loc ->
          cond do
            completed?(ctx, loc) -> :ok
            not seed_unit_present?(loc) -> :ok
            true -> materialize(ctx, loc)
          end
      end
    end
  end

  # Refuse deleting what the athanor does not own: `{:error, :bundled}`
  # for an unmaterialized seed path at or below its shadow unit. A
  # completed copy (or the athanor's own unit) deletes normally — and any
  # bundle shows through again. Only the internal-write scope is exempt
  # (its rollback deletes a partial, sentinel-less copy — exactly the
  # shape this refuses for everyone else).
  defp deletable(%Context{} = ctx, path) do
    if internal_writes?() do
      :ok
    else
      case Arca.Storage.locate(path) do
        loc when loc in [:not_overlaid, :above_unit] ->
          :ok

        loc ->
          if not completed?(ctx, loc) and seed_unit_present?(loc) do
            {:error, :bundled}
          else
            :ok
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # The inner tenant adapter — the configured one. This module is the
  # decorator the facade always wraps around it; configured as the
  # adapter itself it would recurse without bound, so refuse loudly.
  defp tenant do
    case Application.get_env(:cyfr, :storage_adapter, Arca.Adapters.Local) do
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

  # A leaf read falls through when the path could live in a seed unit the
  # athanor has not completed. Above-unit paths have no unit to shadow —
  # they fall through unconditionally.
  defp fall_through?(ctx, path) do
    case Arca.Storage.locate(path) do
      :not_overlaid -> false
      :above_unit -> true
      loc -> not completed?(ctx, loc)
    end
  end

  # The above-unit merge the leaf walks share: seed items are shadowed
  # where their unit holds a completed tenant copy, partial tenant copies
  # under a seed unit stay hidden, everything else unions.
  defp merge_above_unit(ctx, tenant_items, seed_items, full_path_fun) do
    classes = classify_tenant_units(ctx, Enum.map(tenant_items, full_path_fun))

    class_of = fn item ->
      case leaf_loc(full_path_fun.(item)) do
        nil -> nil
        loc -> classes[loc]
      end
    end

    fresh = Enum.reject(seed_items, &(class_of.(&1) == :completed))
    kept = Enum.reject(tenant_items, &(class_of.(&1) == :hidden))
    kept ++ fresh
  end

  # Classify each distinct tenant unit once, for the above-unit merges:
  # `:completed` (a complete copy — shadows the seed's leaves; whether it
  # is a marked copy or the athanor's own shadowing work, the tenant side
  # answers), `:hidden` (an uncompleted copy under a seed unit — the union
  # serves the seed, so the tenant's partial leaves must not surface or
  # double-list), `:own` (tenant-only — no seed counterpart, answers
  # as-is).
  defp classify_tenant_units(ctx, tenant_paths) do
    tenant_paths
    |> Enum.map(&leaf_loc/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
    |> Map.new(fn loc ->
      class =
        cond do
          completed?(ctx, loc) -> :completed
          seed_unit_present?(loc) -> :hidden
          true -> :own
        end

      {loc, class}
    end)
  end

  # The at-or-below-unit answer, shared by the listing merges: a completed
  # copy answers alone, an unmaterialized seed unit reads through, and a
  # tenant-only unit answers its own content. A tenant adapter fault
  # propagates before any probe — `:enotdir` is a real answer (a file
  # where the unit's tree belongs), everything else is an outage the seed
  # side must not paper over.
  defp at_unit_result(ctx, loc, tenant_result, seed_fun) do
    case tenant_result do
      {:error, reason} when reason != :enotdir ->
        tenant_result

      _answered ->
        cond do
          completed?(ctx, loc) -> tenant_result
          seed_unit_present?(loc) -> seed_fun.()
          true -> tenant_result
        end
    end
  end

  # The shadow test: is the athanor's copy of the unit COMPLETE? A
  # directory copy is complete when it holds its sentinel file; a file
  # unit when the tenant file exists. Asked of the tenant adapter
  # directly, on purpose — the union answering here would make every seed
  # unit look materialized. `exists?/2` is total by the adapter contract,
  # so these probes cannot carry an outage: they serve only the write
  # gates and leaf fall-through, whose failure directions are safe (a
  # refused delete, a materialization that fails typed, a read the
  # adapter just answered). Status surfaces ask `tenant_unit_state/2`
  # instead — the error-carrying form.
  defp completed?(ctx, {:file, unit}), do: tenant().exists?(ctx, unit)

  defp completed?(ctx, {:dir, unit, sentinel}),
    do: tenant().exists?(ctx, unit ++ [sentinel])

  # The status-surface probe: what the athanor's own tree holds at the
  # unit, with the error channel the total `exists?/2` probes cannot
  # carry — a status answer must not misreport a materialized unit as
  # `:seed` during an adapter outage. `:enotdir` is a real answer (a file
  # where a tree belongs): content, but never a complete copy.
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
  # (broken install media never materializes anyway).
  defp seed_unit_present?({:file, unit}), do: seed_exists?(unit)

  defp seed_unit_present?({:dir, unit, _sentinel}) do
    case seed_list_typed(unit) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp materialize(ctx, {:dir, unit_dir, sentinel}) do
    seed_dir = seed(unit_dir)

    with :ok <- seed_sentinel_present(seed_dir, sentinel),
         :ok <- check_cap(ctx, seed_dir) do
      # An internal context focused on the caller's athanor, writing back
      # THROUGH the facade so every copied byte passes the facade's usage
      # accounting like any other write. The user_id is attribution only —
      # the copy-on-write exemption is the lexical scope.
      internal =
        Sanctum.internal_context(
          user_id: "_overlay",
          athanor_id: ctx.athanor_id,
          scope: :athanor
        )

      copy =
        with_internal_writes(fn ->
          with :ok <-
                 Arca.copy_tree(internal, seed_dir, unit_dir,
                   exclude: &(excluded?(&1) or &1 == [sentinel])
                 ),
               # The completion mark: the sentinel lands last, so a crash
               # anywhere above leaves the unit reading as unmaterialized
               # and the next write re-copies over the partial remains.
               {:ok, bytes} <- seed_get(unit_dir ++ [sentinel]),
               :ok <- Arca.put(internal, unit_dir ++ [sentinel], bytes) do
            # The origin mark lands after the sentinel: mark present means
            # a completed COPY (a crash in between reads as the athanor's
            # own — the direction that never destroys its bytes).
            record_origin(internal, unit_dir)
          end
        end)

      case copy do
        :ok ->
          Logger.info(
            "[Arca.Overlay] materialized #{Enum.join(unit_dir, "/")} for #{ctx.athanor_id}"
          )

          :ok

        {:error, reason} ->
          with_internal_writes(fn -> rollback(ctx, unit_dir, reason) end)
          {:error, {:materialize_failed, reason}}
      end
    end
  end

  # A failed copy must not linger: without its sentinel the partial unit
  # already reads as unmaterialized, but its bytes would count against the
  # cap and confuse direct reads of paths the copy never reached. If the
  # rollback itself fails, the unit is stuck holding a partial copy — say
  # so loudly; the next successful materialization overwrites it.
  defp rollback(ctx, unit_dir, reason) do
    internal =
      Sanctum.internal_context(
        user_id: "_overlay",
        athanor_id: ctx.athanor_id,
        scope: :athanor
      )

    case Arca.delete_tree(internal, unit_dir) do
      :ok ->
        :ok

      {:error, rollback_reason} ->
        Logger.error(
          "[Arca.Overlay] materialization of #{Enum.join(unit_dir, "/")} failed " <>
            "(#{inspect(reason)}) AND its rollback failed (#{inspect(rollback_reason)}) — " <>
            "a partial copy remains until the next materialization overwrites it"
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

  # The write that triggers materialization is capped by its ingress; the
  # materialization bytes it drags in must not slip past the same cap.
  # The walk counts droppings the copy then excludes — an over-count in
  # the safe direction; CI keeps the seed free of droppings so it stays
  # theoretical.
  defp check_cap(ctx, seed_dir) do
    case Arca.Adapters.Local.usage(seed_ctx(), seed_dir) do
      {:ok, %{bytes: bytes}} -> Sanctum.Tenancy.Caps.check_storage(ctx, bytes)
      {:error, reason} -> {:error, {:materialize_failed, {:seed_usage, reason}}}
    end
  end

  # Through the facade, so accounting applies as for any caller; this
  # decorator's own delete callbacks clear the unit's origin mark.
  defp delete_unit(ctx, {:file, unit}), do: Arca.delete(ctx, unit)
  defp delete_unit(ctx, {:dir, unit, _sentinel}), do: Arca.delete_tree(ctx, unit)

  # ---------------------------------------------------------------------------
  # Origin marks
  # ---------------------------------------------------------------------------

  defp origin_mark_path(unit), do: @origin_root ++ unit

  defp origin_mark?(ctx, unit), do: tenant().exists?(ctx, origin_mark_path(unit))

  # The batch read: one listing, each leaf a marked unit. An unreadable
  # listing degrades every marked unit to :own_shadowing — visible, and
  # the direction that never destroys the athanor's bytes.
  defp origin_marks(ctx) do
    case tenant().list_recursive(ctx, @origin_root) do
      {:ok, mark_leaves} ->
        MapSet.new(mark_leaves, &Enum.drop(&1, length(@origin_root)))

      {:error, reason} ->
        Logger.warning(
          "[Arca.Overlay] origin marks unreadable for #{ctx.athanor_id}: #{inspect(reason)}"
        )

        MapSet.new()
    end
  end

  # One put records a mark, one delete clears it — no read-modify-write,
  # so concurrent materializations never lose each other's marks. Both
  # ride the internal-write scope: `meta/` is reserved, and the caller's
  # own context stays the author for accounting and audit.
  defp record_origin(ctx, unit) do
    result =
      with_internal_writes(fn ->
        Arca.put(ctx, origin_mark_path(unit), ~s({"origin":"seed"}))
      end)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Arca.Overlay] origin mark write failed for #{ctx.athanor_id} " <>
            "at #{Enum.join(unit, "/")}: #{inspect(reason)}"
        )

        {:error, {:origin_mark, reason}}
    end
  end

  # Clearing is best-effort against a delete that already succeeded: a
  # failure is loud (a stale mark could later misclassify the athanor's
  # own work as a copy) but does not un-delete anything.
  defp clear_origin(ctx, unit) do
    result =
      with_internal_writes(fn ->
        case Arca.delete(ctx, origin_mark_path(unit)) do
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
          "[Arca.Overlay] origin mark clear failed for #{ctx.athanor_id} " <>
            "at #{Enum.join(unit, "/")}: #{inspect(reason)} — " <>
            "a stale mark remains until the unit is next deleted"
        )

        :ok
    end
  end

  # After a delete_tree: a unit-level delete retires that unit's mark; a
  # wider delete inside an overlaid root retires every mark beneath it.
  # Non-overlaid paths (the whole-tree purge included — `meta/` goes with
  # the tree) have no marks to clear.
  defp clear_origin_after_delete_tree(ctx, path) do
    case Arca.Storage.locate(path) do
      {:file, unit} when unit == path ->
        clear_origin(ctx, unit)

      {:dir, unit, _sentinel} when unit == path ->
        clear_origin(ctx, unit)

      :above_unit ->
        with_internal_writes(fn ->
          case Arca.delete_tree(ctx, @origin_root ++ path) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.error(
                "[Arca.Overlay] origin mark sweep failed for #{ctx.athanor_id} " <>
                  "under #{Enum.join(path, "/")}: #{inspect(reason)}"
              )

              :ok
          end
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

  defp seed_ctx, do: Sanctum.system_context()
end
