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
    Sanctum.Gate.call_external(tool, ctx, args)
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
    Sanctum.Gate.call_in_chain(tool, ctx, args, authority, opts)
  end

  @doc """
  The registry's `kind` annotation for `tool`/`action` — nil when the tool
  or the annotation is unknown, so the gap stays visible (no `_default`
  fallback). A catalogued tool's kind alone: `Sanctum.Catalog.tool_kind/2` also
  classifies the virtual hands and the external namespace.
  """
  @spec action_kind(String.t(), String.t()) :: atom() | nil
  def action_kind(tool, action) do
    case Sanctum.Catalog.get_tool(tool) do
      {:ok, tool_def} -> Sanctum.Annotations.kind(tool_def, action)
      _ -> nil
    end
  end

  @doc "Stop the supervised handler of the in-chain call named by `handle`."
  @spec cancel_call(term()) :: :ok
  def cancel_call(handle), do: Sanctum.RunningTasks.cancel_handle(handle)

  @doc "Forget a call's cancellation handle once the loop is done with it."
  @spec release_call(term()) :: :ok
  def release_call(handle), do: Sanctum.RunningTasks.release_handle(handle)

  @doc """
  Whether `tool`/`action` is reviewed as safe to re-dispatch after an
  uncertain recovery (`recovery: :replay_safe`); false for an unknown
  tool or any other action.
  """
  @spec replay_safe?(String.t(), String.t()) :: boolean()
  def replay_safe?(tool, action) do
    case Sanctum.Catalog.get_tool(tool) do
      {:ok, tool_def} -> Sanctum.Annotations.recovery(tool_def, action) == :replay_safe
      _ -> false
    end
  end

  @doc """
  The registry's `standing` annotation for `tool`/`action` — `:thread`,
  `false`, or nil when the action declares none or the tool is unknown.
  """
  @spec action_standing(String.t(), String.t()) :: :thread | false | nil
  def action_standing(tool, action) do
    case Sanctum.Catalog.get_tool(tool) do
      {:ok, tool_def} -> Sanctum.Annotations.standing(tool_def, action)
      _ -> nil
    end
  end

  @doc "Whether a running chain would refuse `tool`/`action` (nothing a chain can run)."
  @spec in_chain_refused?(String.t(), String.t()) :: boolean()
  def in_chain_refused?(tool, action),
    do: Sanctum.Catalog.in_chain_refused?(tool, action)

  @doc """
  Whether an approved `tool`/`action` is an execution the assistant runs
  as a CHILD of the card's authority rather than a catalog call: the host
  intercepts it for a running chain, and the assistant does the same for
  a card (`Aqua.Loop`).
  """
  @spec child_execution?(String.t(), String.t()) :: boolean()
  def child_execution?(tool, action), do: Sanctum.Catalog.host_intercepted?(tool, action)

  @doc """
  One sentence for a refusal: the gate's renderer (`Sanctum.Refusals.render/1`),
  the same sentence everywhere — this text persists as a thread message
  every member reads, so an internal term is never spelled into it.
  """
  @spec render_refusal(term()) :: String.t()
  def render_refusal(reason), do: Sanctum.Refusals.render(reason)
end
