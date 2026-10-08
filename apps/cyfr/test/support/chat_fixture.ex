# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ChatFixture do
  @moduledoc """
  What a test needs to drive a turn on the chat fixture
  (`test_wasm/chat_fixture/`), a `model/chat@1` catalyst the Opus service
  runs for real, which plays the script the turn's message carries and
  answers what it was given.

  - The athanor: `lay_seed!/2` lays a seed whose only catalyst is the
    fixture, in the mode the test names, and whose soul runs on it with a
    small tool policy of catalog operations; `athanor!/0` fills a fresh
    group athanor from the configured seed the way a person's is filled
    (`Compendium.Provisioning.provision/2`). In `:disclosed` mode the need
    declares no attach rule and the fixture reads its key: `bind_key!/2`
    connects a disclosed key through the consent walk. In `:attach` mode
    the need attaches the key as `x-api-key` and the fixture never reads
    it: `upstream!/1` starts the loopback upstream its egress names, and
    `offer_instance_entry!/4`, run before `athanor!/0`, offers everyone an
    instance entry to that upstream, which the athanor's first sign-in
    binds.
  - The script: `message/2` is the line a person sends, the script in a
    fenced block of it; `text/1`, `call_start/3`, `call_delta/2`,
    `call_end/1`, `usage/1`, `stop/1` and `error/2` are the contract's
    seven stream events; `key/0`, `key/2`, `fill/2` and `repeat/2` are the
    fixture's own words, and `attached_request/3` a step's attached
    request to the upstream (see its README).
  - Watching: `observe!/2` starts a viewer that holds no handle on the
    engine — it keeps what the thread's topic carries and, for every
    execution the athanor's execution topic announces, what that
    execution's event stream carries in the order it arrives, caught up
    from the replay window so nothing emitted before it subscribed is
    missed. `seen/1` answers both.
  - Reading: `report/2` is what the fixture answered about a chat step
    (the request it received, the host's reply to each emit and, in attach
    mode, the attached request's answer), read from the step's retained
    result; `upstream_request!/1` is the next request the upstream
    received; `leaks/2` names every place a credential shows: a column of
    any table, a file under the base path, or a term the caller passes.
  """

  alias Sanctum.Tenancy.{Athanors, Users}

  @wasm Path.expand("test_wasm/chat_fixture/chat_fixture.wasm", __DIR__)
  @readme Path.expand("test_wasm/chat_fixture/README.md", __DIR__)
  @name "chat-fixture"
  @ref "catalyst:local.#{@name}"
  @version "0.1.0"
  @key_field "FIXTURE_API_KEY"
  @fence "```"

  # Attach mode: the need's rule, the upstream the egress names and the
  # paths an offered entry's destination admits.
  @attach_rule %{"in" => "header", "name" => "x-api-key", "template" => "{value}"}
  @upstream_host "127.0.0.1"
  @upstream_paths ["/v1/"]
  # The upstream reads at most this much of a request, and answers 413 past it.
  @upstream_max_body 1_048_576

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
  # The athanor
  # ---------------------------------------------------------------------------

  @doc """
  Lay a seed at `seed` whose catalyst is the fixture and whose soul runs on
  it, and answer `seed`. `opts[:mode]` is required: `:disclosed`, the need
  declaring no attach rule, so the fixture reads the key bound to it; or
  `:attach`, the need attaching the key as `x-api-key` to the loopback
  upstream (`upstream!/1`), whose address, scheme and method its egress
  names. `opts[:limits]` is merged over the limits the fixture's manifest
  asks for, which the consent minted for it grants.
  """
  @spec lay_seed!(Path.t(), keyword()) :: Path.t()
  def lay_seed!(seed, opts) do
    unit = Path.join([seed, "components", "catalysts", "local", @name, @version])
    File.mkdir_p!(unit)
    File.cp!(@wasm, Path.join(unit, "catalyst.wasm"))
    limits = Map.merge(@limits, Keyword.get(opts, :limits, %{}))

    {need, caps} =
      case Keyword.fetch!(opts, :mode) do
        :disclosed ->
          {%{"reason" => "to read a key as a model catalyst does"}, %{"limits" => limits}}

        :attach ->
          {%{
             "reason" => "to have CYFR attach a key to its requests",
             "attach" => @attach_rule,
             "hosts" => [@upstream_host]
           },
           %{
             "egress" => %{
               "domains" => [@upstream_host],
               "schemes" => ["http"],
               "methods" => ["POST"],
               "private_ips" => [@upstream_host]
             },
             "limits" => limits
           }}
      end

    manifest = %{
      "name" => @name,
      "type" => "catalyst",
      "version" => @version,
      "publisher" => "local",
      "description" => "A model/chat@1 catalyst that plays the script its request carries",
      "contracts" => [Prima.Model.chat_contract()],
      "needs" => %{
        "api_key" =>
          Map.merge(
            %{"type" => "api_key:#{@name}", "required" => true, "fields" => [@key_field]},
            need
          )
      },
      "caps" => caps
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
  A fresh group athanor of a person of its own, filled from the configured
  seed as a person's athanor is. Answers the person's context in it.
  """
  @spec athanor!() :: Sanctum.Context.t()
  def athanor! do
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

  @doc """
  Connect `key` to the fixture laid in `:disclosed` mode as a person does,
  through the consent walk: a disclosed entry, which the fixture reads.
  """
  @spec bind_key!(Sanctum.Context.t(), String.t()) :: :ok
  def bind_key!(ctx, key) when is_binary(key) do
    _entry = Sanctum.Test.ConsentFixtures.bind_key!(ctx, @ref, %{@key_field => key})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Attach mode
  # ---------------------------------------------------------------------------

  defmodule Upstream do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    # Every request is told to the test that started the upstream, whole
    # within the bound, and answered with the body it was given.
    @impl true
    def call(conn, %{parent: parent, answer: answer, max_body: max_body}) do
      case read_body(conn, length: max_body) do
        {:ok, body, conn} ->
          send(parent, {
            Cyfr.Test.ChatFixture,
            :upstream,
            %{method: conn.method, path: conn.request_path, headers: conn.req_headers, body: body}
          })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, answer)

        {:more, _partial, conn} ->
          send_resp(conn, 413, "")
      end
    end
  end

  @doc """
  Start the loopback upstream the fixture's attach-mode egress names, on a
  port of the system's choosing, under the test's supervisor, so it stops
  with the test. It tells the test each request it receives
  (`upstream_request!/1`), reading at most 1 MiB of a body, and answers
  every one 200 with `answer`. Answers the port.
  """
  @spec upstream!(String.t()) :: :inet.port_number()
  def upstream!(answer \\ ~s({"upstream":"answered"})) when is_binary(answer) do
    plug = {Upstream, %{parent: self(), answer: answer, max_body: @upstream_max_body}}

    server =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: make_ref()
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  @doc """
  The next request the upstream received, as `%{method, path, headers,
  body}`, waiting at most `timeout` ms.
  """
  @spec upstream_request!(timeout()) :: map()
  def upstream_request!(timeout \\ 5_000) do
    receive do
      {__MODULE__, :upstream, request} -> request
    after
      timeout -> ExUnit.Assertions.flunk("the upstream received nothing")
    end
  end

  @doc """
  A platform administrator of the instance, a person of their own: who
  offers, caps and revokes an instance entry.
  """
  @spec instance_admin!() :: Sanctum.Context.t()
  def instance_admin! do
    {ctx, _user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    %{ctx | platform_admin: true}
  end

  @doc """
  Offer everyone an instance entry of the fixture's provider holding `key`
  as its field, to the upstream at `port`: `http`, `POST` and the paths
  under `/v1/`, under the component policy it is created with (`any`).
  `opts` are merged into the creation's params, the caps
  (`:person_daily`, `:total_daily`) among them. Run before `athanor!/0`,
  whose first sign-in binds it. Answers the entry.
  """
  @spec offer_instance_entry!(Sanctum.Context.t(), :inet.port_number(), String.t(), map()) ::
          map()
  def offer_instance_entry!(admin, port, key, opts \\ %{}) when is_binary(key) do
    params =
      Map.merge(
        %{
          name: "chat-fixture-#{System.unique_integer([:positive])}",
          kind: "api_key",
          provider_hint: @name,
          fields: %{@key_field => key},
          destination: %{
            "hosts" => [@upstream_host],
            "scheme" => "http",
            "port" => port,
            "methods" => ["POST"],
            "paths" => @upstream_paths
          },
          audience: "everyone"
        },
        opts
      )

    confirmed =
      Sanctum.TestContext.confirmed(admin, :credential_entry, %{
        operation: "instance_entry.create",
        arguments: params,
        resource: params.name
      })

    {:ok, entry} = Sanctum.InstanceEntries.create(confirmed, params)
    entry
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
  A step's attached request: a `POST` of `body` to `path` on the upstream at
  `port`, which the fixture makes on its connection before it plays the
  step, reading no key.
  """
  def attached_request(port, path, body),
    do: %{
      "method" => "POST",
      "url" => "http://#{@upstream_host}:#{port}#{path}",
      "headers" => %{"content-type" => "application/json"},
      "body" => body
    }

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
      actor = Sanctum.Context.actor(ctx)
      :ok = Aqua.Runner.subscribe(thread_id, ctx.athanor_id)
      :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.executions(actor))
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
    def handle_info(%Cyfr.Bus.ThreadEvent{kind: kind, data: data}, state),
      do: {:noreply, %{state | thread: [{kind, data} | state.thread]}}

    def handle_info(%Cyfr.Bus.Execution{kind: :started, execution_id: id} = started, state) do
      :ok = Crucible.subscribe_events(id, state.ctx)
      replayed = Crucible.events_since(id, {0, 0}, state.ctx.athanor_id)

      state =
        Enum.reduce(replayed, %{state | started: [started | state.started]}, &keep(&2, id, &1))

      {:noreply, state}
    end

    def handle_info(%Cyfr.Bus.ExecutionEvent{execution_id: id} = event, state),
      do: {:noreply, keep(state, id, Cyfr.Bus.ExecutionEvent.event(event))}

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

  @doc "Start a viewer of `thread_id` and of every execution the athanor starts."
  @spec observe!(Sanctum.Context.t(), String.t()) :: pid()
  def observe!(ctx, thread_id) do
    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec({Observer, {ctx, thread_id}}, id: make_ref())
    )
  end

  @doc """
  What the viewer has seen: `thread`, the thread topic's events in order as
  `{kind, data}`; `started`, each execution announced (`Cyfr.Bus.Execution`);
  `streams`, each execution's events by id, in the order they arrived.
  """
  @spec seen(pid()) :: %{
          thread: [{atom(), term()}],
          started: [Cyfr.Bus.Execution.t()],
          streams: %{String.t() => [map()]}
        }
  def seen(observer), do: GenServer.call(observer, :seen, 30_000)

  @doc "The guest's events of one stream: the `data` of each `emit`, in order."
  @spec emitted([map()]) :: [map()]
  def emitted(stream), do: for(%{type: "emit", data: data} <- stream, do: data)

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  @doc """
  What the fixture answered about the chat step run as `execution_id`: the
  step it played, the request it received, the host's reply to each emit
  and, in attach mode, the attached request's answer, read from the
  execution's retained result.
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
      for path <- files(Application.fetch_env!(:arca, :base_path)),
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
