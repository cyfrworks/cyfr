# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaTemplate do
  @moduledoc """
  The shipped AQUA tree — seed media under the reserved `seed/aqua` root
  (`Arca.Storage.seed_roots/0`), read in place from the seed tree: the
  repo's `seed/aqua/` on a checkout, the operator-editable `/app/seed/aqua`
  mount in Docker.

  Provisioning copies the shipped tree into the athanor's `aqua/`
  (`Arca.Overlay`); from then on the athanor's files are its own, and the
  seed is the default a reset copies in again. A release that ships new
  roles or scrolls changes nothing until a reset asks for them.

  What remains here is the seed-side surface: `seed_check/0` (is the
  install's template well-formed — provisioning fails loud on a mount
  with no soul), `files/0` (what the seed ships), `status/1` (each unit's
  provenance, from the overlay), and `reset/2` (restore edited copies of
  shipped units and pull shipped units the athanor lacks; member-created
  roles and scrolls are kept unless `all: true` deletes them too).
  """

  require Logger

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Sanctum.Context

  @seed_prefix Arca.Storage.seed_prefix("aqua")

  @doc "The template's seed segments: `[\"seed\", \"aqua\"]`."
  @spec seed_prefix() :: [String.t()]
  def seed_prefix, do: @seed_prefix

  @doc """
  Whether the install ships a well-formed template: a soul file that
  parses, and roles (optional) that each parse. Fails loud with a reason,
  so an operator who mounted a broken tree learns it at boot, not from an
  empty roster.
  """
  @spec seed_check() :: :ok | {:error, term()}
  def seed_check do
    ctx = Sanctum.system_context()

    with {:ok, _soul} <- seed_soul(ctx),
         {:ok, _roles} <- seed_roles(ctx) do
      :ok
    end
  end

  @doc """
  The files the seed ships, as paths relative to the aqua root — only what
  the tree's grammar recognises as a unit (the soul, `roles/*.md`, the
  scrolls). A seed that cannot be listed answers
  nothing, and says so in the log — a silent empty list reads as "the
  install ships no files", which is never true.
  """
  @spec files() :: [[String.t()]]
  def files do
    case Arca.list_recursive(Prima.Actor.system(), @seed_prefix) do
      {:ok, leaves} ->
        leaves
        |> Enum.map(&Enum.drop(&1, length(@seed_prefix)))
        |> Enum.filter(&(AquaPath.locate(AquaPath.root() ++ &1) != :above_unit))

      {:error, reason} ->
        Logger.error(
          "[Compendium.AquaTemplate] the seed tree could not be listed: #{inspect(reason)}"
        )

        []
    end
  end

  @doc """
  Each aqua unit the athanor holds, in the one provenance vocabulary
  (`Compendium.Provenance`): `:bundled` (a copy of what ships, byte for
  byte), `:bundled_modified` (the athanor wrote into its copy), `:user`
  (member-created). A shipped unit the athanor does not hold is not the
  athanor's and is not listed.
  """
  @spec status(Context.t()) ::
          {:ok, [%{path: String.t(), state: Compendium.Provenance.t()}]} | {:error, term()}
  def status(%Context{} = ctx) do
    with {:ok, statuses} <- Arca.Overlay.unit_statuses(Sanctum.Context.actor(ctx), "aqua") do
      statuses
      |> Enum.sort_by(fn {unit, _state} -> unit end)
      |> Enum.reduce_while({:ok, []}, fn {unit, state}, {:ok, acc} ->
        case unit_provenance(ctx, unit, state) do
          {:ok, nil} -> {:cont, {:ok, acc}}
          {:ok, state} -> {:cont, {:ok, [%{path: Enum.join(unit, "/"), state: state} | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, files} -> {:ok, Enum.reverse(files)}
        error -> error
      end
    end
  end

  # A held copy is bundled or edited by its bytes; the athanor's own is
  # the athanor's; what it does not hold is not listed.
  defp unit_provenance(ctx, unit, :shipped) do
    with {:ok, edited?} <- Arca.Overlay.edited?(Sanctum.Context.actor(ctx), unit) do
      {:ok, if(edited?, do: :bundled_modified, else: :bundled)}
    end
  end

  defp unit_provenance(_ctx, _unit, :own), do: {:ok, :user}
  defp unit_provenance(_ctx, _unit, _available_or_absent), do: {:ok, nil}

  @doc """
  Reset the aqua tree to what ships: every edited copy of a shipped unit
  is restored to the shipped bytes, and every shipped unit the athanor
  does not hold is copied in. By default member-created agents and skills
  are KEPT and reported; `all: true` deletes them too, so the tree is
  exactly the shipped set. Either way the template's presence is checked
  before anything changes: a broken install refuses rather than destroys.
  """
  @spec reset(Context.t(), keyword()) ::
          {:ok, %{reverted: [String.t()], kept: [String.t()]}} | {:error, term()}
  def reset(%Context{} = ctx, opts \\ []) do
    Context.require_tenant!(ctx)
    all? = Keyword.get(opts, :all, false)

    with :ok <- seed_check(),
         {:ok, statuses} <- Arca.Overlay.unit_statuses(Sanctum.Context.actor(ctx), "aqua") do
      statuses
      |> Enum.sort_by(fn {unit, _state} -> unit end)
      |> Enum.reduce_while({:ok, %{reverted: [], kept: []}}, fn {unit, state}, {:ok, acc} ->
        name = Enum.join(unit, "/")

        case reset_unit(ctx, unit, state, all?) do
          :reverted -> {:cont, {:ok, %{acc | reverted: acc.reverted ++ [name]}}}
          :kept -> {:cont, {:ok, %{acc | kept: acc.kept ++ [name]}}}
          :unchanged -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc """
  Restore one shipped unit — the soul, a role or a scroll — to the
  shipped bytes, whatever the athanor wrote into its copy; a shipped unit
  the athanor lacks is copied in. `{:error, :not_a_copy}` when the
  athanor made the unit itself, `{:error, :not_found}` when neither the
  athanor nor the seed has it.
  """
  @spec restore(Context.t(), Arca.Storage.path()) ::
          :ok | {:error, :not_a_copy | :not_found | term()}
  def restore(%Context{} = ctx, unit) do
    Context.require_tenant!(ctx)

    with :ok <- seed_check(),
         {:ok, status} <- Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), unit) do
      case status do
        held_or_offered when held_or_offered in [:shipped, :available] ->
          Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), unit)

        :own ->
          {:error, :not_a_copy}

        :absent ->
          {:error, :not_found}
      end
    end
  end

  # One unit's part of a reset: an edited copy is restored, a shipped unit
  # the athanor lacks is copied in, and the athanor's own work is kept —
  # or, with `all: true`, deleted so the shipped set is all that remains.
  defp reset_unit(ctx, unit, :shipped, _all?) do
    case Arca.Overlay.edited?(Sanctum.Context.actor(ctx), unit) do
      {:ok, true} -> outcome(Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), unit))
      {:ok, false} -> :unchanged
      {:error, _} = error -> error
    end
  end

  defp reset_unit(ctx, unit, :available, _all?),
    do: outcome(Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), unit))

  defp reset_unit(ctx, unit, :own, true) do
    case Arca.Overlay.drop_unit(Sanctum.Context.actor(ctx), unit) do
      {:ok, :deleted} -> :reverted
      {:error, :not_found} -> :unchanged
      {:error, _} = error -> error
    end
  end

  defp reset_unit(_ctx, _unit, :own, false), do: :kept
  defp reset_unit(_ctx, _unit, :absent, _all?), do: :unchanged

  defp outcome(:ok), do: :reverted
  defp outcome({:error, _} = error), do: error

  # The seed's soul and roles, parsed with the same format module the
  # athanor's union reads them with. No roster rule beyond "each file
  # parses": there is one soul by construction, and a role has no parent
  # to resolve.
  defp seed_soul(ctx) do
    case Arca.get(Sanctum.Context.actor(ctx), @seed_prefix ++ [List.last(AquaPath.soul_file())]) do
      {:ok, binary} ->
        case AquaAgent.parse(AquaPath.soul_name(), binary) do
          {:ok, soul} -> {:ok, soul}
          {:error, reason} -> {:error, {:seed_soul_invalid, reason}}
        end

      {:error, :not_found} ->
        {:error, :template_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seed_roles(ctx) do
    case Arca.list_typed(Sanctum.Context.actor(ctx), @seed_prefix ++ [AquaPath.roles_dirname()]) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn {file, kind} -> kind == :file and String.ends_with?(file, ".md") end)
        |> Enum.map(fn {file, _kind} -> String.trim_trailing(file, ".md") end)
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
          with {:ok, binary} <-
                 Arca.get(
                   Sanctum.Context.actor(ctx),
                   @seed_prefix ++ [AquaPath.roles_dirname(), name <> ".md"]
                 ),
               {:ok, role} <- AquaAgent.parse(name, binary) do
            {:cont, {:ok, [role | acc]}}
          else
            {:error, reason} -> {:halt, {:error, {:seed_role_invalid, name, reason}}}
          end
        end)

      {:error, :not_found} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
