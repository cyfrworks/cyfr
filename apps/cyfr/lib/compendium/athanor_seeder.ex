# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AthanorSeeder do
  @moduledoc """
  Seed an athanor with the bundled components — and keep it current.

  Component storage is athanor-scoped, so a brand-new athanor starts
  empty. `seed/1` copies the bundle in (`Compendium.Bundle`,
  `seed/components/`) — the `http`/`files` catalysts, the
  `aqua`/`list-models` formulas, sample tinctures — and the athanor's own
  scan registers the copies, giving every athanor the same working
  baseline.

  `sync/1` is the upgrade half: the bundle is the `local` namespace's
  upstream, the way the registry is upstream for published namespaces. A
  release that ships new component versions offers them additively — a
  version directory the athanor lacks is copied in and registered; one it
  already has is never touched, whatever its bytes, because the athanor's
  tree is the user's space. A user's self-published newer version simply
  stays the resolver's `latest`; an edited-in-place copy survives every
  sync and is reported as `modified` when its bytes have drifted from the
  shipped ones — the hook an updates surface reads. `seed/1` is `sync/1`
  on an empty tree, so both paths share one copy discipline.

  Seeding is idempotent and not best-effort: a copy failure is returned,
  and the caller decides what an athanor without its baseline means.
  """

  require Logger

  alias Compendium.{AutoIndexer, Bundle, ComponentPath}

  # Build droppings a checked-out bundle may carry (someone ran cargo or npm
  # inside a component's src/). Never part of a component; copying them would
  # bloat every athanor and count against its storage cap.
  @excluded_dirs ~w(target node_modules .git)

  @type report :: %{copied: [String.t()], present: [String.t()], modified: [String.t()]}

  @doc """
  Copy the bundle into the athanor and register it.

  Returns `:ok`, `{:error, :bundle_missing}` when the install has no bundle,
  or `{:error, reason}` on the first failed copy.
  """
  @spec seed(String.t() | %{id: String.t()}) :: :ok | {:error, term()}
  def seed(athanor) do
    with {:ok, _report} <- sync(athanor), do: :ok
  end

  @doc """
  Additively sync the bundle into the athanor.

  Bundle version directories the athanor lacks are copied (build droppings
  excluded) and, when anything was copied, the athanor's scan registers the
  arrivals. Version directories the athanor already has are never touched —
  they are reported `present`, or `modified` when their bytes no longer
  match the shipped ones. Returns `{:ok, report}` with each list holding
  `"{type}s/{publisher}/{name}/{version}"` entries, `{:error,
  :bundle_missing}`, or `{:error, reason}` on the first failed copy.

  Telling `present` from `modified` digests every byte of both trees, which
  only a caller actually reading the distinction should pay for — the boot
  sync passes `classify_drift: false` and gets everything already-there as
  `present`, no content reads.
  """
  @spec sync(String.t() | %{id: String.t()}, keyword()) :: {:ok, report()} | {:error, term()}
  def sync(athanor, opts \\ [])

  def sync(%{id: athanor_id}, opts), do: sync(athanor_id, opts)

  def sync(athanor_id, opts) when is_binary(athanor_id) and athanor_id != "" do
    classify_drift = Keyword.get(opts, :classify_drift, true)

    # A server-internal context working inside the athanor: the only kind of
    # context allowed to read the bundle, and the one whose scan registers
    # rows for this athanor alone.
    ctx =
      Sanctum.internal_context(
        user_id: "_seed",
        athanor_id: athanor_id,
        scope: :athanor
      )

    with :ok <- bundle_present(ctx),
         {:ok, report} <- sync_versions(ctx, classify_drift) do
      if report.copied != [], do: AutoIndexer.scan(ctx: ctx)
      {:ok, report}
    end
  end

  # An install without its bundle cannot provision anyone; say so rather than
  # minting an empty athanor.
  defp bundle_present(ctx) do
    case Arca.list_recursive(ctx, Bundle.bundle_prefix()) do
      {:ok, [_ | _]} -> :ok
      {:ok, []} -> {:error, :bundle_missing}
      {:error, reason} -> {:error, {:bundle_unreadable, reason}}
    end
  end

  # A type the bundle does not carry (no reagents shipped, say) lists empty
  # and syncs nothing.
  defp sync_versions(ctx, classify_drift) do
    Enum.reduce_while(Bundle.type_plurals(), {:ok, empty_report()}, fn type_plural, {:ok, acc} ->
      src = Bundle.bundle_prefix() ++ [type_plural, Bundle.publisher()]
      dest = ComponentPath.base_prefix() ++ [type_plural, Bundle.publisher()]

      case bundle_versions(ctx, src) do
        {:ok, versions} ->
          case sync_type(ctx, type_plural, src, dest, versions, acc, classify_drift) do
            {:ok, _} = ok -> {:cont, ok}
            {:error, _} = err -> {:halt, err}
          end

        {:error, reason} ->
          {:halt, {:error, {:bundle_unreadable, reason}}}
      end
    end)
  end

  defp empty_report, do: %{copied: [], present: [], modified: []}

  # The {name, version} directories the bundle ships under one type/publisher.
  # A shallow walk — names, then versions, then one listing per version —
  # never a recursive enumeration, which on a dev checkout would spell out
  # every path in a component's cargo `target/` droppings. A version
  # directory with no entries is skipped the way the old file-leaf walk
  # never surfaced it: copying nothing would still register a scan and a
  # dep pull, every boot. A file at the version level is not a version.
  defp bundle_versions(ctx, src) do
    with {:ok, names} <- list_dirs(ctx, src) do
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
        case non_empty_versions(ctx, src, name) do
          {:ok, versions} -> {:cont, {:ok, acc ++ Enum.map(versions, &{name, &1})}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp non_empty_versions(ctx, src, name) do
    with {:ok, versions} <- list_dirs(ctx, src ++ [name]) do
      Enum.reduce_while(versions, {:ok, []}, fn version, {:ok, acc} ->
        case Arca.list_typed(ctx, src ++ [name, version]) do
          {:ok, []} -> {:cont, {:ok, acc}}
          {:ok, _entries} -> {:cont, {:ok, acc ++ [version]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp list_dirs(ctx, prefix) do
    with {:ok, entries} <- Arca.list_typed(ctx, prefix) do
      {:ok, for({name, :dir} <- entries, do: name)}
    end
  end

  defp sync_type(ctx, type_plural, src, dest, versions, acc, classify_drift) do
    Enum.reduce_while(versions, {:ok, acc}, fn {name, version}, {:ok, acc} ->
      label = Enum.join([type_plural, Bundle.publisher(), name, version], "/")
      dest_dir = dest ++ [name, version]

      case Arca.list_typed(ctx, dest_dir) do
        {:ok, []} ->
          # Absent — the additive copy, filtered like the initial seed.
          case Arca.copy_tree(ctx, src ++ [name, version], dest_dir, exclude: &excluded?/1) do
            :ok ->
              {:cont, {:ok, update_in(acc.copied, &[label | &1])}}

            {:error, reason} ->
              Logger.warning("[AthanorSeeder] Failed to sync #{label}: #{inspect(reason)}")
              {:halt, {:error, {:seed_failed, label, reason}}}
          end

        {:ok, _entries} ->
          # The athanor's own — never overwritten; report drift so an
          # updates surface can tell "shipped" from "edited in place".
          key =
            if classify_drift and drifted?(ctx, src ++ [name, version], dest_dir),
              do: :modified,
              else: :present

          {:cont, {:ok, update_in(acc[key], &[label | &1])}}

        {:error, reason} ->
          {:halt, {:error, {:seed_failed, label, reason}}}
      end
    end)
  end

  defp excluded?(relative), do: Enum.any?(relative, &(&1 in @excluded_dirs))

  # Whether the athanor's copy of a version dir differs from the shipped
  # bytes. Both trees are small (a bundle component, droppings excluded);
  # this runs at boot and on demand, not on any hot path.
  defp drifted?(ctx, src_dir, dest_dir) do
    tree_digest(ctx, src_dir) != tree_digest(ctx, dest_dir)
  end

  defp tree_digest(ctx, prefix) do
    case Arca.list_recursive(ctx, prefix) do
      {:ok, leaves} ->
        leaves
        |> Enum.map(&Enum.drop(&1, length(prefix)))
        |> Enum.reject(&excluded?/1)
        |> Enum.sort()
        |> Enum.map(fn relative ->
          case Arca.get(ctx, prefix ++ relative) do
            {:ok, content} -> [Enum.join(relative, "/"), 0, content, 0]
            {:error, _} -> [Enum.join(relative, "/"), 0]
          end
        end)
        |> IO.iodata_to_binary()
        |> Cyfr.Digest.sha256()

      {:error, _} ->
        nil
    end
  end
end
