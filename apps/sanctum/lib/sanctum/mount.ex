# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Mount do
  @moduledoc """
  A catalyst's login need mounted into the program row it is bound to.

  A program row with a kept home (`mcp_servers`, `home: "kept"`) has one
  folder, its own: the home's id is the row's id, made with the row and
  retired with it. The box that holds the home (the backends service)
  keeps what the program keeps there, under a uid of the home's own that
  it draws when it first makes the home, and no CYFR process can read it.
  A grant of a catalyst's login need binds the need to the row: the
  binding's value is the row's id.

  A consent offers a login need the athanor's own program rows that fit
  it (`programs/1`, `Prima.Manifest.Needs.fit/2`) and binds one by its id
  at its definition's digest, read again at the commit (`program/2`); a
  share is never offered for it.

  `orphaned_homes/1` is the read the programs controller makes of the
  same rows: the homes a box holds that no kept row holds any more.
  """

  alias Sanctum.Context

  @typedoc "A kept home's id: its program row's id."
  @type home_id :: String.t()

  @doc """
  The program rows of the context's athanor, the ones a login need's
  candidates are chosen from: `{:error, {:unavailable, "Programs"}}` when
  the store cannot answer, so an outage never reads as none; a context
  with no athanor has none.
  """
  @spec programs(Context.t()) :: {:ok, [map()]} | {:error, {:unavailable, String.t()}}
  def programs(%Context{} = ctx) do
    case Arca.McpServerStorage.list(Context.actor(ctx)) do
      {:ok, rows} -> {:ok, Enum.filter(rows, &(&1.transport == "program"))}
      {:error, :no_athanor} -> {:ok, []}
      {:error, _unanswered} -> {:error, {:unavailable, "Programs"}}
    end
  end

  @doc """
  The program row `row_id` of the context's athanor, as a binding names
  it; another athanor's row is not found.
  """
  @spec program(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def program(%Context{} = ctx, row_id) when is_binary(row_id),
    do: Arca.McpServerStorage.get_by_id(Context.actor(ctx), row_id)

  @doc """
  The grants that stand on the row `row` (`%{id, name}`) of `athanor_id`:
  the source of each profile there, not revoked, whose head binds the
  row to a login need or grants its tools
  (`Arca.ConsentStorage.head_profiles_on_row/2`, the same answer the
  row's delete blocks); sorted, each once. They are the grants a change
  or removal of the row asks again, which its confirmation names before
  it is given.
  `{:error, :unavailable}` when the store cannot answer.
  """
  @spec granted_to(String.t(), %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          optional(atom()) => term()
        }) ::
          {:ok, [String.t()]} | {:error, :unavailable}
  def granted_to(athanor_id, %{id: id, name: name} = row)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) and is_binary(name) do
    actor = Prima.Actor.in_athanor(athanor_id)

    with {:ok, ids} <- Arca.ConsentStorage.head_profiles_on_row(actor, row),
         {:ok, profiles} <- profiles(actor, ids) do
      sources =
        for %{status: status, source_ref: source} <- profiles, status != "revoked", do: source

      {:ok, Enum.sort(Enum.uniq(sources))}
    else
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp profiles(actor, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, read} ->
      case Arca.ProfileStorage.get(actor, id) do
        {:ok, profile} -> {:cont, {:ok, [profile | read]}}
        {:error, :not_found} -> {:cont, {:ok, read}}
        {:error, _unanswered} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Which of the kept homes `home_ids` (a box's) no program row keeps any
  more, with the athanor each was its row's (nil for a row that is gone):
  its row deleted, no longer a program with a kept home, or its athanor
  archived. The positive evidence the programs controller retires a home
  on; a home whose row stands is not named. `{:error, :unavailable}` when
  the store cannot answer, so the sweep retires nothing and asks again
  later.
  """
  @spec orphaned_homes([home_id()]) ::
          {:ok, [{home_id(), String.t() | nil}]} | {:error, :unavailable}
  def orphaned_homes(home_ids) when is_list(home_ids) do
    case Arca.McpServerStorage.standing(home_ids) do
      {:ok, standing} ->
        orphans =
          Enum.flat_map(home_ids, fn id ->
            case orphaned(Map.get(standing, id)) do
              :stands -> []
              athanor_id -> [{id, athanor_id}]
            end
          end)

        {:ok, orphans}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp orphaned(nil), do: nil
  defp orphaned(%{kept: true, athanor_archived: false}), do: :stands
  defp orphaned(%{athanor_id: athanor_id}), do: athanor_id
end
