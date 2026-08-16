# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaTemplate do
  @moduledoc """
  The shipped AQUA agent definitions, and how an athanor gets its own copy.

  `aqua/agent.json` plus the prompt files it names are the template — a
  directory in the release (`:cyfr, :aqua_template_path`, the repo's
  `aqua/`). Every athanor owns a copy under its tenant storage
  (`data/{athanor_id}/aqua/`), written when the athanor is provisioned;
  the Agents page and the `aqua` tool then edit that copy, so a group's
  members shape their own agent without touching anyone else's.

  `ensure/1` is the self-healing entry the `aqua` tool uses: an athanor
  whose copy is missing gets the template on first read.
  """

  require Logger

  alias Sanctum.Context

  @manifest "agent.json"

  @doc "The template directory on disk."
  @spec template_path() :: String.t()
  def template_path do
    Application.fetch_env!(:cyfr, :aqua_template_path) |> Path.expand()
  end

  @doc "The template's files (`agent.json` first), relative to `template_path/0`."
  @spec files() :: [String.t()]
  def files do
    dir = template_path()

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(&1 == @manifest or String.ends_with?(&1, ".md")))
        |> Enum.filter(&File.regular?(Path.join(dir, &1)))
        |> Enum.sort_by(&(&1 != @manifest))

      {:error, _} ->
        []
    end
  end

  @doc """
  Copy the template into the context's athanor, overwriting whatever is
  there. Returns `{:error, :template_missing}` when the release ships no
  template.
  """
  @spec copy_into(Context.t()) :: :ok | {:error, term()}
  def copy_into(%Context{} = ctx) do
    Context.require_tenant!(ctx)

    case files() do
      [] ->
        {:error, :template_missing}

      names ->
        if @manifest in names do
          Enum.reduce_while(names, :ok, fn name, :ok ->
            content = File.read!(Path.join(template_path(), name))

            case Arca.put(ctx, ["aqua", name], content) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, {name, reason}}}
            end
          end)
        else
          {:error, :template_missing}
        end
    end
  end

  @doc """
  Give the athanor the template if it has no `agent.json` yet; a copy that
  exists is left alone. Returns `:ok` when a manifest is present afterwards.
  """
  @spec ensure(Context.t()) :: :ok | {:error, term()}
  def ensure(%Context{} = ctx) do
    if Arca.exists?(ctx, ["aqua", @manifest]) do
      :ok
    else
      case copy_into(ctx) do
        :ok ->
          Logger.info("[Compendium.AquaTemplate] seeded AQUA definitions for #{ctx.athanor_id}")
          :ok

        {:error, reason} = err ->
          Logger.warning(
            "[Compendium.AquaTemplate] could not seed #{ctx.athanor_id}: #{inspect(reason)}"
          )

          err
      end
    end
  end
end
