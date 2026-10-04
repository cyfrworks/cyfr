# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Feeds do
  @moduledoc """
  An athanor's feeds: each binds one component operation, fixed arguments,
  an interval and labelled actions (`Prima.Feed.Binding`), and is a row of
  the schedules' table of kind `feed` whose id is its binding id
  (`Arca.CronSchedule`). The scheduler fires it as it fires a schedule
  (`Crucible.Schedules.Scheduler`), and a result is kept only when this
  module accepts it.

    * `max_per_athanor/0` is the most live feeds an athanor holds, a
      structural bound counted under the athanor's lock in the transaction
      that inserts a feed (`Arca.CronSchedule.create_feed/2`, which takes
      it as `cap:`), and counted apart from the schedules' own.
    * `spec/1` reads a row's stored binding back.
    * `list/1` and `get/2` answer the caller's athanor's live feeds, each
      as `t:feed/0`.
    * `accept/5` takes a run's output for the seq the run claimed: it
      decodes the output, unwraps its envelope, holds the data to the
      binding's result bound and shape (`Prima.Feed.check_result/2`) and
      writes its JSON text fenced (`Arca.CronSchedule.accept_feed_result/5`).
      A refused result writes nothing.

  ## The envelope

  A run's output, a catalyst's or a formula's alike, is an envelope: a
  JSON object of exactly `status` (an integer) and `data`, or an object
  holding `error` (with `status` optional). A feed's result is the `data`
  of an envelope whose `status` is 200 to 299, and the binding's result
  shape describes that data. Every other output is refused with reason
  `"error"`, naming only its `status` when it carries an integer one: a
  status outside 2xx, an `error` envelope, an envelope with a key besides
  `status` and `data`, and an output that is no envelope at all. No output
  is taken as it is.

  A feed's arguments and results are JSON text, never digested; nothing
  here logs a result or a binding's content.
  """

  alias Arca.CronSchedule
  alias Prima.Feed.Binding
  alias Sanctum.Context

  require Logger

  @max_per_athanor 10

  @typedoc """
  A live feed: its binding id, its binding, the seq and time of its
  accepted result (0 and nil before the first), and that result, decoded
  (nil before the first).
  """
  @type feed :: %{
          binding_id: String.t(),
          binding: Binding.t(),
          feed_result_seq: non_neg_integer(),
          feed_result_at: DateTime.t() | nil,
          result: term()
        }

  @typedoc """
  Why a result is refused: where in it, and the reason — one of
  `Prima.Feed.reasons/0`, or `"error"` for an output that is not a 2xx
  envelope, which also names the output's integer `status` when it has
  one, and nothing else of it.
  """
  @type refusal :: %{
          required(:path) => String.t(),
          required(:reason) => String.t(),
          optional(:status) => integer()
        }

  @doc "The most live feeds one athanor holds."
  @spec max_per_athanor() :: pos_integer()
  def max_per_athanor, do: @max_per_athanor

  @doc """
  A feed row's stored binding (`feed_spec`), read back through its
  grammar: `{:ok, binding}`, or `{:error, %{path, reason}}` for text that
  is absent (`"required"`), not JSON (`"json"`) or that the grammar
  refuses.
  """
  @spec spec(map()) :: {:ok, Binding.t()} | {:error, refusal()}
  def spec(%{feed_spec: text}) when is_binary(text) do
    case Prima.Json.decode(text) do
      {:ok, json} -> Binding.validate(json)
      {:error, :invalid_json} -> {:error, %{path: "", reason: "json"}}
    end
  end

  def spec(%{}), do: {:error, %{path: "", reason: "required"}}

  @doc """
  The caller's athanor's live feeds, by name. A row whose stored binding no
  longer reads is left out, and logged by its id and the refusal, never by
  its content.
  """
  @spec list(Context.t()) :: {:ok, [feed()]} | {:error, :no_athanor | :database_error}
  def list(%Context{} = ctx) do
    with {:ok, rows} <- CronSchedule.list_feeds(Context.actor(ctx)) do
      {:ok, rows |> Enum.flat_map(&readable/1) |> Enum.sort_by(& &1.binding.name)}
    end
  end

  @doc """
  The caller's athanor's live feed `binding_id`. A schedule's id, a removed
  or another athanor's feed, an absent id, and a row whose stored binding
  no longer reads are each `:not_found`.
  """
  @spec get(Context.t(), String.t()) ::
          {:ok, feed()} | {:error, :not_found | :no_athanor | :database_error}
  def get(%Context{} = ctx, binding_id) when is_binary(binding_id) do
    with {:ok, row} <- CronSchedule.get_feed(Context.actor(ctx), binding_id) do
      case readable(row) do
        [feed] -> {:ok, feed}
        [] -> {:error, :not_found}
      end
    end
  end

  @doc """
  Accept a run's `output` as feed `binding_id`'s result for `seq`, the seq
  the run claimed (`Arca.CronSchedule.claim_feed_seq/2`) under `slot`, the
  member slot read when it was claimed.

  A binary output is decoded as JSON text, and a map or list is taken as
  the decoded value; anything else is not JSON. The decoded output must be
  a 2xx envelope (the moduledoc's), whose `data` is the result. The result
  is then held to the binding's bound and shape
  (`Prima.Feed.check_result/2`) and written as its `Prima.Json.encode/1`
  text, fenced.

  Answers `:ok` once written; `{:error, :stale}` when a later-claimed
  result was already accepted; `{:error, {:refused, refusal}}` for an
  output that is not JSON (`"json"`) or not a 2xx envelope (`"error"`,
  with its `status` when it has one), or a result past its bound
  (`"size"`) or outside its shape, which writes nothing; and the storage
  layer's
  `:not_found` (a feed removed, a schedule's or another athanor's id),
  `:not_owner` (a member that lost its slot), `:unclaimed`, `:no_athanor`
  and `:database_error` as they are.
  """
  @spec accept(Context.t(), String.t(), integer(), term(), Arca.ControlPlane.slot() | :none) ::
          :ok
          | {:error,
             :stale
             | {:refused, refusal()}
             | :not_found
             | :not_owner
             | :unclaimed
             | :no_athanor
             | :database_error}
  def accept(%Context{} = ctx, binding_id, seq, output, slot)
      when is_binary(binding_id) and is_integer(seq) do
    actor = Context.actor(ctx)

    with {:ok, row} <- CronSchedule.get_feed(actor, binding_id),
         {:ok, binding} <- stored_binding(row),
         {:ok, decoded} <- decoded(output),
         {:ok, result} <- unwrapped(decoded),
         {:ok, text} <- checked(binding, result),
         {:ok, _row} <- CronSchedule.accept_feed_result(actor, binding_id, seq, text, slot) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------

  defp readable(row) do
    case spec(row) do
      {:ok, binding} ->
        [
          %{
            binding_id: row.id,
            binding: binding,
            feed_result_seq: row.feed_result_seq,
            feed_result_at: row.feed_result_at,
            result: stored_result(row)
          }
        ]

      {:error, refusal} ->
        unreadable(row, refusal)
        []
    end
  end

  defp stored_binding(row) do
    case spec(row) do
      {:ok, binding} ->
        {:ok, binding}

      {:error, refusal} ->
        unreadable(row, refusal)
        {:error, :not_found}
    end
  end

  # The line names the row and where its binding fails, never its text.
  defp unreadable(row, %{path: path, reason: reason}) do
    Logger.warning(
      "[Crucible.Feeds] feed #{row.id} has a stored binding that does not read " <>
        "(#{reason} at #{inspect(path)}); it is left out"
    )
  end

  # Written only as accepted JSON text; text that does not decode is said
  # by its size and read as no result.
  defp stored_result(%{feed_result: nil}), do: nil

  defp stored_result(%{feed_result: text} = row) when is_binary(text) do
    case Prima.Json.decode(text) do
      {:ok, result} ->
        result

      {:error, :invalid_json} ->
        Logger.warning(
          "[Crucible.Feeds] feed #{row.id} has a stored result that is not JSON " <>
            "(#{byte_size(text)} bytes)"
        )

        nil
    end
  end

  defp decoded(output) when is_binary(output) do
    case Prima.Json.decode(output) do
      {:ok, result} -> {:ok, result}
      {:error, :invalid_json} -> not_json()
    end
  end

  defp decoded(output) when (is_map(output) and not is_struct(output)) or is_list(output),
    do: {:ok, output}

  defp decoded(_output), do: not_json()

  defp not_json, do: {:error, {:refused, %{path: "", reason: "json"}}}

  # The result is the `data` of a 2xx envelope of exactly `status` and
  # `data`. Anything else is refused as an error, named by its integer
  # `status` when it has one and by nothing else it holds.
  defp unwrapped(%{"status" => status, "data" => data} = envelope)
       when is_integer(status) and status in 200..299 and map_size(envelope) == 2,
       do: {:ok, data}

  defp unwrapped(%{"status" => status}) when is_integer(status),
    do: {:error, {:refused, %{path: "", reason: "error", status: status}}}

  defp unwrapped(_output), do: {:error, {:refused, %{path: "", reason: "error"}}}

  # The result's JSON text, once its bound and shape hold.
  defp checked(binding, result) do
    with :ok <- Prima.Feed.check_result(binding, result),
         {:ok, text} <- Prima.Json.encode(result) do
      {:ok, text}
    else
      {:error, %{path: _, reason: _} = refusal} -> {:error, {:refused, refusal}}
      {:error, :unencodable} -> not_json()
    end
  end
end
