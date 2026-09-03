# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaTemplate do
  @moduledoc """
  The shipped AQUA tree — seed media under the reserved `seed/aqua` root
  (`Arca.Storage.seed_roots/0`), read in place from the seed tree: the
  repo's `seed/aqua/` on a checkout, the operator-editable `/app/seed/aqua`
  mount in Docker.

  Provisioning copies nothing: the athanor's `aqua/` is served through the
  seed overlay (`Arca.Overlay`, per-file shadow units), so the soul, every
  role and every scroll the seed ships is visible immediately, an edited
  file shadows only itself, an unedited one tracks the operator's mount
  live, and deleting an edited copy reverts it to shipped. Upgrades are
  therefore per-file and automatic — the digest-stamp machinery this
  module used to carry is gone with the copies it compared.

  What remains here is the seed-side surface: `seed_check/0` (is the
  install's template well-formed — provisioning fails loud on a mount
  with no soul), `files/0` (what the seed ships), `status/1` (each unit's
  drift, from the overlay), and `reset/2` (revert edited copies of
  shipped units; member-created roles and scrolls are kept unless
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
  Whether the install ships a well-formed template: a soul file that
  parses, and roles (optional) that each parse. Fails loud with a reason
  — an older shape (`agents/` with no soul beside it, or a v2 `agent.json`)
  gets a pointed message, so an operator who mounted an old tree learns it
  at boot, not from an empty roster.
  """
  @spec seed_check() :: :ok | {:error, term()}
  def seed_check do
    ctx = Sanctum.system_context()

    cond do
      Arca.exists?(ctx, @seed_prefix ++ ["agent.json"]) ->
        {:error, :seed_is_v2_shaped}

      true ->
        with {:ok, _soul} <- seed_soul(ctx),
             {:ok, _roles} <- seed_roles(ctx) do
          :ok
        end
    end
  end

  @doc """
  The files the seed ships, as paths relative to the aqua root — only what
  the tree's grammar recognises as a unit (the soul, `roles/*.md`, the
  scrolls). A mount that still carries an older shape beside the shipped
  one is not what the seed ships.
  """
  @spec files() :: [[String.t()]]
  def files do
    case Arca.list_recursive(Sanctum.system_context(), @seed_prefix) do
      {:ok, leaves} ->
        leaves
        |> Enum.map(&Enum.drop(&1, length(@seed_prefix)))
        |> Enum.filter(fn rel ->
          hd(rel) != "agents" and AquaPath.locate(AquaPath.root() ++ rel) != :above_unit
        end)

      {:error, _} ->
        []
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
        # Unit by unit, not one `delete_tree` on the aqua root. That root is
        # ABOVE units, so `Arca.Overlay`'s lock does not cover it — the
        # decorator locks a unit, and locking every unit beneath a tree
        # would mean taking them in an order two processes could invert.
        # `drop_unit/2` takes each unit's own lock in turn, so a reset can
        # no longer land inside a concurrent `commit_unit/4` and leave a
        # skill holding its manifest and nothing else.
        statuses
        |> Enum.sort_by(fn {unit, _state} -> unit end)
        |> Enum.reduce_while({:ok, []}, fn
          {_unit, :seed}, acc ->
            {:cont, acc}

          {unit, _state}, {:ok, gone} ->
            case Arca.Overlay.drop_unit(ctx, unit) do
              {:ok, _} -> {:cont, {:ok, gone ++ [Enum.join(unit, "/")]}}
              {:error, :not_found} -> {:cont, {:ok, gone}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end)
        |> case do
          {:ok, gone} -> {:ok, %{reverted: Enum.sort(gone), kept: []}}
          error -> error
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

  # The seed's soul and roles, parsed with the same format module the
  # athanor's union reads them with. No roster rule beyond "each file
  # parses": there is one soul by construction, and a role has no parent
  # to resolve.
  defp seed_soul(ctx) do
    case Arca.get(ctx, @seed_prefix ++ [List.last(AquaPath.soul_file())]) do
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
    case Arca.list_typed(ctx, @seed_prefix ++ [AquaPath.roles_dirname()]) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn {file, kind} -> kind == :file and String.ends_with?(file, ".md") end)
        |> Enum.map(fn {file, _kind} -> String.trim_trailing(file, ".md") end)
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
          with {:ok, binary} <-
                 Arca.get(ctx, @seed_prefix ++ [AquaPath.roles_dirname(), name <> ".md"]),
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
