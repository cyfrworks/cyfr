# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Brain.Wire do
  @moduledoc """
  The brain wire, version 1, the holder's side (`Opus.Brain`): one JSON
  object per line over a brain driver's `run` session, commands from the
  holder and events from the driver. `tests/fixtures/brain_wire.json` binds
  this module and every driver (`apps/locus/keeper/cmd/cyfr-claude-code`)
  to the same lines; its `comment` is the protocol's statement.

  A line is read strictly: one object, at most `max_line_bytes/0` bytes,
  its `t` a message of its direction, its members exactly that message's,
  each of its type, every id non-empty and at most `max_id_bytes/0`
  bytes, every list at most `max_list/0` entries. Every line from the box
  is the program's word, since the harness runs under the driver's uid
  and can write as it does: a line that does not read is refused, and
  the holder ends the session on it. A command is held to the same reading
  before it is written, so the holder writes nothing a driver would not
  read.
  """

  @version 1
  @max_line_bytes 1_048_576
  @max_id_bytes 256
  @max_list 1_000
  @tool_name_bytes 1..128

  @config %{
    "model" => :string,
    "effort" => :string,
    "permission_mode" => :string,
    "harness_tools" => :strings
  }
  @counts ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens)
  @phases ~w(start end)
  @error_types ~w(invalid_request authentication rate_limited overloaded provider_error unknown_model)
  @media_types %{
    "image" => ~w(image/jpeg image/png image/gif image/webp),
    "document" => ~w(application/pdf)
  }
  @native ~w(text said own ask usage idle error)

  @commands %{
    "start" =>
      {~w(t gen config), ~w(session system pending),
       %{
         "gen" => :count,
         "config" => :config,
         "session" => :id,
         "system" => :string,
         "pending" => :ids
       }},
    "work" => {~w(t id work tools), [], %{"id" => :id, "work" => :id, "tools" => :tools}},
    "post" =>
      {~w(t id work content), ~w(context),
       %{"id" => :id, "work" => :id, "content" => :content, "context" => :content}},
    "answer" =>
      {~w(t id ask content is_error), [],
       %{"id" => :id, "ask" => :id, "content" => :string, "is_error" => :boolean}},
    "models" => {~w(t id), [], %{"id" => :id}},
    "forget" => {~w(t id session), [], %{"id" => :id, "session" => :id}}
  }

  @events %{
    "hello" => {~w(t v driver boot), [], %{"v" => :count, "driver" => :id, "boot" => :id}},
    "started" =>
      {~w(t session fresh held), [], %{"session" => :id, "fresh" => :boolean, "held" => :ids}},
    "gone" => {~w(t), [], %{}},
    "accepted" => {~w(t id), [], %{"id" => :id}},
    "refused" => {~w(t id reason), [], %{"id" => :id, "reason" => :string}},
    "text" =>
      {~w(t gen message delta), ~w(work),
       %{"gen" => :count, "work" => :id, "message" => :id, "delta" => :string}},
    "said" =>
      {~w(t gen message text), ~w(work),
       %{"gen" => :count, "work" => :id, "message" => :id, "text" => :string}},
    "own" =>
      {~w(t gen name phase), ~w(work),
       %{"gen" => :count, "work" => :id, "name" => :string, "phase" => :phase}},
    "ask" =>
      {~w(t gen ask name arguments), ~w(work),
       %{"gen" => :count, "work" => :id, "ask" => :id, "name" => :string, "arguments" => :object}},
    "usage" =>
      {~w(t gen counts), ~w(work result total),
       %{"gen" => :count, "work" => :id, "result" => :id, "total" => :id, "counts" => :counts}},
    "idle" =>
      {~w(t gen answered stop), ~w(work),
       %{"gen" => :count, "work" => :id, "answered" => :ids, "stop" => :string}},
    "error" =>
      {~w(t gen type message), ~w(work),
       %{"gen" => :count, "work" => :id, "type" => :error_type, "message" => :string}},
    "models" =>
      {~w(t id models efforts), [], %{"id" => :id, "models" => :models, "efforts" => :strings}},
    "forgot" => {~w(t id session), [], %{"id" => :id, "session" => :id}}
  }

  @typedoc "A command or an event as it reads: its JSON object, string keys."
  @type message :: %{required(String.t()) => term()}

  @typedoc "Why a line does not read: it is no message of its direction, or past a bound."
  @type refusal :: :unreadable | :unknown | :too_large

  @doc "The wire's version, the one a driver's `hello` names."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The most bytes one line may hold, either way."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc "The most bytes one id may hold."
  @spec max_id_bytes() :: pos_integer()
  def max_id_bytes, do: @max_id_bytes

  @doc "The most entries one list may hold."
  @spec max_list() :: pos_integer()
  def max_list, do: @max_list

  @doc """
  The messages of one direction, `:commands` or `:events`, each as its
  `{fields, optional, types}`.
  """
  @spec messages(:commands | :events) :: %{String.t() => {[String.t()], [String.t()], map()}}
  def messages(:commands), do: @commands
  def messages(:events), do: @events

  @doc "The members a `start`'s `config` may hold, each with its type."
  @spec config() :: %{String.t() => atom()}
  def config, do: @config

  @doc "The four counts a `usage` carries."
  @spec counts() :: [String.t()]
  def counts, do: @counts

  @doc "The phases an `own` event names."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc "The types an `error` event names, `Prima.Model`'s refusals a harness can type."
  @spec error_types() :: [String.t()]
  def error_types, do: @error_types

  @doc "The media types a content block of each kind may carry."
  @spec media_types() :: %{String.t() => [String.t()]}
  def media_types, do: @media_types

  @doc """
  The events that are the program's own lines (a driver writes one only
  when its harness wrote a line), as against the driver's own: what the
  silence of a program is measured by.
  """
  @spec native() :: [String.t()]
  def native, do: @native

  @doc "Whether `event` is one of the program's own lines (`native/0`)."
  @spec native?(message()) :: boolean()
  def native?(%{"t" => t}), do: t in @native

  @doc """
  The line `command` is written as, once it reads as a command
  (`read_command/1`): `{:error, refusal}` for one that does not, which
  is not written.
  """
  @spec encode(message()) :: {:ok, String.t()} | {:error, refusal()}
  def encode(%{} = command) do
    case Jason.encode(command) do
      {:ok, line} -> with {:ok, _read} <- read(line, @commands), do: {:ok, line}
      {:error, _not_json} -> {:error, :unreadable}
    end
  end

  @doc "A line from the holder, read as `encode/1` holds a command to."
  @spec read_command(String.t()) :: {:ok, message()} | {:error, refusal()}
  def read_command(line) when is_binary(line), do: read(line, @commands)

  @doc "A line from the driver, as the holder reads it."
  @spec decode(String.t()) :: {:ok, message()} | {:error, refusal()}
  def decode(line) when is_binary(line), do: read(line, @events)

  defp read(line, _messages) when byte_size(line) > @max_line_bytes, do: {:error, :too_large}

  defp read(line, messages) do
    with true <- String.valid?(line),
         {:ok, %{"t" => t} = message} when is_binary(t) <- Jason.decode(line) do
      case messages do
        %{^t => spec} ->
          if message?(message, spec), do: {:ok, message}, else: {:error, :unreadable}

        _not_this_direction ->
          {:error, :unknown}
      end
    else
      _not_one_object -> {:error, :unreadable}
    end
  end

  defp message?(message, {fields, optional, types}) do
    Enum.all?(fields, &Map.has_key?(message, &1)) and
      Enum.all?(Map.keys(message), &(&1 in fields or &1 in optional)) and
      Enum.all?(message, fn
        {"t", _t} -> true
        {key, value} -> of_type?(Map.fetch!(types, key), value)
      end) and one_measure?(message)
  end

  # A usage names a native result or a cumulative total, exactly one.
  defp one_measure?(%{"t" => "usage"} = usage),
    do: Map.has_key?(usage, "result") != Map.has_key?(usage, "total")

  defp one_measure?(_message), do: true

  defp of_type?(:id, value), do: id?(value)
  defp of_type?(:string, value), do: is_binary(value)
  defp of_type?(:count, value), do: is_integer(value) and value >= 0
  defp of_type?(:boolean, value), do: is_boolean(value)
  defp of_type?(:object, value), do: is_map(value)
  defp of_type?(:ids, value), do: list?(value, &id?/1)
  defp of_type?(:strings, value), do: list?(value, &is_binary/1)
  defp of_type?(:content, value), do: list?(value, &block?/1)
  defp of_type?(:tools, value), do: list?(value, &tool?/1)
  defp of_type?(:models, value), do: list?(value, &model?/1)
  defp of_type?(:phase, value), do: value in @phases
  defp of_type?(:error_type, value), do: value in @error_types

  defp of_type?(:config, value) when is_map(value),
    do:
      Enum.all?(value, fn {key, v} -> is_map_key(@config, key) and of_type?(@config[key], v) end)

  defp of_type?(:counts, value) when is_map(value),
    do:
      Enum.sort(Map.keys(value)) == Enum.sort(@counts) and
        Enum.all?(Map.values(value), &of_type?(:count, &1))

  defp of_type?(_type, _value), do: false

  defp id?(value), do: is_binary(value) and value != "" and byte_size(value) <= @max_id_bytes

  defp list?(value, entry?),
    do: is_list(value) and length(value) <= @max_list and Enum.all?(value, entry?)

  defp block?(%{"type" => "text", "text" => text} = block) when map_size(block) == 2,
    do: is_binary(text)

  defp block?(%{"type" => kind, "media_type" => media_type, "data" => data} = block)
       when map_size(block) == 3 and is_map_key(@media_types, kind),
       do: media_type in @media_types[kind] and is_binary(data)

  defp block?(_block), do: false

  defp tool?(%{"name" => name, "description" => description, "parameters" => parameters} = tool)
       when map_size(tool) == 3,
       do:
         is_binary(name) and byte_size(name) in @tool_name_bytes and is_binary(description) and
           is_map(parameters)

  defp tool?(_tool), do: false

  defp model?(%{"id" => id, "name" => name} = model) when map_size(model) == 2,
    do: id?(id) and is_binary(name)

  defp model?(_model), do: false
end
