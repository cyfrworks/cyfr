# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ChatFixture do
  @moduledoc """
  What a test needs to drive a turn on the chat fixture
  (`test_wasm/chat_fixture/`), a `model/chat@1` catalyst the Opus service
  runs for real, which plays the script the turn's message carries and
  answers what it was given.

  - The estate: `lay_seed!/2` lays a seed whose only catalyst is the
    fixture and whose soul runs on it with a small tool policy of catalog
    operations; `estate!/0` fills a fresh group estate from the configured
    seed the way a person's is filled (`Compendium.Provisioning.provision/2`);
    `bind_key!/2` connects a key to the fixture through the consent walk.
  - The script: `message/2` is the line a person sends, the script in a
    fenced block of it; `text/1`, `call_start/3`, `call_delta/2`,
    `call_end/1`, `usage/1`, `stop/1` and `error/2` are the contract's
    seven stream events; `key/0`, `key/2`, `fill/2` and `repeat/2` are the
    fixture's own words (see its README).
  - Watching: `observe!/2` starts a viewer that holds no handle on the
    engine — it keeps what the thread's topic carries and, for every
    execution the estate's execution topic announces, what that
    execution's event stream carries in the order it arrives, caught up
    from the replay window so nothing emitted before it subscribed is
    missed. `seen/1` answers both.
  - Reading: `report/2` is what the fixture answered about a chat step
    (the request it received and the host's reply to each emit), read from
    the step's retained result; `leaks/2` names every place a credential
    shows: a column of any table, a file under the base path, or a term
    the caller passes.
  """

  alias Sanctum.Tenancy.{Athanors, Users}

  @wasm Path.expand("test_wasm/chat_fixture/chat_fixture.wasm", __DIR__)
  @readme Path.expand("test_wasm/chat_fixture/README.md", __DIR__)
  @name "chat-fixture"
  @ref "catalyst:local.#{@name}"
  @version "0.1.0"
  @key_field "FIXTURE_API_KEY"
  @fence "```"

  @limits %{
    "timeout" => "1m",
    "max_memory_bytes" => 67_108_864,
    "max_request_size" => 1_048_576,
    "max_response_size" => 5_242_880,
    "rate_limit" => %{"requests" => 10_000, "window" => "1m"}
  }

  # Catalog operations the gate admits for the soul: reads that run beside
  # each other, and one that asks the person first.
  @tool_policy %{
    "notes.list" => "auto",
    "notes.read" => "auto",
    "notes.search" => "auto",
    "notes.keep" => "ask",
    "system.status" => "auto"
  }

  @doc "The fixture's name-level reference."
  @spec ref() :: String.t()
  def ref, do: @ref

  @doc "The fixture's checked-in binary."
  @spec wasm_path() :: Path.t()
  def wasm_path, do: @wasm

  @doc "The fixture's README, which records its digests."
  @spec readme_path() :: Path.t()
  def readme_path, do: @readme

  # ---------------------------------------------------------------------------
  # The estate
  # ---------------------------------------------------------------------------

  @doc """
  Lay a seed at `seed` whose catalyst is the fixture and whose soul runs on
  it, and answer `seed`. `opts[:limits]` is merged over the limits the
  fixture's manifest asks for, which the consent minted for it grants.
  """
  @spec lay_seed!(Path.t(), keyword()) :: Path.t()
  def lay_seed!(seed, opts \\ []) do
    unit = Path.join([seed, "components", "catalysts", "local", @name, @version])
    File.mkdir_p!(unit)
    File.cp!(@wasm, Path.join(unit, "catalyst.wasm"))

    manifest = %{
      "name" => @name,
      "type" => "catalyst",
      "version" => @version,
      "publisher" => "local",
      "description" => "A model/chat@1 catalyst that plays the script its request carries",
      "contracts" => [Cyfr.Models.chat_contract()],
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:#{@name}",
          "reason" => "to read a key as a model catalyst does",
          "required" => true,
          "fields" => [@key_field]
        }
      },
      "caps" => %{"limits" => Map.merge(@limits, Keyword.get(opts, :limits, %{}))}
    }

    File.write!(Path.join(unit, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.mkdir_p!(Path.join(seed, "aqua"))

    policy = Enum.map_join(@tool_policy, "\n", fn {key, mode} -> "  #{key}: #{mode}" end)

    File.write!(Path.join([seed, "aqua", "aqua.md"]), """
    ---
    title: AQUA
    catalyst_ref: #{@ref}
    model: #{@name}
    tool_policy:
    #{policy}
    ---

    You answer the person.
    """)

    seed
  end

  @doc """
  A fresh group estate of a person of its own, filled from the configured
  seed as a person's estate is. Answers the person's context in it.
  """
  @spec estate!() :: Sanctum.Context.t()
  def estate! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|chat-fixture-#{n}",
        provider: "github",
        email: "chat-fixture-#{n}@example.com",
        verified: true,
        name: "Fixture #{n}"
      })

    {:ok, group} = Athanors.create_group(user.id, "Chat fixture #{n}")
    {:ok, ctx} = Sanctum.Context.focus(%{Sanctum.TestContext.local() | user_id: user.id}, group)
    {:ok, %{provisioned_at: %DateTime{}}} = Compendium.Provisioning.provision(group, ctx)
    ctx
  end

  @doc "Connect `key` to the fixture as a person does, through the consent walk."
  @spec bind_key!(Sanctum.Context.t(), String.t()) :: :ok
  def bind_key!(ctx, key) when is_binary(key) do
    _entry = Sanctum.Test.ConsentFixtures.bind_key!(ctx, @ref, %{@key_field => key})
    :ok
  end

  # ---------------------------------------------------------------------------
  # The script
  # ---------------------------------------------------------------------------

  @doc "The line a person sends: `line`, then the script of `steps` in a fenced block."
  @spec message([map()], String.t()) :: String.t()
  def message(steps, line \\ "@aqua play the script") when is_list(steps) do
    "#{line}\n#{@fence}#{@name}\n#{Jason.encode!(%{"steps" => steps})}\n#{@fence}"
  end

  @doc "A `text.delta` event."
  def text(text), do: %{"type" => "text.delta", "text" => text}

  @doc "A `tool_call.start` event."
  def call_start(index, id, name),
    do: %{"type" => "tool_call.start", "index" => index, "id" => id, "name" => name}

  @doc "A `tool_call.delta` event: a fragment of the call's JSON arguments."
  def call_delta(index, fragment),
    do: %{"type" => "tool_call.delta", "index" => index, "arguments" => fragment}

  @doc "A `tool_call.end` event."
  def call_end(index), do: %{"type" => "tool_call.end", "index" => index}

  @doc "A `usage` event."
  def usage(usage), do: %{"type" => "usage", "usage" => usage}

  @doc "A `stop` event."
  def stop(reason), do: %{"type" => "stop", "stop_reason" => reason}

  @doc "An `error` event."
  def error(type, message),
    do: %{"type" => "error", "error" => %{"type" => type, "message" => message}}

  @doc "The contract's usage map."
  def tokens(input, output), do: %{"input_tokens" => input, "output_tokens" => output}

  @doc "A `text` content block."
  def text_block(text), do: %{"type" => "text", "text" => text}

  @doc "A `tool_call` content block."
  def call_block(id, name, arguments),
    do: %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments}

  @doc "A contract response."
  def answer(content, stop_reason, usage),
    do: %{
      "model" => @name,
      "content" => content,
      "stop_reason" => stop_reason,
      "usage" => usage
    }

  @doc "The bound key, as a script names it without holding it."
  def key, do: "{{key}}"

  @doc "The bound key's bytes `from..to`; `to` nil is the key's end."
  def key(from, to \\ nil), do: "{{key:#{from}:#{to}}}"

  @doc "A string of `text` repeated to `bytes` bytes, made in the fixture."
  def fill(text, bytes), do: %{"$fill" => text, "bytes" => bytes}

  @doc "`event` emitted `times` times, reported as counts."
  def repeat(times, event), do: %{"$repeat" => times, "event" => event}

  @doc """
  `text` cut at the byte offsets `at`, each of which must fall between two
  characters: what a catalyst can hand `emit`, whose events are JSON text.
  """
  @spec fragments(String.t(), [non_neg_integer()]) :: [String.t()]
  def fragments(text, at) do
    bounds = Enum.sort(Enum.uniq([0 | at] ++ [byte_size(text)]))

    for [from, to] <- Enum.chunk_every(bounds, 2, 1, :discard) do
      fragment = binary_part(text, from, to - from)
      if not String.valid?(fragment), do: raise(ArgumentError, "#{from}..#{to} cuts a character")
      fragment
    end
  end

  # ---------------------------------------------------------------------------
  # Watching
  # ---------------------------------------------------------------------------

  defmodule Observer do
    @moduledoc false
    use GenServer

    def start_link({ctx, thread_id}), do: GenServer.start_link(__MODULE__, {ctx, thread_id})

    @impl true
    def init({ctx, thread_id}) do
      :ok = Aqua.Runner.subscribe(thread_id, ctx.athanor_id)
      :ok = Phoenix.PubSub.subscribe(Emissary.PubSub, Cyfr.Bus.executions(ctx.athanor_id))
      {:ok, %{ctx: ctx, thread: [], started: [], streams: %{}}}
    end

    @impl true
    def handle_call(:seen, _from, state) do
      streams =
        Map.new(state.streams, fn {id, {_numbers, events}} -> {id, Enum.reverse(events)} end)

      seen = %{
        thread: Enum.reverse(state.thread),
        started: Enum.reverse(state.started),
        streams: streams
      }

      {:reply, seen, state}
    end

    @impl true
    def handle_info({:thread, _thread_id, event}, state),
      do: {:noreply, %{state | thread: [event | state.thread]}}

    def handle_info({:execution_started, %{execution_id: id} = metadata, _measurements}, state) do
      :ok = Cyfr.Execution.subscribe_events(id, state.ctx)
      replayed = Cyfr.Execution.events_since(id, {0, 0}, state.ctx.athanor_id)

      state =
        Enum.reduce(replayed, %{state | started: [metadata | state.started]}, &keep(&2, id, &1))

      {:noreply, state}
    end

    def handle_info({:execution_event, %{execution_id: id} = event}, state),
      do: {:noreply, keep(state, id, event)}

    def handle_info(_other, state), do: {:noreply, state}

    # An event is kept once, by its number, in the order it arrived: what the
    # replay answered first, then what the topic carried.
    defp keep(state, id, event) do
      {numbers, events} = Map.get(state.streams, id, {MapSet.new(), []})

      if MapSet.member?(numbers, event.sequence) do
        state
      else
        kept = {MapSet.put(numbers, event.sequence), [event | events]}
        %{state | streams: Map.put(state.streams, id, kept)}
      end
    end
  end

  @doc "Start a viewer of `thread_id` and of every execution the estate starts."
  @spec observe!(Sanctum.Context.t(), String.t()) :: pid()
  def observe!(ctx, thread_id) do
    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec({Observer, {ctx, thread_id}}, id: make_ref())
    )
  end

  @doc """
  What the viewer has seen: `thread`, the thread topic's events in order;
  `started`, the metadata of each execution announced; `streams`, each
  execution's events by id, in the order they arrived.
  """
  @spec seen(pid()) :: %{thread: [term()], started: [map()], streams: %{String.t() => [map()]}}
  def seen(observer), do: GenServer.call(observer, :seen, 30_000)

  @doc "The guest's events of one stream: the `data` of each `emit`, in order."
  @spec emitted([map()]) :: [map()]
  def emitted(stream), do: for(%{type: "emit", data: data} <- stream, do: data)

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  @doc """
  What the fixture answered about the chat step run as `execution_id`: the
  step it played, the request it received and the host's reply to each
  emit, read from the execution's retained result.
  """
  @spec report(Sanctum.Context.t(), String.t()) :: map()
  def report(ctx, execution_id) do
    {:ok, _row, bytes} =
      Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), execution_id, "result")

    %{"data" => %{"fixture" => report}} = Jason.decode!(bytes)
    report
  end

  @doc """
  Every place `secret` shows in any form the host masks (itself, its
  base64 and its hex): `{:table, name, column}` for a column of any table
  of the database, `{:file, path}` for a file under the base path, and
  `{:term, label}` for each labelled term of `terms`.
  """
  @spec leaks(String.t(), keyword()) :: [term()]
  def leaks(secret, terms \\ []) when is_binary(secret) do
    forms = [
      secret,
      Base.encode64(secret),
      Base.url_encode64(secret),
      Base.encode16(secret, case: :lower),
      Base.encode16(secret, case: :upper)
    ]

    shows? = fn value -> :binary.match(flat(value), forms) != :nomatch end

    in_tables =
      for table <- tables(),
          %{columns: columns, rows: rows} = Arca.Repo.query!(~s(SELECT * FROM "#{table}")),
          row <- rows,
          {column, value} <- Enum.zip(columns, row),
          shows?.(value),
          uniq: true,
          do: {:table, table, column}

    in_files =
      for path <- files(Application.fetch_env!(:cyfr, :base_path)),
          shows?.(File.read!(path)),
          do: {:file, path}

    in_terms = for {label, term} <- terms, shows?.(term), do: {:term, label}

    in_tables ++ in_files ++ in_terms
  end

  defp flat(value) when is_binary(value), do: value
  defp flat(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp tables do
    sql =
      if Cyfr.RuntimeConfig.repo_adapter() == Ecto.Adapters.Postgres,
        do: "SELECT tablename FROM pg_tables WHERE schemaname = current_schema()",
        else: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"

    %{rows: rows} = Arca.Repo.query!(sql)
    Enum.map(rows, fn [name] -> name end)
  end

  defp files(root) do
    case File.ls(root) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(root, name)
          if File.dir?(path), do: files(path), else: [path]
        end)

      {:error, _} ->
        []
    end
  end
end
