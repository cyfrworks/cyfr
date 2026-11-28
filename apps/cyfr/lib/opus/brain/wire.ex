# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Brain.Wire do
  @moduledoc """
  The brain wire, version 8, the holder's side (`Opus.Brain`): one JSON
  object per line over a brain driver's `run` session, commands from the
  holder and events from the driver. `tests/fixtures/brain_wire.json` binds
  this module and every driver's side (`apps/locus/keeper/internal/brainwire`,
  which `cmd/cyfr-claude-code`, `cmd/cyfr-codex` and `cmd/cyfr-acp` share)
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

  @version 8
  @max_line_bytes 1_048_576
  @max_id_bytes 256
  @max_list 1_000
  # What an own tool's `detail` holds at most: what its run does or did.
  @max_detail_bytes 2_048
  @tool_name_bytes 1..128
  # What every harness carries of a tool whole (`carried?/1`): Claude Code
  # keeps a description's first 16,384 characters, counted as JavaScript
  # counts them, in UTF-16 code units; its stub takes a tool as one
  # argument of at most 131,071 bytes; and its driver takes the stub's
  # answer members, `result` and `error`, out of every call's arguments.
  @max_description 16_384
  @max_stub_argument 131_071
  @uncarried ~w(result error)
  # A list's tools that every harness carries take, as the stub's
  # arguments, each a JSON string in one array, at most three quarters of
  # a line: the rest is for what a line carries beside them, a start's
  # instructions and the set Claude Code's driver wraps them in.
  @max_tools_bytes 786_432

  @config %{
    "model" => :string,
    "effort" => :string,
    "access" => :string,
    "harness_tools" => :strings
  }
  @counts ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens)
  @accountings ~w(complete partial unavailable)
  @stops ~w(end_turn limit error)
  @phases ~w(start end)
  @accounts ~w(signed_in signed_out)
  @error_types ~w(invalid_request authentication rate_limited overloaded provider_error unknown_model)
  @media_types %{
    "image" => ~w(image/jpeg image/png image/gif image/webp),
    "document" => ~w(application/pdf)
  }
  @native ~w(text thought said own ask usage idle error)
  # What a driver's `ending` may say of its end, its own finding and never
  # the program's words (`endings/0`).
  @endings ~w(unanswered servers_unlisted refused outdated unsupported ended unrunnable
              unreadable unfit too_many_tools broken)

  @commands %{
    "start" =>
      {~w(t gen config), ~w(session system pending tools),
       %{
         "gen" => :count,
         "config" => :config,
         "session" => :id,
         "system" => :string,
         "pending" => :ids,
         "tools" => :tools
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
      {~w(t session fresh held), ~w(account),
       %{"session" => :id, "fresh" => :boolean, "held" => :ids, "account" => :account}},
    "gone" => {~w(t), [], %{}},
    "accepted" => {~w(t id), [], %{"id" => :id}},
    "later" => {~w(t id), [], %{"id" => :id}},
    "refused" =>
      {~w(t id reason), ~w(account),
       %{"id" => :id, "reason" => :string, "account" => :signed_out}},
    "text" =>
      {~w(t gen message delta), ~w(work),
       %{"gen" => :count, "work" => :id, "message" => :id, "delta" => :string}},
    "thought" =>
      {~w(t gen message delta), ~w(work),
       %{"gen" => :count, "work" => :id, "message" => :id, "delta" => :string}},
    "said" =>
      {~w(t gen message text), ~w(work),
       %{"gen" => :count, "work" => :id, "message" => :id, "text" => :string}},
    "own" =>
      {~w(t gen call name phase), ~w(work detail),
       %{
         "gen" => :count,
         "work" => :id,
         "call" => :id,
         "name" => :string,
         "phase" => :phase,
         "detail" => :detail
       }},
    "ask" =>
      {~w(t gen ask name arguments), ~w(work),
       %{"gen" => :count, "work" => :id, "ask" => :id, "name" => :string, "arguments" => :object}},
    "usage" =>
      {~w(t gen accounting), ~w(work result total models),
       %{
         "gen" => :count,
         "work" => :id,
         "result" => :id,
         "total" => :id,
         "accounting" => :accounting,
         "models" => :model_counts
       }},
    "idle" =>
      {~w(t gen answered stop), ~w(work),
       %{"gen" => :count, "work" => :id, "answered" => :ids, "stop" => :stop}},
    "error" =>
      {~w(t gen type message), ~w(work),
       %{"gen" => :count, "work" => :id, "type" => :error_type, "message" => :string}},
    "models" =>
      {~w(t id models access), ~w(account),
       %{"id" => :id, "models" => :models, "access" => :choices, "account" => :signed_in}},
    "forgot" => {~w(t id session), [], %{"id" => :id, "session" => :id}},
    "ending" => {~w(t why), [], %{"why" => :why}}
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

  @doc "The most bytes an own tool's `detail` may hold."
  @spec max_detail_bytes() :: pos_integer()
  def max_detail_bytes, do: @max_detail_bytes

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

  @doc "The four counts a `usage` carries for each model."
  @spec counts() :: [String.t()]
  def counts, do: @counts

  @doc """
  What a `usage` says of its counts: `complete`, `partial` (some did not
  read), or `unavailable` (the harness gave none, and the event names no
  models).
  """
  @spec accountings() :: [String.t()]
  def accountings, do: @accountings

  @doc "Why a native turn ended, as an `idle` names it."
  @spec stops() :: [String.t()]
  def stops, do: @stops

  @doc "The phases an `own` event names."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc "What an event may say of the program's account, as its driver read it."
  @spec accounts() :: [String.t()]
  def accounts, do: @accounts

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

  @doc """
  What a driver's `ending`, the last line of a driver that ends of
  itself, may name in `why`: its own finding, never the program's words,
  which `Opus.Brain` hands its attendant as the end's reason.
  """
  @spec endings() :: [String.t()]
  def endings, do: @endings

  @doc "Whether `name` is as long as a tool's name may be: 1 to 128 bytes."
  @spec tool_name?(term()) :: boolean()
  def tool_name?(name), do: is_binary(name) and byte_size(name) in @tool_name_bytes

  @doc "The most UTF-16 code units a tool's description may hold."
  @spec max_description() :: pos_integer()
  def max_description, do: @max_description

  @doc "The most bytes a tool may take as the stub's argument (`stub_argument/1`)."
  @spec max_stub_argument() :: pos_integer()
  def max_stub_argument, do: @max_stub_argument

  @doc "The properties no tool's parameters name: a harness takes them out of every call."
  @spec uncarried() :: [String.t()]
  def uncarried, do: @uncarried

  @doc "The most bytes a list of carried tools takes as the stub's arguments (`tools_bytes/1`)."
  @spec max_tools_bytes() :: pos_integer()
  def max_tools_bytes, do: @max_tools_bytes

  @doc """
  Whether `tool` is one every harness carries whole: a tool a line
  carries, `{name, description, parameters}` with a name of 1 to 128
  bytes, whose description is at most `max_description/0` UTF-16 code
  units, whose parameters name none of `uncarried/0`
  (`named_properties/1`), and
  that is at most `max_stub_argument/0` bytes as the stub's argument. A
  line may carry a tool past these, which a driver refuses; the turn
  hands an outside server's tool only when it is carried
  (`Aqua.Loop.Request`).
  """
  @spec carried?(term()) :: boolean()
  def carried?(tool),
    do:
      tool?(tool) and utf16_units(tool["description"]) <= @max_description and
        carried_properties?(tool["parameters"]) and
        byte_size(stub_argument(tool)) <= @max_stub_argument

  @doc """
  The argument names a tool's `parameters` name at their top: those its
  `properties` declare, when an object, and those its `required` lists,
  when a list, since a schema may require one it does not declare, there
  or through what composes the top: each schema of `allOf`, `anyOf` and
  `oneOf`, `then` and `else`, and a `$ref` into the same document (`#`
  and a JSON pointer), each schema read once. A call carries each of these
  as an argument of that name. A schema that names nothing and takes any
  property names none.
  """
  @spec named_properties(map()) :: [String.t()]
  def named_properties(parameters) when is_map(parameters),
    do: parameters |> named(parameters, MapSet.new()) |> elem(0) |> Enum.uniq()

  @composing ~w(allOf anyOf oneOf)

  defp named(schema, root, seen) when is_map(schema) do
    if MapSet.member?(seen, schema) do
      {[], seen}
    else
      seen = MapSet.put(seen, schema)
      own = declared(schema) ++ required(schema)

      Enum.reduce(composed(schema, root), {own, seen}, fn part, {names, seen} ->
        {more, seen} = named(part, root, seen)
        {names ++ more, seen}
      end)
    end
  end

  defp named(_schema, _root, seen), do: {[], seen}

  defp declared(%{"properties" => %{} = properties}), do: Map.keys(properties)
  defp declared(_schema), do: []

  defp required(%{"required" => required}) when is_list(required),
    do: Enum.filter(required, &is_binary/1)

  defp required(_schema), do: []

  defp composed(schema, root) do
    listed =
      for key <- @composing,
          %{^key => parts} when is_list(parts) <- [schema],
          part <- parts,
          do: part

    branches = for key <- ~w(then else), %{^key => part} <- [schema], do: part

    referenced =
      case schema do
        %{"$ref" => "#" <> pointer} -> [pointed(root, pointer)]
        _ -> []
      end

    listed ++ branches ++ referenced
  end

  # The schema a same-document JSON pointer names (`#` the whole), nil
  # for one naming nothing.
  defp pointed(root, ""), do: root

  defp pointed(root, "/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce_while(root, fn
      segment, %{} = node -> {:cont, Map.get(node, segment)}
      segment, node when is_list(node) -> {:cont, list_at(node, segment)}
      _segment, _leaf -> {:halt, nil}
    end)
  end

  defp pointed(_root, _pointer), do: nil

  defp list_at(list, segment) do
    case Integer.parse(segment) do
      {index, ""} when index >= 0 -> Enum.at(list, index)
      _ -> nil
    end
  end

  @doc """
  The stub's argument for `tool`, as the driver writes it (Go's
  `brainwire.Marshal`): `{description, inputSchema, name}`, its strings
  with U+2028 and U+2029 escaped, its schema the line's own bytes.
  """
  @spec stub_argument(map()) :: String.t()
  def stub_argument(%{"name" => name, "description" => description, "parameters" => parameters}) do
    IO.iodata_to_binary([
      ~s({"description":),
      Jason.encode_to_iodata!(description, escape: :javascript_safe),
      ~s(,"inputSchema":),
      Jason.encode_to_iodata!(parameters),
      ~s(,"name":),
      Jason.encode_to_iodata!(name, escape: :javascript_safe),
      "}"
    ])
  end

  @doc """
  The bytes `tools` take as the stub's arguments, each a JSON string in
  one array, as Claude Code's driver sets them.
  """
  @spec tools_bytes([map()]) :: non_neg_integer()
  def tools_bytes(tools) when is_list(tools) do
    tools
    |> Enum.map(&stub_argument/1)
    |> Jason.encode_to_iodata!(escape: :javascript_safe)
    |> IO.iodata_length()
  end

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

  # A usage names a native result or a cumulative total, exactly one, and
  # names its models exactly when its accounting is not unavailable.
  defp one_measure?(%{"t" => "usage"} = usage),
    do:
      Map.has_key?(usage, "result") != Map.has_key?(usage, "total") and
        Map.has_key?(usage, "models") != (usage["accounting"] == "unavailable")

  defp one_measure?(_message), do: true

  defp of_type?(:id, value), do: id?(value)
  defp of_type?(:string, value), do: is_binary(value)
  defp of_type?(:detail, value), do: is_binary(value) and byte_size(value) <= @max_detail_bytes
  defp of_type?(:count, value), do: is_integer(value) and value >= 0
  defp of_type?(:boolean, value), do: is_boolean(value)
  defp of_type?(:object, value), do: is_map(value)
  defp of_type?(:ids, value), do: list?(value, &id?/1)
  defp of_type?(:strings, value), do: list?(value, &is_binary/1)
  defp of_type?(:content, value), do: list?(value, &block?/1)

  defp of_type?(:tools, value), do: list?(value, &tool?/1)

  defp of_type?(:models, value), do: list?(value, &model?/1)
  defp of_type?(:choices, value), do: list?(value, &choice?/1)
  defp of_type?(:model_counts, value), do: list?(value, &model_counts?/1)
  defp of_type?(:phase, value), do: value in @phases
  defp of_type?(:error_type, value), do: value in @error_types
  defp of_type?(:accounting, value), do: value in @accountings
  defp of_type?(:stop, value), do: value in @stops
  defp of_type?(:account, value), do: value in @accounts
  defp of_type?(:signed_in, value), do: value == "signed_in"
  defp of_type?(:signed_out, value), do: value == "signed_out"
  defp of_type?(:why, value), do: value in @endings

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
       do: tool_name?(name) and is_binary(description) and is_map(parameters)

  defp tool?(_tool), do: false

  defp carried_properties?(parameters),
    do: not Enum.any?(@uncarried, &(&1 in named_properties(parameters)))

  defp utf16_units(text) do
    case :unicode.characters_to_binary(text, :utf8, :utf16) do
      units when is_binary(units) -> div(byte_size(units), 2)
      _not_utf8 -> @max_description + 1
    end
  end

  # A model: its id, the name a person reads and the efforts it takes.
  defp model?(%{"id" => id, "name" => name, "efforts" => efforts} = model)
       when map_size(model) == 3,
       do: id?(id) and is_binary(name) and of_type?(:strings, efforts)

  defp model?(_model), do: false

  # An access choice: its id and the name a person reads.
  defp choice?(%{"id" => id, "name" => name} = choice) when map_size(choice) == 2,
    do: id?(id) and is_binary(name)

  defp choice?(_choice), do: false

  defp model_counts?(%{"model" => model, "counts" => counts} = entry) when map_size(entry) == 2,
    do: id?(model) and of_type?(:counts, counts)

  defp model_counts?(_entry), do: false
end
