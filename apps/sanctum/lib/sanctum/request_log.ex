# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.RequestLog do
  @moduledoc """
  The MCP request log's rows, as projections of admission decisions.

  One row per recorded call, so a chain is legible: the `execution.run`
  an ingress received, and each tool the running component reached from
  inside the sandbox. `id` is the call — the decision's call id — and
  `request_id` is the ingress request they share.

  A row is never written on its own. `Sanctum.Decisions.open/3` appends
  the decision with the start row this module builds (`opened/3`), and
  `Sanctum.Decisions.close/3` records the completion with the columns
  this module builds (`closed/3`), each in the decision's own transaction
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

  A row's output is the athanor's only when the output came from it. A
  call may read another athanor its caller sits in — a note from the
  person's own athanor, the members or facts of another group — and the
  members of the athanor it ran in must not read that through its log. An
  answer names each athanor it read from (`athanor_id`, `athanor`, or an
  athanor row's `id`), so a success whose answer names any athanor other
  than the row's stores `%{"redacted" => "cross_athanor"}` in place of its
  output, beside the row's operation and status. The caller's own answer is
  untouched, and an answer that names only the row's athanor, or none, is
  stored as it is.

  ## Reading the log

  The rows are security rows: Sanctum is their only reader, and a reader
  above it takes them from here. `list/2` reads the caller's athanor's
  rows and no other: the athanor is the context's, whatever the options
  name, and a context with no athanor, a platform administrator's
  included, is refused before any row is read.

  ## Sensitive Data

  Input parameters are sanitized before they are stored, and so is the
  structure inside a result's text blocks (`Prima.Sanitizer`): values
  under sensitive key names are redacted, and so is every credential of a
  shape the platform issues wherever a string carries it, whatever its
  key. A refused call's row also holds no argument its declaration
  refuses (`Sanctum.Catalog`). The decision a row projects, and a
  completion's text, reach it already sanitized (`Sanctum.Decisions`), so
  a row's action and error are its decision's. Every text column the row
  stores passes the same redaction once more here, as the columns are
  built (`opened/3`, `closed/3`): a method a caller named, a completion's
  routing label, or any column added later, carries no credential of a
  shape the platform issues, whichever caller supplied it.
  """

  alias Prima.Decision
  alias Sanctum.Context

  @cross_athanor %{"redacted" => "cross_athanor"}
  @locators [:id, :athanor_id, :athanor, "id", "athanor_id", "athanor"]

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
    |> redacted_texts()
  end

  def opened(_ctx, %Decision{}, projection) when is_map(projection), do: nil

  # ============================================================================
  # Reads
  # ============================================================================

  @doc """
  The caller's athanor's request-log rows, newest first
  (`Arca.McpLog.list/2`, whose filters `opts` carries: `:limit`,
  `:user_id`, `:status`, `:request_id`, `:tool` and `:since`), read under
  the context's actor. The athanor is the context's; an `:athanor_id`
  among the options names nothing. A context with no athanor is
  `{:error, :no_athanor}` before any row is read, whatever its scope.
  """
  @spec list(Context.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_athanor | :database_error}
  def list(%Context{} = ctx, opts) when is_list(opts),
    do: Arca.McpLog.list(Context.actor(ctx), opts)

  @doc """
  The completion columns of a call's row, filed under `ctx`'s athanor:
  `"success"` with its sanitized output — or the `cross_athanor` marker in
  its place when the answer names another athanor (the module doc) — or
  `"error"` with the refusal's sentence (`text`, rendered by the caller
  from the reason). `:duration_ms` and `:routed_to` label either; an
  absent one is left as the row has it.
  """
  @spec closed(Context.t(), {:ok, term()} | {:error, String.t()}, map()) :: map()
  def closed(%Context{athanor_id: athanor_id}, {:ok, output}, meta) when is_map(meta) do
    stored = if foreign?(output, athanor_id), do: @cross_athanor, else: sanitize_output(output)

    %{status: "success", output: encode_json(stored)}
    |> labelled(meta, [:duration_ms, :routed_to])
    |> redacted_texts()
  end

  def closed(%Context{}, {:error, text}, meta) when is_binary(text) and is_map(meta) do
    %{status: "error", error: text}
    |> labelled(meta, [:duration_ms, :routed_to])
    |> redacted_texts()
  end

  # The one place every text column of a row passes, whoever supplied the
  # text: a caller's method, a completion's routing label, a decision's
  # texts. Only strings are touched, so the clock and the counts stay what
  # they are, and a column already sanitized is unchanged.
  defp redacted_texts(columns) when is_map(columns) do
    Map.new(columns, fn
      {key, value} when is_binary(value) -> {key, Prima.Sanitizer.sanitize(value)}
      pair -> pair
    end)
  end

  defp labelled(columns, meta, keys) do
    Enum.reduce(keys, columns, fn key, acc ->
      case Map.get(meta, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # Whether an answer names an athanor other than `home`, the row's. The
  # locator keys are the ones answers name their athanor under; prose under
  # any other key is a body, never read as a locator. A tools/call text
  # block carries its structured answer as JSON text, so it is decoded and
  # read as the structure it is.
  defp foreign?(%{"type" => "text", "text" => text} = block, home) when is_binary(text) do
    decoded =
      case Jason.decode(text) do
        {:ok, structured} when is_map(structured) or is_list(structured) -> structured
        _prose -> nil
      end

    foreign?(decoded, home) or foreign?(Map.delete(block, "text"), home)
  end

  # A struct is read by its fields (a clock, a source); it enumerates nothing.
  defp foreign?(%_{} = struct, home), do: foreign?(Map.from_struct(struct), home)

  defp foreign?(%{} = map, home) do
    Enum.any?(map, fn {key, value} ->
      (key in @locators and other_athanor?(value, home)) or foreign?(value, home)
    end)
  end

  defp foreign?(list, home) when is_list(list), do: Enum.any?(list, &foreign?(&1, home))
  defp foreign?(_leaf, _home), do: false

  defp other_athanor?(value, home),
    do: Sanctum.Tenancy.Athanors.athanor_id?(value) and value != home

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
  # caller under a sensitive key (a session token, or any credential whose
  # value has no recognisable shape) would be persisted verbatim. Decode
  # each text block that parses as JSON, sanitize the structure, and
  # re-encode; prose text is sanitized as any string is, by value shape
  # alone. The client response is built before logging and is never
  # affected.
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
