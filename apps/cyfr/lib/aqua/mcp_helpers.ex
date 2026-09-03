# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.MCPHelpers do
  @moduledoc """
  The seam between the assistant plane and the MCP tool surface — Aqua's
  `PrismWeb.MCPHelpers`.

  Aqua was the one domain namespace with a live tool-dispatch dependency
  and neither a helper nor a roster for it: `Aqua.Turn`,
  `Aqua.AgentConfig`, `Aqua.Actions` and the conversation runner each
  spelled their `Emissary.MCP.*` reaches themselves — the drift class
  `PrismWeb.ToolSeamTest` closed for the console. Every Emissary reach
  the assistant makes goes through here now, and `Aqua.ToolSeamTest`
  keeps it that way.

  Two deliberate exceptions live outside this module: `Emissary.PubSub`
  used as a process NAME (the application's one supervised PubSub), and
  `Aqua.Actions`' read of the console route table, rostered in
  `Cyfr.NamespaceDirectionTest`.
  """

  @doc "Call a tool on the external plane under `ctx`."
  @spec call_tool(String.t(), Sanctum.Context.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(tool, %Sanctum.Context{} = ctx, args) when is_binary(tool) and is_map(args) do
    Emissary.MCP.ToolRegistry.call_external(tool, ctx, args)
  end

  @doc "Call a tool on the in-chain plane, under the chain's `authority`."
  @spec call_in_chain(String.t(), Sanctum.Context.t(), map(), Sanctum.Authority.t()) ::
          {:ok, term()} | {:error, term()}
  def call_in_chain(tool, %Sanctum.Context{} = ctx, args, authority) do
    Emissary.MCP.ToolRegistry.call_in_chain(tool, ctx, args, authority)
  end

  @doc """
  The registry's `kind` annotation for `tool`/`action` — nil when the tool
  or the annotation is unknown, so the gap stays visible (the
  `Aqua.Actions.kind_for/2` rule: no `_default` fallback).
  """
  @spec action_kind(String.t(), String.t()) :: atom() | nil
  def action_kind(tool, action) do
    case Emissary.MCP.ToolRegistry.get_tool(tool) do
      {:ok, tool_def} -> Emissary.MCP.ActionAnnotations.kind(tool_def, action)
      _ -> nil
    end
  end

  @doc """
  The registry's `standing` annotation for `tool`/`action` — `:conversation`,
  `false`, or nil when the action declares none or the tool is unknown.
  """
  @spec action_standing(String.t(), String.t()) :: :conversation | false | nil
  def action_standing(tool, action) do
    case Emissary.MCP.ToolRegistry.get_tool(tool) do
      {:ok, tool_def} -> Emissary.MCP.ActionAnnotations.standing(tool_def, action)
      _ -> nil
    end
  end

  @doc "Whether a running chain would refuse `tool`/`action` (external-only plane)."
  @spec in_chain_refused?(String.t(), String.t()) :: boolean()
  def in_chain_refused?(tool, action),
    do: Emissary.MCP.ToolRegistry.in_chain_refused?(tool, action)

  @doc """
  One sentence for a refusal: the shared renderer first (crafted binaries,
  consent signals, the crash vocabulary — the same sentence everywhere),
  and an internal term sanitized BEFORE inspect — this text persists as a
  conversation message every member reads, and a flattened string is past
  the sanitizer's reach.
  """
  @spec render_refusal(term()) :: String.t()
  def render_refusal(reason) do
    Emissary.MCP.ToolError.render(reason) ||
      inspect(Sanctum.Sanitizer.sanitize(reason), limit: 20, printable_limit: 200)
  end
end
