# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaTemplate do
  @moduledoc """
  The shipped AQUA tree — seed media under the reserved `seed/aqua` root
  (`Arca.Storage.seed_roots/0`), read in place from the seed tree: the
  repo's `seed/aqua/` on a checkout, the operator-editable `/app/seed/aqua`
  mount in Docker.

  Provisioning copies nothing: the athanor's `aqua/` is served through the
  seed overlay (`Arca.Overlay`, per-file shadow units), so every agent and
  skill the seed ships is visible immediately, an edited file shadows only
  itself, an unedited one tracks the operator's mount live, and deleting an
  edited copy reverts it to shipped. Upgrades are therefore per-file and
  automatic — the digest-stamp machinery this module used to carry is gone
  with the copies it compared.

  What remains here is the seed-side surface: `seed_check/0` (is the
  install's template well-formed — provisioning fails loud on a v2 or
  empty mount), `files/0` (what the seed ships), `status/1` (each unit's
  drift, from the overlay), and `reset/2` (revert edited copies of
  shipped units; member-created agents and skills are kept unless
  `all: true` deletes the whole upper layer).
  """

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Sanctum.Context

  @seed_prefix Arca.Storage.seed_prefix("aqua")

  @doc "The template's seed segments: `[\"seed\", \"aqua\"]`."
  @spec seed_prefix() :: [String.t()]
  def seed_prefix, do: @seed_prefix

  @doc """
  Whether the install ships a well-formed v3 template: an `agents/`
  directory whose files parse and pass roster validation (at least one
  orchestrator, one default, parents resolve). Fails loud with a reason —
  a v2-shaped mount (`agent.json` at the root) gets a pointed message, so
  an operator who mounted an old tree learns it at boot, not from an
  empty roster.
  """
  @spec seed_check() :: :ok | {:error, term()}
  def seed_check do
    ctx = Sanctum.system_context()

    cond do
      Arca.exists?(ctx, @seed_prefix ++ ["agent.json"]) ->
        {:error, :seed_is_v2_shaped}

      true ->
        case seed_roster() do
          {:ok, _roster} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "The files the seed ships, as paths relative to the aqua root."
  @spec files() :: [[String.t()]]
  def files do
    case Arca.list_recursive(Sanctum.system_context(), @seed_prefix) do
      {:ok, leaves} -> Enum.map(leaves, fn ["seed", "aqua" | rest] -> rest end)
      {:error, _} -> []
    end
  end

  @doc """
  Each aqua shadow unit's state, in the one provenance vocabulary
  (`Compendium.Provenance.of_status/1`): `:bundled` (reads come from the
  seed), `:bundled_modified` (the athanor's copy shadows a shipped
  counterpart), `:user` (member-created, no shipped counterpart).
  """
  @spec status(Context.t()) ::
          {:ok, [%{path: String.t(), state: Compendium.Provenance.t()}]} | {:error, term()}
  def status(%Context{} = ctx) do
    with {:ok, statuses} <- Arca.Overlay.unit_statuses(ctx, "aqua") do
      {:ok,
       statuses
       |> Enum.map(fn {unit, state} ->
         %{path: Enum.join(unit, "/"), state: Compendium.Provenance.of_status(state)}
       end)
       |> Enum.sort_by(& &1.path)}
    end
  end

  @doc """
  Revert the aqua tree to shipped. By default only edited copies of
  shipped units revert — member-created agents and skills are KEPT and
  reported. `all: true` deletes the whole `aqua/` upper layer, the
  member's own units included, so the seed shows through whole. Either
  way the template's presence is checked before anything is deleted: a
  broken install refuses rather than destroys.
  """
  @spec reset(Context.t(), keyword()) ::
          {:ok, %{reverted: [String.t()], kept: [String.t()]}} | {:error, term()}
  def reset(%Context{} = ctx, opts \\ []) do
    Context.require_tenant!(ctx)

    with :ok <- seed_check(),
         {:ok, statuses} <- Arca.Overlay.unit_statuses(ctx, "aqua") do
      if Keyword.get(opts, :all, false) do
        with :ok <- Arca.delete_tree(ctx, AquaPath.root()) do
          gone = for {unit, state} <- statuses, state != :seed, do: Enum.join(unit, "/")
          {:ok, %{reverted: Enum.sort(gone), kept: []}}
        end
      else
        statuses
        |> Enum.sort_by(fn {unit, _state} -> unit end)
        |> Enum.reduce_while({:ok, %{reverted: [], kept: []}}, fn
          {unit, :materialized}, {:ok, acc} ->
            case Arca.Overlay.revert_copy(ctx, unit) do
              :ok ->
                {:cont, {:ok, %{acc | reverted: acc.reverted ++ [Enum.join(unit, "/")]}}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end

          {unit, own}, {:ok, acc} when own in [:own, :own_shadowing] ->
            {:cont, {:ok, %{acc | kept: acc.kept ++ [Enum.join(unit, "/")]}}}

          {_unit, :seed}, {:ok, acc} ->
            {:cont, {:ok, acc}}
        end)
      end
    end
  end

  # The seed's own roster, parsed and validated exactly the way the
  # athanor's union roster is — same format module, same rules.
  defp seed_roster do
    ctx = Sanctum.system_context()

    case Arca.list_typed(ctx, @seed_prefix ++ ["agents"]) do
      {:ok, entries} ->
        agents =
          entries
          |> Enum.filter(fn {file, kind} -> kind == :file and String.ends_with?(file, ".md") end)
          |> Enum.map(fn {file, _kind} -> String.trim_trailing(file, ".md") end)
          |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
            with {:ok, binary} <- Arca.get(ctx, @seed_prefix ++ ["agents", name <> ".md"]),
                 {:ok, agent} <- AquaAgent.parse(name, binary) do
              {:cont, {:ok, [agent | acc]}}
            else
              {:error, reason} -> {:halt, {:error, {:seed_agent_invalid, name, reason}}}
            end
          end)

        with {:ok, list} <- agents do
          validate_seed_roster(Enum.reject(list, & &1.disabled))
        end

      {:error, _} ->
        {:error, :template_missing}
    end
  end

  defp validate_seed_roster([]), do: {:error, :template_missing}

  defp validate_seed_roster(agents) do
    orchestrators = Enum.filter(agents, &(&1.role == :orchestrator))
    defaults = Enum.filter(orchestrators, & &1.default)

    cond do
      orchestrators == [] -> {:error, :no_orchestrator}
      length(orchestrators) == 1 -> {:ok, agents}
      length(defaults) == 1 -> {:ok, agents}
      defaults == [] -> {:error, :no_default_orchestrator}
      true -> {:error, :multiple_default_orchestrators}
    end
  end
end
