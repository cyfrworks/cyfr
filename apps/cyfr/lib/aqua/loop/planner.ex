# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Planner do
  @moduledoc """
  One context planner for the loop, fed by what the catalyst reports
  (`Cyfr.Models.capabilities/5`) and what the last response cost
  (`usage.input_tokens`).

  A request fits while the observed size stays under most of the usable
  window — the context window less the output ceiling and a margin, or
  the model's own input ceiling where that is lower — and
  its bytes stay under the consented request cap (`Cyfr.Limits`
  `max_request_size`); past either the planner names the compaction
  boundary: the oldest row the model keeps reading (`first_kept_seq`,
  inclusive), chosen so a tool call is never parted from its results,
  and the row before it (`summarized_through_seq`), the last one the
  summary stands for. Rows before the boundary stay in the transcript;
  only the projection changes. `prune/2` bounds old tool results in the
  projection alone. Sizes are estimates — a quarter of the bytes — until
  the next response reports what the request cost.

  What is measured is `readable/1`, not every row given: the projection
  keeps what a compaction already summarized, and only the request drops
  it, so measuring the whole of it would compact again every turn.
  """

  @margin_tokens 8_000
  @fill_ratio 0.85
  @keep_ratio 0.25
  @keep_min_tokens 4_000
  @keep_max_tokens 20_000
  @preserve_recent 20
  @truncated_result_chars 500

  @type boundary :: %{first_kept_seq: pos_integer(), summarized_through_seq: non_neg_integer()}

  @doc """
  The tokens a request may hold: the window less the output ceiling and
  the margin, and never past the model's input ceiling
  (`max_input_tokens`) where the capabilities carry one. `max_tokens` is
  the request's output ceiling, already bounded by the model's
  (`Aqua.Loop.Request.max_tokens/2`). Never less than one: a window too
  small for its own output allowance still plans, it just compacts to the
  newest step.
  """
  @spec usable(map(), pos_integer()) :: pos_integer()
  def usable(%{context_window: window} = caps, max_tokens)
      when is_integer(window) and is_integer(max_tokens) do
    combined = window - max_tokens - @margin_tokens

    # The capability map carries a positive integer or nil; anything else
    # is read the same way as nil so a malformed ceiling never tightens
    # the budget to zero.
    budget =
      case Map.get(caps, :max_input_tokens) do
        ceiling when is_integer(ceiling) and ceiling > 0 -> min(ceiling, combined)
        _ -> combined
      end

    max(budget, 1)
  end

  @doc """
  Whether the rows fit, or where to compact. `opts`: `:capabilities`,
  `:max_tokens` (the request's output ceiling), `:observed_tokens` (the
  last response's `input_tokens`, nil on the first request),
  `:new_bytes` (the bytes of rows appended since that response),
  `:request_bytes` and `:max_request_size` (the consented request cap).
  """
  @spec plan([Aqua.Tape.row()], keyword()) :: :fit | {:compact, boundary()}
  def plan(rows, opts) when is_list(rows) do
    caps = Keyword.fetch!(opts, :capabilities)
    max_tokens = Keyword.fetch!(opts, :max_tokens)
    usable = usable(caps, max_tokens)

    # What the model will actually be sent. The projection keeps every row a
    # compaction already summarized — only the request drops them — so
    # measuring the raw projection measures the whole thread again and
    # compacts on the first round of every later turn.
    rows = readable(rows)

    observed =
      case Keyword.get(opts, :observed_tokens) do
        n when is_integer(n) and n > 0 -> n + estimate_tokens(Keyword.get(opts, :new_bytes, 0))
        _ -> rows |> Enum.map(&row_bytes/1) |> Enum.sum() |> estimate_tokens()
      end

    over_bytes? =
      case {Keyword.get(opts, :request_bytes), Keyword.get(opts, :max_request_size)} do
        {bytes, cap} when is_integer(bytes) and is_integer(cap) and cap > 0 -> bytes > cap
        _ -> false
      end

    cond do
      rows == [] ->
        :fit

      observed > @fill_ratio * usable or over_bytes? ->
        keep =
          usable
          |> Kernel.*(@keep_ratio)
          |> round()
          |> max(@keep_min_tokens)
          |> min(@keep_max_tokens)

        {:compact, boundary(rows, keep)}

      true ->
        :fit
    end
  end

  @doc """
  The boundary that keeps about `keep_tokens` of the newest rows without
  parting a tool call from its results: rows are grouped by the model
  step that produced them, and the boundary is the start of the oldest
  group that still fits — at least the newest group, always.
  """
  @spec boundary([Aqua.Tape.row()], pos_integer()) :: boundary()
  def boundary(rows, keep_tokens) when is_list(rows) and rows != [] do
    groups = rows |> Enum.sort_by(& &1.seq) |> group()

    {kept, _} =
      groups
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn group, {acc, tokens} ->
        cost = group |> Enum.map(&row_bytes/1) |> Enum.sum() |> estimate_tokens()

        cond do
          acc == [] -> {:cont, {[group], cost}}
          tokens + cost <= keep_tokens -> {:cont, {[group | acc], tokens + cost}}
          # The first group that does not fit ends the tail: nothing older
          # is kept past a gap.
          true -> {:halt, {acc, tokens}}
        end
      end)

    first = kept |> List.first() |> List.first()
    kept_seq = with_answered_calls(rows, first.seq)
    %{first_kept_seq: kept_seq, summarized_through_seq: kept_seq - 1}
  end

  # Grouping keeps a result beside the call it answers, but only while they
  # are adjacent: an approval card or an aborted mark writes a row between
  # them, and the boundary could then land on that row and summarize away a
  # call whose result it keeps. Providers reject a `tool_result` with no
  # `tool_call`, and nothing repairs that direction.
  #
  # So the boundary is pulled back to include any call whose answer is kept.
  # Pulling back can bring in further results whose calls are older still,
  # hence the repeat; it only ever moves earlier, so it settles.
  defp with_answered_calls(rows, first) do
    calls =
      for row <- rows, row.kind == "tool_call", id = call_id(row), id != nil, into: %{} do
        {id, row.seq}
      end

    orphaned =
      for row <- rows,
          row.seq >= first,
          row.kind == "tool_result",
          id = call_id(row),
          seq = Map.get(calls, id),
          seq != nil and seq < first,
          do: seq

    case orphaned do
      [] -> first
      seqs -> with_answered_calls(rows, Enum.min(seqs))
    end
  end

  defp call_id(%{payload: payload}) do
    case payload do
      %{"tool_call_id" => id} when is_binary(id) -> id
      json when is_binary(json) -> decoded_call_id(json)
      _ -> nil
    end
  end

  defp decoded_call_id(json) do
    case Jason.decode(json) do
      {:ok, %{"tool_call_id" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  @doc """
  The projection with old tool results bounded: every `tool_result` row
  older than the newest `#{@preserve_recent}` rows carries at most
  `#{@truncated_result_chars}` characters of its content. Canonical rows
  are never changed.
  """
  @spec prune([Aqua.Tape.row()]) :: [Aqua.Tape.row()]
  def prune(rows) when is_list(rows) do
    {old, recent} = Enum.split(rows, max(length(rows) - @preserve_recent, 0))

    Enum.map(old, fn
      %{kind: "tool_result", content: content} = row
      when is_binary(content) and byte_size(content) > @truncated_result_chars ->
        %{row | content: String.slice(content, 0, @truncated_result_chars) <> "\n…[truncated]"}

      row ->
        row
    end) ++ recent
  end

  @doc """
  The request that produces a compaction summary: the rows before the
  boundary, shaped as `messages`, with the previous summary first when
  there is one, and the instruction to hand the work over in a summary.
  `opts`: `:model`, `:max_tokens`, `:previous_summary`.
  """
  @spec summary_request([map()], keyword()) :: map()
  def summary_request(messages, opts) when is_list(messages) do
    previous =
      case Keyword.get(opts, :previous_summary) do
        summary when is_binary(summary) and summary != "" ->
          [
            %{
              "role" => "user",
              "content" => [%{"type" => "text", "text" => "[Summary so far]\n" <> summary}]
            }
          ]

        _ ->
          []
      end

    %{
      "model" => Keyword.get(opts, :model),
      "system" => summary_instruction(),
      "messages" =>
        previous ++
          messages ++
          [
            %{
              "role" => "user",
              "content" => [
                %{
                  "type" => "text",
                  "text" =>
                    "Write the handoff summary of everything above: what was asked, what was " <>
                      "done and found, what remains open, and any facts the next steps need. " <>
                      "Keep file paths, names and decisions exact."
                }
              ]
            }
          ],
      "max_tokens" => Keyword.get(opts, :max_tokens, 4_096)
    }
  end

  @doc "A quarter of the bytes, never less than one token."
  @spec estimate_tokens(non_neg_integer() | binary() | map() | list()) :: pos_integer()
  def estimate_tokens(bytes) when is_integer(bytes), do: max(div(bytes, 4), 1)
  def estimate_tokens(text) when is_binary(text), do: estimate_tokens(byte_size(text))
  def estimate_tokens(term), do: term |> Jason.encode!() |> byte_size() |> estimate_tokens()

  @doc "How many newest rows `prune/1` leaves whole."
  def preserve_recent, do: @preserve_recent

  @doc """
  The rows the model reads: everything from the latest compaction's
  boundary, with that compaction standing in for what came before it. The
  summary row is kept, because it is sent and it costs tokens.
  """
  @spec readable([Aqua.Tape.row()]) :: [Aqua.Tape.row()]
  def readable(rows) do
    case rows |> Enum.filter(&(&1.kind == "compaction")) |> List.last() do
      nil ->
        Enum.reject(rows, &(&1.kind == "compaction"))

      latest ->
        first = first_kept_seq(latest)
        [latest | Enum.filter(rows, &(&1.kind != "compaction" and &1.seq >= first))]
    end
  end

  defp first_kept_seq(%{payload: payload}) do
    case payload do
      %{"first_kept_seq" => seq} when is_integer(seq) -> seq
      json when is_binary(json) -> decoded_first_kept(json)
      _ -> 0
    end
  end

  defp decoded_first_kept(json) do
    case Jason.decode(json) do
      {:ok, %{"first_kept_seq" => seq}} when is_integer(seq) -> seq
      _ -> 0
    end
  end

  # Rows of one model step — its reply, its calls and their results —
  # form one group; every other row is a group of its own.
  defp group(rows) do
    rows
    |> Enum.chunk_while(
      {nil, []},
      fn row, {step, acc} ->
        case {step_of(row), row.kind} do
          # A result belongs with the call that produced it. `TurnStorage`
          # stamps a call with the MODEL step's id and a result with its own
          # CALL step's id, so grouping on the id alone puts every result in
          # a group of its own and lets the boundary fall between a call and
          # its answer — which is the one thing this grouping exists to
          # prevent, and which no provider accepts.
          {_, "tool_result"} when acc != [] -> {:cont, {step, [row | acc]}}
          {nil, _} when acc == [] -> {:cont, {nil, [row]}}
          {nil, _} -> {:cont, Enum.reverse(acc), {nil, [row]}}
          {s, _} when s == step -> {:cont, {step, [row | acc]}}
          {s, _} when acc == [] -> {:cont, {s, [row]}}
          {s, _} -> {:cont, Enum.reverse(acc), {s, [row]}}
        end
      end,
      fn
        {_, []} -> {:cont, []}
        {_, acc} -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.reject(&(&1 == []))
  end

  defp step_of(%{kind: kind} = row) when kind in ["text", "tool_call", "tool_result"] do
    case row.payload do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{"step_id" => step}} when is_binary(step) -> step
          _ -> nil
        end

      %{"step_id" => step} when is_binary(step) ->
        step

      _ ->
        nil
    end
  end

  defp step_of(_row), do: nil

  defp row_bytes(%{content: content, payload: payload}) do
    byte_size(content || "") + byte_size(if(is_binary(payload), do: payload, else: ""))
  end

  defp summary_instruction do
    "You are compacting a long thread for the assistant that will continue it. " <>
      "Summarize faithfully and concretely; never invent; keep what the next steps need."
  end
end
