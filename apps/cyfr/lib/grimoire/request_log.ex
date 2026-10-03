# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.RequestLog do
  @moduledoc """
  The MCP request log's rows, as projections of admission decisions.

  One row per recorded call, so a chain is legible: the `execution.run`
  an ingress received, and each tool the running component reached from
  inside the sandbox. `id` is the call — the decision's call id — and
  `request_id` is the ingress request they share.

  A row is never written on its own. `Grimoire.Decisions.open/3` appends
  the decision with the start row this module builds (`opened/3`), and
  `Grimoire.Decisions.close/3` records the completion with the columns
  this module builds (`closed/2`), each in the decision's own transaction
  (`Arca.DecisionLog`): the row and the decision cannot disagree.

  A row's meaning is its decision's: a refused call carries the
  refusal's `refusal_class`, a failed one its sentence, and the decision
  carries the completion's class. A JSON-RPC error code is a transport's
  rendering of a class, which the gate cannot name, so a row the gate
  writes leaves `error_code` empty.

  Every row is filed under the athanor the call ran in. A decision without
  an athanor — a caller refused before any tenant was resolved, a platform
  context working in none — has no tenant to file a row under, so it has
  the decision alone. A public tincture's calls carry the tincture's
  athanor.

  ## Sensitive Data

  Input parameters are sanitized to redact passwords, secrets, tokens and
  API keys before they are stored, and so is the structure inside a
  result's text blocks.
  """

  alias Prima.Decision
  alias Sanctum.Context

  # ============================================================================
  # Projections
  # ============================================================================

  @doc """
  The start row that projects `decision`, or nil when it has no tenant.

  `projection` carries what the decision does not: `:method` (default
  `"tools/call"`) and `:input` (sanitized and encoded here). An admitted
  decision's row is `"pending"`; a refused one's is closed at once as
  `"error"`, with the refusal's class and its rendered reason.
  """
  @spec opened(Context.t() | nil, Decision.t(), map()) :: map() | nil
  def opened(%Context{athanor_id: athanor_id} = ctx, %Decision{} = decision, projection)
      when is_binary(athanor_id) and athanor_id != "" and is_map(projection) do
    row = %{
      id: decision.call_id,
      request_id: decision.request_id,
      user_id: ctx.user_id || "system",
      timestamp: decision.inserted_at,
      tool: decision.tool,
      action: decision.action,
      method: Map.get(projection, :method) || "tools/call",
      input: encode_json(sanitize_input(Map.get(projection, :input) || %{}))
    }

    case decision.admission do
      :admitted ->
        Map.put(row, :status, "pending")

      :refused ->
        Map.merge(row, %{
          status: "error",
          refusal_class: Atom.to_string(decision.refusal_class),
          error: decision.reason
        })
    end
  end

  def opened(_ctx, %Decision{}, projection) when is_map(projection), do: nil

  @doc """
  The completion columns of a call's row: `"success"` with its sanitized
  output, or `"error"` with the refusal's sentence (`text`, rendered by the
  caller from the reason). `:duration_ms` and `:routed_to` label either;
  an absent one is left as the row has it.
  """
  @spec closed({:ok, term()} | {:error, String.t()}, map()) :: map()
  def closed({:ok, output}, meta) when is_map(meta) do
    %{status: "success", output: encode_json(sanitize_output(output))}
    |> labelled(meta, [:duration_ms, :routed_to])
  end

  def closed({:error, text}, meta) when is_binary(text) and is_map(meta) do
    %{status: "error", error: text}
    |> labelled(meta, [:duration_ms, :routed_to])
  end

  defp labelled(columns, meta, keys) do
    Enum.reduce(keys, columns, fn key, acc ->
      case Map.get(meta, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # ============================================================================
  # Input Sanitization
  # ============================================================================

  @doc """
  Sanitize input data to redact sensitive values.

  Delegates to `Prima.Sanitizer.sanitize/1`.
  """
  @spec sanitize_input(term()) :: term()
  defdelegate sanitize_input(input), to: Prima.Sanitizer, as: :sanitize

  # The tools/call wire shape re-encodes the tool's structured result as an
  # opaque JSON string under `"content"[]."text"`. Key-based redaction cannot
  # see inside a string, so a credential a tool legitimately returns to its
  # caller (a created API key, a webhook secret, a session token) would be
  # persisted verbatim. Decode each text block that parses as JSON, sanitize
  # the structure, and re-encode; prose text passes through untouched. The
  # client response is built before logging and is never affected.
  defp sanitize_output(nil), do: nil

  defp sanitize_output(%{"content" => blocks} = output) when is_list(blocks) do
    %{output | "content" => Enum.map(blocks, &sanitize_text_block/1)}
    |> sanitize_input()
  end

  defp sanitize_output(output), do: sanitize_input(output)

  defp sanitize_text_block(%{"type" => "text", "text" => text} = block)
       when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        %{block | "text" => Jason.encode!(sanitize_input(decoded))}

      _ ->
        block
    end
  end

  defp sanitize_text_block(block), do: block

  # ============================================================================
  # Private
  # ============================================================================

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_binary(value), do: value

  # Never inspect/1 into a stored column — Elixir term syntax in a JSON
  # field reads as data to every later decoder.
  defp encode_json(value), do: Prima.Json.safe_encode(value)
end
