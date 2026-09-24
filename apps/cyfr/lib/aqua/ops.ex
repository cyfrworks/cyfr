# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Ops do
  @moduledoc """
  The assistant's adapter onto the operation catalog — Aqua's
  `PrismWeb.Ops`.

  Provides the MCP dispatch operations used by the assistant domain.

  One deliberate exception lives outside this module: `Aqua.Intents`'
  read of the console route table, rostered in `Cyfr.Boundaries`. The
  assistant's live events go through `Cyfr.Bus`, the host's, never a
  surface.
  """

  @doc "Call a tool on the external plane under `ctx`."
  @spec call_tool(String.t(), Sanctum.Context.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(tool, %Sanctum.Context{} = ctx, args) when is_binary(tool) and is_map(args) do
    Grimoire.Catalog.call_external(tool, ctx, args)
  end

  @doc """
  Call a tool on the in-chain plane, under the chain's `authority`.

  `opts` are the registry's own (`:lineage` — the host-stamped execution
  and thread identity a tool may trust, guest-supplied spellings
  dropped); the helper forwards them so the runner can name a card's own
  execution without the argument map carrying it.
  """
  @spec call_in_chain(String.t(), Sanctum.Context.t(), map(), Prima.Authority.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call_in_chain(tool, %Sanctum.Context{} = ctx, args, authority, opts \\ []) do
    Grimoire.Catalog.call_in_chain(tool, ctx, args, authority, opts)
  end

  @doc """
  The registry's `kind` annotation for `tool`/`action` — nil when the tool
  or the annotation is unknown, so the gap stays visible (the
  `Aqua.Kinds.kind_for/2` rule: no `_default` fallback).
  """
  @spec action_kind(String.t(), String.t()) :: atom() | nil
  def action_kind(tool, action) do
    case Grimoire.Catalog.get_tool(tool) do
      {:ok, tool_def} -> Grimoire.Annotations.kind(tool_def, action)
      _ -> nil
    end
  end

  @doc "Stop the supervised handler of the in-chain call named by `handle`, started or not."
  @spec cancel_call(term()) :: :ok
  def cancel_call(handle), do: Grimoire.RunningTasks.cancel_handle(handle)

  @doc "Forget a call's cancellation handle once the loop is done with it."
  @spec release_call(term()) :: :ok
  def release_call(handle), do: Grimoire.RunningTasks.release_handle(handle)

  @doc """
  Whether `tool`/`action` is reviewed as safe to re-dispatch after an
  uncertain recovery (`recovery: :replay_safe`); false for an unknown
  tool or any other action.
  """
  @spec replay_safe?(String.t(), String.t()) :: boolean()
  def replay_safe?(tool, action) do
    case Grimoire.Catalog.get_tool(tool) do
      {:ok, tool_def} -> Grimoire.Annotations.recovery(tool_def, action) == :replay_safe
      _ -> false
    end
  end

  @doc """
  The registry's `standing` annotation for `tool`/`action` — `:thread`,
  `false`, or nil when the action declares none or the tool is unknown.
  """
  @spec action_standing(String.t(), String.t()) :: :thread | false | nil
  def action_standing(tool, action) do
    case Grimoire.Catalog.get_tool(tool) do
      {:ok, tool_def} -> Grimoire.Annotations.standing(tool_def, action)
      _ -> nil
    end
  end

  @doc """
  The action verbs a registry tool enumerates — its input schema's
  `action` enum — or `[]` for a tool the registry does not hold or one
  with no verbs. What a `tool.*` glob expands to.
  """
  @spec actions_of(String.t()) :: [String.t()]
  def actions_of(tool) when is_binary(tool) do
    case Grimoire.Catalog.get_tool(tool) do
      {:ok, tool_def} ->
        case get_in(tool_def, ["inputSchema", "properties", "action", "enum"]) do
          verbs when is_list(verbs) -> Enum.filter(verbs, &is_binary/1)
          _ -> []
        end

      _ ->
        []
    end
  end

  def actions_of(_tool), do: []

  @doc "Whether a running chain would refuse `tool`/`action` (nothing a chain can run)."
  @spec in_chain_refused?(String.t(), String.t()) :: boolean()
  def in_chain_refused?(tool, action),
    do: Grimoire.Catalog.in_chain_refused?(tool, action)

  @doc """
  Whether an approved `tool`/`action` is an execution the assistant runs
  as a CHILD of the card's authority rather than a catalog call: the host
  intercepts it for a running chain, and the assistant does the same for
  a card (`Aqua.Loop`).
  """
  @spec child_execution?(String.t(), String.t()) :: boolean()
  def child_execution?(tool, action), do: Grimoire.Catalog.host_intercepted?(tool, action)

  @doc """
  One sentence for a refusal: the shared renderer first (crafted binaries,
  consent signals, the crash vocabulary — the same sentence everywhere),
  and an internal term sanitized BEFORE inspect — this text persists as a
  thread message every member reads, and a flattened string is past
  the sanitizer's reach.
  """
  @spec render_refusal(term()) :: String.t()
  def render_refusal(reason) do
    case Grimoire.Error.render(reason) do
      nil -> inspect(Prima.Sanitizer.sanitize(reason), limit: 20, printable_limit: 200)
      sentence -> sentence
    end
  end
end
