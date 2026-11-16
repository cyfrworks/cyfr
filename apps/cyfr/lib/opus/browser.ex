# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Browser do
  @moduledoc """
  Aqua's browser, held for one person: the session the browser driver
  runs in (the program row of the browser's own definition,
  `Opus.Programs.Definition.browser?/1`), which starts Chrome over its
  debugging pipe inside the box, with its profile in the row's kept
  folder. The browser is the person's: its session's owner is the
  person's browser (`Opus.Programs.browser/2`, named here and nowhere
  else), not a turn, so it outlasts the turn that started it and serves
  every later turn of that person.

  ## Who acts on it

  `act/3` runs one action of the browser tool for a caller the session
  owner proves (`Opus.Programs.caller/1`): a running turn of the person
  that made the call itself, by S36's proof from the store. Any other
  caller, a key, a frame, a component a turn started, or a turn that is
  paused or was superseded, reaches no window (`:not_owned`). The window
  is the one of the thread the proved turn runs in, named from the
  lineage the gate stamped and from no argument. Whether a request
  reaches the driver is decided once, as its writer is about to write its
  first byte: it must still be wanted, that is still waiting here
  unanswered, its caller still waiting for it and its turn still running.
  A request whose time ran out, whose turn was cancelled or superseded,
  or whose caller died while it waited sends nothing. Whether Aqua may
  use the browser at all is the person's browser setting, which the
  tool's provider reads before it calls here (`Aqua.BrowserSetting`) and
  hands to `act/4` as a check, which the holder reads again before it
  starts the browser (below).

  ## Its life

  One holder process per person, found by name, starts the session when
  a turn first needs it, or when the person watches a window, and is its
  one attached process. The holder is registered under its name before
  it reads the setting, and it reads the setting, through the check
  `act/4` or `watch/4` was handed, before it starts anything; turning the
  setting off writes it before it stops the holder it finds by that name
  (`stop/2`). So a holder the stop did not find registered after the
  write, reads the setting off, starts nothing and ends, answering what
  it holds `:turned_off`. It ends the session at its idle stop (no action
  and no watch for the `browser_idle_ms` platform setting's time), on
  `stop/2` (the browser setting went off), and the
  session ends as any does: its program exits, the person closes it from
  what is running, its row changes, its person no longer stands. Every
  request waiting then is answered, and the profile stays in its folder.
  A holder that finds a session of the person's browser it does not hold
  closes it before it starts its own. At most four windows are open at
  once; a fifth is refused (`:too_many_windows`).

  ## The driver's protocol

  Every message is one frame (`Opus.Browser.Frame`). A request names its
  id, its window, its operation and its arguments; the driver answers it
  in numbered chunks, the next only after this holder acknowledged the
  last on the session's input, and keeps it until the last is
  acknowledged or it has kept it too long. An acknowledgement names the
  last chunk of the unbroken run this holder holds, never one past a
  gap; the acknowledgement of a response's last chunk lets it go, held
  whole or wanted no more. A response's text is at most
  `Opus.Browser.Frame.max_response/0` bytes, the bound the vector file
  states for both sides: this holder keeps no more of one than that
  while it assembles it, since the browser's uid can speak this
  protocol, and refuses one past it (`:response_too_large`). A delivery of the session's
  output is taken only once every whole frame in it is read, so what the
  driver prints faster waits in the service's bounded buffer. After a
  replacement tail, the bytes before the first whole frame are dropped
  and each response still incomplete is asked for again from its first
  missing chunk (`again`), never sent again as a request, so no action
  runs twice; one the driver no longer holds is refused `:unavailable`,
  as is one not answered in time.

  ## The person's watch

  `watch/4` is the person at a screen watching one window (C12), proved
  by the session owner as a person and no other caller: it starts the
  browser when none runs, as an action does, and asks the driver for that
  window's cast, a request of op `cast` whose id names the cast from then
  on. Its messages go to the process that asked, the viewer, as
  `{Opus.Browser, watch, message}`, `watch` the handle `seen/2`,
  `input/2` and `unwatch/1` take, the first `:watching` once it is
  admitted. Each image of it is `{:image, n, output}`, its JPEG an
  `Opus.Programs.Output`, handed to no other process; the next is handed
  only once the viewer said it drew this one (`seen/2`), and only then is
  the driver told, so a viewer that does not say so is sent no further
  image, while every action's response still arrives whole beside it. A
  window that does not stand, or that closed, is `:waiting`, and its
  cast is asked again once an action opens it. The
  viewer's input (`input/2`, events `Opus.Browser.Input` reads) goes to
  that window alone, at most `Opus.Browser.Input.max_events/0` events
  waiting, the rest dropped, each write decided by the writer as a
  request is, just before its first byte. A watch is asked
  with the moment its caller stops waiting, and the holder admits nothing
  past it; a caller whose wait ran out withdraws it. A watch ends with
  `{:ended, reason}` once, and nothing after: on
  `unwatch/1`, the viewer's exit, a newer watch of its window
  (`:replaced`), `stop/2`, or the session's end. Once it ended, no image
  of its cast and no input of its viewer goes anywhere. After a
  replacement tail every cast is ended and asked for anew, so an image
  cut there is never shown and the cast goes on with the next. A watch
  keeps the browser from its idle stop. At most `max_windows/0` windows
  are watched at once (`:too_many_watches`).
  """

  use GenServer, restart: :temporary

  alias Opus.Browser.Frame
  alias Opus.Programs

  @registry Opus.Browser.Registry
  @holders Opus.Browser.Holders
  @max_windows 4
  @ops ~w(open read click type key page screenshot close)
  @openers ~w(open page)
  @request_ms 90_000
  # How long a start and the driver's hello may take, together.
  @start_ms 120_000
  @answer_margin_ms 5_000
  @rows 50
  @cols 200
  # How long a watch's caller waits for its holder, which answers at once:
  # past it the holder admits nothing for that caller.
  @watch_ms 5_000

  @doc "The most windows one browser holds at once."
  @spec max_windows() :: pos_integer()
  def max_windows, do: @max_windows

  @doc "The most bytes a response's text may hold (`Opus.Browser.Frame.max_response/0`)."
  @spec max_response() :: pos_integer()
  def max_response, do: Frame.max_response()

  @doc "The operations `act/3` runs."
  @spec ops() :: [String.t()]
  def ops, do: @ops

  @doc """
  The bound a newly added browser's row is given (the `browser_memory_bytes`
  platform setting).
  """
  @spec memory_bytes() :: pos_integer()
  def memory_bytes, do: setting("browser_memory_bytes")

  @doc """
  The athanor's row of Aqua's browser: `{:ok, row}`, `{:error, :not_added}`
  when it holds none, `{:error, :not_browser}` for a row of the browser's
  name with another definition, `{:error, :disabled}` for one that is
  disabled.
  """
  @spec row(String.t()) :: {:ok, map()} | {:error, term()}
  def row(athanor_id) when is_binary(athanor_id) do
    name = Programs.Definition.browser_name()

    case Arca.McpServerStorage.list(Prima.Actor.in_athanor(athanor_id)) do
      {:ok, rows} ->
        case Enum.find(rows, &(&1.name == name)) do
          nil -> {:error, :not_added}
          row -> browser_row(row)
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp browser_row(row) do
    cond do
      not Programs.Definition.browser?(row) -> {:error, :not_browser}
      row.enabled != true -> {:error, :disabled}
      true -> {:ok, row}
    end
  end

  @doc """
  Run `op` (`ops/0`) with `args` in the window of the caller's thread:
  the caller is a turn as `Opus.Programs.turn/2` names one, proved here.
  Answers the driver's answer, `{:error, {:driver, code, sentence}}`
  for one the driver refused, or `{:error, reason}`: `:not_owned` for a
  caller that is no running turn of a standing person, `:too_many_windows`,
  `:not_added`, `:not_browser`, `:disabled`, `:unavailable` (the
  response is gone or did not come in time), `{:ended, reason}` (the
  session ended under the request), `:turned_off` (`stop/2` meanwhile),
  `:too_large`, or a start's refusal.

  `allowed?` answers, when it is called, whether the person's browser
  setting lets Aqua use the browser now. The holder calls it before it
  starts the browser for this request, after it is registered; with it
  `false` the request is answered `:turned_off` and nothing starts.
  """
  @spec act(Programs.caller(), String.t(), map(), (-> boolean())) ::
          {:ok, map()} | {:error, term()}
  def act({:turn, _ctx, lineage} = caller, op, args, allowed?)
      when op in @ops and is_map(args) and is_function(allowed?, 0) do
    with {:ok, {athanor_id, user_id, turn_id}} <- turn(caller),
         window when is_binary(window) <- Map.get(lineage, "thread_id"),
         {:ok, pid} <- holder(athanor_id, user_id) do
      # What a turn types, an address it opens and a page it writes travel
      # as their JSON in an `Opus.Programs.Output`, which shows its size
      # alone, so no debug log, status or crash report prints them.
      GenServer.call(
        pid,
        {:act, caller, turn_id, window, op, Programs.Output.new(Jason.encode!(args)), allowed?},
        @start_ms + @request_ms + @answer_margin_ms
      )
    else
      {:error, reason} -> {:error, reason}
      _no_thread -> {:error, :not_owned}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def act(_caller, _op, _args, _allowed?), do: {:error, :not_owned}

  @typedoc "A watch of a window: its holder and the reference its messages carry."
  @opaque watch :: {pid(), reference()}

  @doc """
  Watch `window` of the person's browser as `ctx`, a person at a screen
  whom the session owner proves, from the calling process, which is the
  viewer: the browser starts when none runs, after `allowed?` (as
  `act/4`'s) says it may, and the window's images are scaled to fit
  `size`. Answers the watch, whose messages carry its reference
  (moduledoc), or `:not_owned` for any caller that is not a person at a
  screen, `:too_many_watches`, `:turned_off`, `:unavailable`.
  """
  @spec watch(
          Sanctum.Context.t(),
          String.t(),
          %{width: pos_integer(), height: pos_integer()},
          (-> boolean())
        ) ::
          {:ok, watch()} | {:error, term()}
  def watch(%Sanctum.Context{} = ctx, window, %{width: width, height: height}, allowed?)
      when is_binary(window) and window != "" and width in 16..4096 and height in 16..4096 and
             is_function(allowed?, 0) do
    with {:ok, {athanor_id, user_id}} <- person_of(ctx),
         {:ok, pid} <- holder(athanor_id, user_id) do
      ask(pid, window, %{width: width, height: height}, allowed?)
    end
  end

  def watch(_ctx, _window, _size, _allowed?), do: {:error, :not_owned}

  # The watch is asked with the moment its caller stops waiting: the holder
  # admits nothing past it. A caller whose wait ran out withdraws the ask,
  # which reaches the holder after it, so a watch it was not told of is
  # ended as soon as it was admitted.
  defp ask(pid, window, size, allowed?) do
    ask = make_ref()
    deadline = now() + @watch_ms

    try do
      GenServer.call(
        pid,
        {:watch, self(), ask, deadline, window, size, allowed?},
        @watch_ms + @answer_margin_ms
      )
    catch
      :exit, _ ->
        GenServer.cast(pid, {:withdraw, ask, self()})
        {:error, :unavailable}
    end
  end

  @doc "The viewer drew image `n` of its watch; the next may come."
  @spec seen(watch(), pos_integer()) :: :ok
  def seen({pid, ref}, n) when is_pid(pid) and is_reference(ref) and is_integer(n),
    do: GenServer.cast(pid, {:seen, ref, self(), n})

  @doc """
  The viewer's input for the window it watches: `:ok` once it is handed
  to the holder, which drops it when the watch ended or too much waits,
  or `:bad_input` for events `Opus.Browser.Input` does not read.
  """
  @spec input(watch(), [map()]) :: :ok | {:error, :bad_input}
  def input({pid, ref}, events) when is_pid(pid) and is_reference(ref) do
    case Opus.Browser.Input.events(events) do
      # What the person types travels as its JSON in an
      # `Opus.Programs.Output`, which shows its size alone.
      {:ok, events} ->
        GenServer.cast(
          pid,
          {:input, ref, self(), Enum.map(events, &Programs.Output.new(Jason.encode!(&1)))}
        )

      :error ->
        {:error, :bad_input}
    end
  end

  @doc "End the watch; the browser goes on."
  @spec unwatch(watch()) :: :ok
  def unwatch({pid, ref}) when is_pid(pid) and is_reference(ref),
    do: GenServer.cast(pid, {:unwatch, ref, self()})

  @doc """
  The caller a call of the browser tool in a turn's chain is: its context
  and the lineage the gate stamped on its arguments
  (`Opus.Programs.turn/2`), which `act/3` and `turn/1` prove.
  """
  @spec caller(Sanctum.Context.t(), map()) :: Programs.caller()
  def caller(%Sanctum.Context{} = ctx, args) when is_map(args), do: Programs.turn(ctx, args)

  @doc """
  Whether the context is a person at a screen, standing, as the session
  owner proves one (`Opus.Programs.caller/1`): `:ok`, `:not_owned` for any
  other caller.
  """
  @spec person(Sanctum.Context.t()) :: :ok | {:error, :not_owned | :unavailable}
  def person(%Sanctum.Context{} = ctx) do
    with {:ok, _person} <- person_of(ctx), do: :ok
  end

  defp person_of(ctx) do
    case Programs.caller(ctx) do
      {:ok, {_athanor_id, _user_id} = person} -> {:ok, person}
      {:error, :unavailable} -> {:error, :unavailable}
      _not_a_person -> {:error, :not_owned}
    end
  end

  @doc """
  Whether `caller` is a running turn of a standing person, as `act/3`
  proves it: the turn's `{athanor, user, turn}`, or `:not_owned`.
  """
  @spec turn(Programs.caller()) ::
          {:ok, {String.t(), String.t(), String.t()}} | {:error, :not_owned | :unavailable}
  def turn(caller) do
    case Programs.caller(caller) do
      {:ok, {_athanor_id, _user_id, turn_id} = turn} when is_binary(turn_id) -> {:ok, turn}
      {:error, :unavailable} -> {:error, :unavailable}
      _not_a_running_turn -> {:error, :not_owned}
    end
  end

  @doc """
  End the person's browser, as the browser setting going off does: every
  request waiting is answered `:turned_off`, and its session is closed,
  its profile kept. A session of the person's browser that no holder
  holds is closed too. Answers once the close was asked, without waiting
  for a start under way: the session that start brings up is sent
  nothing and is closed as soon as the start answers, and its Chrome,
  started so that it reaches nothing by itself, has reached nothing.
  """
  @spec stop(String.t(), String.t()) :: :ok
  def stop(athanor_id, user_id) when is_binary(athanor_id) and is_binary(user_id) do
    case lookup(athanor_id, user_id) do
      nil -> close_running(Programs.browser(athanor_id, user_id))
      pid -> GenServer.call(pid, :stop, @start_ms)
    end

    :ok
  catch
    :exit, _ -> close_running(Programs.browser(athanor_id, user_id))
  end

  @doc """
  The windows the person's browser holds now, each named by its thread;
  none when no browser of theirs runs.
  """
  @spec windows(String.t(), String.t()) :: [String.t()]
  def windows(athanor_id, user_id) when is_binary(athanor_id) and is_binary(user_id) do
    case lookup(athanor_id, user_id) do
      nil -> []
      pid -> GenServer.call(pid, :windows, @watch_ms)
    end
  catch
    :exit, _ -> []
  end

  @doc "Whether the person's browser holds a session now."
  @spec running?(String.t(), String.t()) :: boolean()
  def running?(athanor_id, user_id) do
    match?({:ok, [_ | _]}, Programs.running(Programs.browser(athanor_id, user_id)))
  end

  defp lookup(athanor_id, user_id) do
    if Process.whereis(@registry) do
      case Registry.lookup(@registry, {athanor_id, user_id}) do
        [{pid, _}] -> pid
        [] -> nil
      end
    end
  end

  defp holder(athanor_id, user_id) do
    case lookup(athanor_id, user_id) do
      nil ->
        case DynamicSupervisor.start_child(@holders, {__MODULE__, {athanor_id, user_id}}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _reason} -> {:error, :unavailable}
        end

      pid ->
        {:ok, pid}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp close_running(browser) do
    case Programs.running(browser) do
      {:ok, sessions} -> Enum.each(sessions, &Programs.close(browser, &1.session))
      {:error, _not_standing_or_unanswered} -> :ok
    end

    :ok
  end

  # ===========================================================================
  # The holder
  # ===========================================================================

  @doc false
  def start_link({athanor_id, user_id}),
    do:
      GenServer.start_link(__MODULE__, {athanor_id, user_id},
        name: {:via, Registry, {@registry, {athanor_id, user_id}}}
      )

  @impl true
  def init({athanor_id, user_id}) do
    Process.flag(:trap_exit, true)
    owner = self()
    browser = Programs.browser(athanor_id, user_id)

    {:ok,
     %{
       athanor_id: athanor_id,
       user_id: user_id,
       browser: browser,
       session: nil,
       phase: :idle,
       starting: nil,
       buffer: Programs.Output.new(""),
       next_id: 1,
       pending: %{},
       queued: [],
       windows: MapSet.new(),
       watches: %{},
       last_act: now(),
       idle: nil,
       stopping: false,
       writer: spawn_link(fn -> write_loop(Process.monitor(owner), owner, browser) end)
     }}
  end

  @impl true
  def handle_call(
        {:act, caller, turn_id, window, op, %Programs.Output{} = args, allowed?},
        from,
        state
      ) do
    state = %{state | last_act: now()}

    request = %{
      kind: :act,
      from: from,
      caller: caller,
      turn_id: turn_id,
      window: window,
      op: op,
      args: args
    }

    cond do
      state.stopping ->
        {:reply, {:error, :turned_off}, state}

      opens_another?(state, window, op) ->
        {:reply, {:error, :too_many_windows}, state}

      state.phase == :ready ->
        {:noreply, state |> send_request(request) |> idle()}

      state.phase == :starting ->
        {:noreply, %{state | queued: state.queued ++ [request]}}

      true ->
        {:noreply, start_session(%{state | queued: [request]}, allowed?)}
    end
  end

  # Whether a request the writer is about to write is still wanted, the one
  # decision whether it reaches the driver: it still waits here, so nothing
  # answered it already (its time ran out, the session ended, the browser
  # was stopped); its caller still waits for it; and its turn still runs.
  # A request that is not wanted is settled here, at the moment it is
  # decided: its caller, if still waiting, is told its turn no longer owns
  # the work.
  def handle_call({:wanted, id}, _from, state) do
    case Map.fetch(state.pending, id) do
      :error ->
        {:reply, false, state}

      # A cast is wanted while its watch stands on it.
      {:ok, %{kind: :cast} = request} ->
        if watching?(state, request.watch, id),
          do: {:reply, true, state},
          else: {:reply, false, unwanted(state, id, request, nil)}

      {:ok, %{from: {caller_pid, _tag}} = request} ->
        cond do
          not Process.alive?(caller_pid) ->
            {:reply, false, unwanted(state, id, request, nil)}

          not owned?(request) ->
            {:reply, false, unwanted(state, id, request, {:error, :not_owned})}

          true ->
            {:reply, true, state}
        end
    end
  end

  def handle_call(:windows, _from, state), do: {:reply, MapSet.to_list(state.windows), state}

  # Input is wanted while its watch stands on the cast it was given for.
  def handle_call({:wanted_input, ref, cast}, _from, state),
    do: {:reply, watching?(state, ref, cast), state}

  def handle_call({:watch, viewer, ask, deadline, window, size, allowed?}, _from, state) do
    cond do
      # Its caller has stopped waiting: nothing is admitted for it.
      now() > deadline ->
        {:reply, {:error, :unavailable}, state}

      state.stopping ->
        {:reply, {:error, :turned_off}, state}

      not Map.has_key?(watched(state), window) and map_size(watched(state)) >= @max_windows ->
        {:reply, {:error, :too_many_watches}, state}

      true ->
        state =
          case watched(state)[window] do
            nil -> state
            older -> end_watch(state, older, :replaced)
          end

        ref = make_ref()

        watch = %{
          ref: ref,
          ask: ask,
          viewer: viewer,
          monitor: Process.monitor(viewer),
          window: window,
          size: size,
          cast: nil,
          reopened: false,
          shown: nil,
          held: nil,
          n: 0,
          input: [],
          writing: false
        }

        state = %{state | watches: Map.put(state.watches, ref, watch), last_act: now()}
        tell(watch, :watching)
        {:reply, {:ok, {self(), ref}}, state |> cast(ref, allowed?) |> idle()}
    end
  end

  # A stop during a start closes what the start opens once it answers.
  def handle_call(:stop, _from, %{starting: %Task{}} = state),
    do: {:reply, :ok, %{answer_all(state, {:error, :turned_off}) | stopping: true}}

  def handle_call(:stop, _from, state) do
    state = answer_all(state, {:error, :turned_off})
    {:stop, :normal, :ok, close_session(state)}
  end

  # The viewer drew image n: the driver is told, when it is of the cast
  # the watch stands on, and the image held since is handed.
  @impl true
  def handle_cast({:seen, ref, viewer, n}, state) do
    case state.watches[ref] do
      %{viewer: ^viewer, shown: {^n, cast, seq}} = watch ->
        if cast == watch.cast,
          do: write(state, Frame.message(%{"t" => "seen", "id" => cast, "seq" => seq}), :seen)

        watch = %{watch | shown: nil}

        case watch.held do
          {held_cast, held_seq, image} when held_cast == watch.cast ->
            {:noreply, hand(state, %{watch | held: nil}, held_seq, image)}

          _none_or_stale ->
            {:noreply, put_watch(state, %{watch | held: nil})}
        end

      _stale_or_another ->
        {:noreply, state}
    end
  end

  def handle_cast({:input, ref, viewer, events}, state) do
    case state.watches[ref] do
      %{viewer: ^viewer, cast: cast} = watch when is_integer(cast) ->
        room = Opus.Browser.Input.max_events() - length(watch.input)
        watch = %{watch | input: watch.input ++ Enum.take(events, max(room, 0))}
        {:noreply, state |> put_watch(watch) |> pump_input(ref)}

      _ended_waiting_or_another ->
        {:noreply, state}
    end
  end

  # A caller that stopped waiting for its watch withdraws it.
  def handle_cast({:withdraw, ask, viewer}, state) do
    case Enum.find(Map.values(state.watches), &(&1.ask == ask and &1.viewer == viewer)) do
      nil -> {:noreply, state}
      watch -> {:noreply, end_watch(state, watch, nil)}
    end
  end

  def handle_cast({:unwatch, ref, viewer}, state) do
    case state.watches[ref] do
      %{viewer: ^viewer} = watch -> {:noreply, end_watch(state, watch, nil)}
      _ended_or_another -> {:noreply, state}
    end
  end

  # The session's start, made off the holder so a slow service never
  # delays a delivery.
  @impl true
  def handle_info({ref, started}, %{starting: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    started(started, %{state | starting: nil})
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{starting: %Task{ref: ref}} = state),
    do: {:stop, :normal, answer_all(%{state | starting: nil}, {:error, :unavailable})}

  def handle_info({:DOWN, monitor, :process, _viewer, _reason} = message, state) do
    case Enum.find(Map.values(state.watches), &(&1.monitor == monitor)) do
      nil ->
        Prima.LoggerContext.unexpected(__MODULE__, message)
        {:noreply, state}

      watch ->
        {:noreply, end_watch(state, watch, nil)}
    end
  end

  def handle_info({:written, {:input, ref, _cast}}, state) do
    case state.watches[ref] do
      nil -> {:noreply, state}
      watch -> {:noreply, state |> put_watch(%{watch | writing: false}) |> pump_input(ref)}
    end
  end

  def handle_info({:EXIT, writer, reason}, %{writer: writer} = state),
    do: {:stop, reason, answer_all(state, {:error, :unavailable})}

  def handle_info({:EXIT, _task, _reason}, state), do: {:noreply, state}

  def handle_info({Programs, session, {kind, delivery, %Programs.Output{bytes: bytes}}}, state)
      when kind in [:bytes, :tail] and session == state.session do
    buffer = if kind == :tail, do: bytes, else: state.buffer.bytes <> bytes
    {bodies, rest} = Frame.decode(buffer)
    state = Enum.reduce(bodies, %{state | buffer: Programs.Output.new(rest)}, &frame/2)
    state = if kind == :tail, do: recover(state), else: state
    _ = Programs.taken(state.browser, session, delivery)
    {:noreply, idle(state)}
  end

  def handle_info({Programs, session, {:ended, reason}}, %{session: session} = state) do
    state = answer_all(%{state | session: nil}, {:error, {:ended, reason}})
    {:stop, :normal, state}
  end

  def handle_info({Programs, _another_session, _delivery}, state), do: {:noreply, state}

  def handle_info({:expired, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {request, pending} ->
        {:noreply,
         %{state | pending: pending} |> settle(request, {:error, :unavailable}) |> idle()}
    end
  end

  def handle_info(:hello_expired, %{phase: :starting} = state) do
    state = answer_all(state, {:error, :unavailable})
    {:stop, :normal, close_session(state)}
  end

  def handle_info(:hello_expired, state), do: {:noreply, state}

  def handle_info({:write_failed, {:request, id}, _reason}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {request, pending} ->
        Process.cancel_timer(request.timer)
        {:noreply, settle(%{state | pending: pending}, request, {:error, :unavailable})}
    end
  end

  def handle_info({:write_failed, _control, _reason}, state), do: {:noreply, state}

  def handle_info({:idle, token}, %{idle: {_timer, token}} = state) do
    left = idle_ms() - (now() - state.last_act)

    if state.pending == %{} and state.queued == [] and state.watches == %{} and left <= 0,
      do: {:stop, :normal, close_session(%{state | idle: nil})},
      else: {:noreply, idle(%{state | idle: nil})}
  end

  def handle_info({:idle, _stale}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # A holder that stops for any reason leaves no session it held running.
  @impl true
  def terminate(_reason, state) do
    _ = close_session(state)
    for watch <- Map.values(state.watches), do: tell(watch, {:ended, :unavailable})
    :ok
  end

  # What a page shows and what the person's turns type pass through here,
  # in its state, its messages and its replies: no status, debug log or
  # crash report prints a byte of either. Every binary its state, last
  # message, exit reason and debug log hold, at any depth, shows as its
  # size alone.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {key, value} when key in [:state, :message, :reason, :log] -> {key, scrub(value)}
      other -> other
    end)
  end

  defp scrub(binary) when is_binary(binary), do: "#{byte_size(binary)} bytes"

  defp scrub(%module{} = struct),
    do: {module, struct |> Map.from_struct() |> scrub()}

  defp scrub(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, scrub(value)} end)
  defp scrub([head | tail]), do: [scrub(head) | scrub(tail)]

  defp scrub(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> scrub() |> List.to_tuple()

  defp scrub(other), do: other

  # ---------------------------------------------------------------------------

  defp opens_another?(state, window, op) do
    op in @openers and not MapSet.member?(state.windows, window) and
      MapSet.size(opening(state) |> MapSet.put(window)) > @max_windows
  end

  # The windows open, and those a request on its way opens.
  defp opening(state) do
    on_the_way =
      for request <- Map.values(state.pending) ++ state.queued,
          request.op in @openers,
          do: request.window

    MapSet.union(state.windows, MapSet.new(on_the_way))
  end

  defp start_session(state, allowed?) do
    %{athanor_id: athanor_id, browser: browser} = state
    Process.send_after(self(), :hello_expired, @start_ms)
    holder = self()

    # The session is held by this process from the moment it is asked for,
    # not by the task that asks: it ends with this holder, however either
    # ends. The setting is read here, by a holder already registered, before
    # anything starts: one `stop/2` did not find reads it off.
    task =
      Task.async(fn ->
        with :ok <- if(allowed?.(), do: :ok, else: {:error, :turned_off}),
             {:ok, row} <- row(athanor_id),
             :ok <- close_running(browser) do
          Programs.start(browser, row.id, %{rows: @rows, cols: @cols, args: [], held_by: holder})
        end
      end)

    %{state | phase: :starting, starting: task}
  end

  defp started({:ok, session}, %{stopping: true} = state),
    do: {:stop, :normal, close_session(%{state | session: session})}

  defp started({:ok, session}, state) do
    case Programs.attach(state.browser, session) do
      {:ok, %{tail: %Programs.Output{bytes: tail}}} ->
        {bodies, rest} = Frame.decode(tail)
        state = %{state | session: session, buffer: Programs.Output.new(rest)}
        {:noreply, Enum.reduce(bodies, state, &frame/2)}

      {:error, _gone} ->
        {:stop, :normal, answer_all(state, {:error, :unavailable})}
    end
  end

  defp started({:error, reason}, state),
    do: {:stop, :normal, answer_all(state, {:error, reason})}

  # One frame the driver sent.
  defp frame(body, state) do
    case Jason.decode(body) do
      {:ok, %{"t" => "hello"} = hello} -> hello(hello, state)
      {:ok, %{"t" => "res"} = res} -> response(res, state)
      {:ok, %{"t" => "gone", "id" => id}} -> gone(id, state)
      {:ok, %{"t" => "image"} = image} -> image(image, state)
      {:ok, %{"t" => "uncast", "id" => cast}} -> uncast(cast, state)
      _unknown -> state
    end
  end

  # A driver that could not start Chrome is closed; its end, which names
  # the session still held here, stops this holder.
  defp hello(%{"error" => sentence}, %{phase: :starting} = state) when is_binary(sentence) do
    state = answer_all(state, {:error, {:driver, "start", sentence}})
    _ = Programs.close(state.browser, state.session)
    state
  end

  defp hello(_hello, %{phase: :starting} = state) do
    state = %{state | phase: :ready}

    Enum.reduce(state.queued, %{state | queued: []}, &send_request(&2, &1))
  end

  defp hello(_hello, state), do: state

  defp send_request(state, request) do
    id = state.next_id

    # The arguments' JSON, as the caller encoded it, is the frame's `args`.
    frame =
      Frame.encode(
        IO.iodata_to_binary([
          ~s({"t":"req","id":),
          Integer.to_string(id),
          ~s(,"win":),
          Jason.encode!(request.window),
          ~s(,"op":),
          Jason.encode!(request.op),
          ~s(,"args":),
          request.args.bytes,
          "}"
        ])
      )

    if byte_size(frame) > Frame.max_to_driver() do
      settle(state, Map.merge(request, %{id: id, timer: nil}), {:error, :too_large})
    else
      timer = Process.send_after(self(), {:expired, id}, @request_ms)
      request = Map.merge(request, %{id: id, timer: timer, parts: %{}, of: nil, size: 0})
      write(state, frame, {:request, id})
      state = %{state | next_id: id + 1, pending: Map.put(state.pending, id, request)}

      case request do
        %{kind: :cast, watch: ref} -> update_watch(state, ref, &%{&1 | cast: id, reopened: false})
        _action -> state
      end
    end
  end

  defp response(%{"id" => id, "seq" => seq, "of" => of, "part" => part}, state)
       when is_integer(id) and is_integer(seq) and is_integer(of) and seq >= 0 and seq < of and
              is_binary(part) do
    case {Map.get(state.pending, id), Base.decode64(part)} do
      {nil, _part} ->
        # A response no request waits for any more ends at once.
        acknowledge(state, id, of - 1)

      {request, {:ok, bytes}} when request.of in [nil, of] ->
        held_part = Map.get(request.parts, seq, Programs.Output.new(""))
        size = request.size - byte_size(held_part.bytes) + byte_size(bytes)

        if size > Frame.max_response() do
          # A response past the bound is taken no further and nothing more
          # of it is kept: the acknowledgement of its last chunk tells the
          # driver this holder wants no more of it.
          acknowledge(state, id, of - 1)
          refuse(state, id, request, {:error, :response_too_large})
        else
          parts = Map.put(request.parts, seq, Programs.Output.new(bytes))
          # A chunk past a gap is held and not acknowledged; one within the
          # unbroken run, a repeat among them, acknowledges the whole run.
          held = unbroken(parts)
          if seq <= held, do: acknowledge(state, id, held)

          if map_size(parts) == of,
            do: answer(state, id, request, Enum.map_join(0..(of - 1), &parts[&1].bytes)),
            else: %{
              state
              | pending: Map.put(state.pending, id, %{request | parts: parts, of: of, size: size})
            }
        end

      {request, _unreadable} ->
        acknowledge(state, id, of - 1)
        answer(state, id, request, nil)
    end
  end

  defp response(_malformed, state), do: state

  # The last chunk of the unbroken run held from the first, -1 for none.
  defp unbroken(parts) do
    Enum.reduce_while(0..map_size(parts)//1, -1, fn seq, last ->
      if Map.has_key?(parts, seq), do: {:cont, seq}, else: {:halt, last}
    end)
  end

  defp owned?(%{caller: caller, turn_id: turn_id}),
    do: match?({:ok, {_athanor_id, _user_id, ^turn_id}}, turn(caller))

  defp unwanted(state, id, request, reply) do
    Process.cancel_timer(request.timer)
    if reply, do: GenServer.reply(request.from, reply)
    idle(%{state | pending: Map.delete(state.pending, id)})
  end

  defp refuse(state, id, request, reply) do
    Process.cancel_timer(request.timer)
    settle(%{state | pending: Map.delete(state.pending, id)}, request, reply)
  end

  # A request's answer: an action's caller is replied to; a cast's watch
  # takes it, if it still stands on that cast.
  defp settle(state, %{kind: :cast} = request, reply), do: cast_answered(state, request, reply)

  defp settle(state, request, reply) do
    GenServer.reply(request.from, reply)
    state
  end

  defp gone(id, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {request, pending} ->
        Process.cancel_timer(request.timer)
        settle(%{state | pending: pending}, request, {:error, :unavailable})
    end
  end

  defp answer(state, id, request, text) do
    Process.cancel_timer(request.timer)
    state = %{state | pending: Map.delete(state.pending, id)}

    {reply, state} =
      case text && Jason.decode(text) do
        {:ok, %{"ok" => %{} = answer}} ->
          {{:ok, answer}, windows(state, request, :ok)}

        {:ok, %{"error" => %{"code" => code, "message" => sentence}}}
        when is_binary(code) and is_binary(sentence) ->
          {{:error, {:driver, code, sentence}}, windows(state, request, code)}

        _unreadable ->
          {{:error, :unavailable}, state}
      end

    state = settle(state, request, reply)

    case {request, reply} do
      {%{op: op, window: window}, {:ok, _answer}} when op in @openers -> opened(state, window)
      _other -> state
    end
  end

  defp windows(state, %{op: op, window: window}, :ok) when op in @openers,
    do: %{state | windows: MapSet.put(state.windows, window)}

  defp windows(state, %{op: "close", window: window}, :ok),
    do: %{state | windows: MapSet.delete(state.windows, window)}

  defp windows(state, %{window: window}, "no_window"),
    do: %{state | windows: MapSet.delete(state.windows, window)}

  defp windows(state, _request, _answered), do: state

  # After a tail: each response still incomplete is asked for again from
  # its first missing chunk.
  # Every cast is ended and asked for anew, so an image or an end cut by
  # the tail never stalls it.
  defp recover(state) do
    for {id, %{kind: :act} = request} <- state.pending do
      first = Enum.find(0..map_size(request.parts), &(not Map.has_key?(request.parts, &1)))
      write(state, Frame.message(%{"t" => "again", "id" => id, "seq" => first}), :again)
    end

    state.watches
    |> Map.values()
    |> Enum.filter(& &1.cast)
    |> Enum.reduce(state, fn watch, state ->
      state = stop_cast(state, watch)
      state |> update_watch(watch.ref, &%{&1 | cast: nil, held: nil}) |> cast(watch.ref, nil)
    end)
  end

  defp acknowledge(state, id, seq) do
    write(state, Frame.message(%{"t" => "ack", "id" => id, "seq" => seq}), :ack)
    state
  end

  # Every action waiting is answered `reply` and every watch ends with its
  # reason.
  defp answer_all(state, {:error, reason} = reply) do
    for request <- Map.values(state.pending) do
      Process.cancel_timer(request.timer)
      if request.kind == :act, do: GenServer.reply(request.from, reply)
    end

    for %{kind: :act} = request <- state.queued, do: GenServer.reply(request.from, reply)

    for watch <- Map.values(state.watches) do
      Process.demonitor(watch.monitor, [:flush])
      tell(watch, {:ended, reason})
    end

    %{state | pending: %{}, queued: [], watches: %{}}
  end

  defp close_session(%{session: nil} = state), do: state

  defp close_session(state) do
    _ = Programs.close(state.browser, state.session)
    %{state | session: nil, phase: :idle, windows: MapSet.new()}
  end

  # ---------------------------------------------------------------------------
  # Watches

  # The watches by the window each watches.
  defp watched(state), do: Map.new(state.watches, fn {_ref, w} -> {w.window, w} end)

  defp watching?(state, ref, cast) do
    case state.watches[ref] do
      %{cast: ^cast, viewer: viewer} -> Process.alive?(viewer)
      _ended_or_moved_on -> false
    end
  end

  defp put_watch(state, watch), do: %{state | watches: Map.put(state.watches, watch.ref, watch)}

  defp update_watch(state, ref, fun) do
    case state.watches[ref] do
      nil -> state
      watch -> put_watch(state, fun.(watch))
    end
  end

  defp tell(watch, message), do: send(watch.viewer, {__MODULE__, {self(), watch.ref}, message})

  # Ask the driver for the watch's cast, starting the browser first when
  # none runs (`allowed?` as an action's): only a new watch may find none,
  # and only it is handed `allowed?`.
  defp cast(state, ref, allowed?) do
    watch = state.watches[ref]

    request = %{
      kind: :cast,
      watch: ref,
      window: watch.window,
      op: "cast",
      args: Programs.Output.new(Jason.encode!(watch.size)),
      from: nil
    }

    case state.phase do
      :ready -> send_request(state, request)
      :starting -> %{state | queued: state.queued ++ [request]}
      :idle when is_function(allowed?, 0) -> start_session(%{state | queued: [request]}, allowed?)
    end
  end

  # The driver's answer to a cast, taken by its watch while it stands on
  # that cast: a window that does not stand waits, unless an action opened
  # it meanwhile; any other refusal ends the watch.
  defp cast_answered(state, request, reply) do
    case state.watches[request.watch] do
      %{cast: id} = watch when id == request.id ->
        case reply do
          {:ok, _casting} -> state
          {:error, {:driver, "no_window", _sentence}} -> waiting(state, watch)
          {:error, reason} -> end_watch(state, watch, reason)
        end

      _ended_or_moved_on ->
        state
    end
  end

  defp waiting(state, watch) do
    watch = %{watch | cast: nil, held: nil}

    if watch.reopened do
      state |> put_watch(%{watch | reopened: false}) |> cast(watch.ref, nil)
    else
      tell(watch, :waiting)
      put_watch(state, watch)
    end
  end

  # An action opened a window: a watch waiting for it asks for its cast,
  # and one whose cast is under way remembers it.
  defp opened(state, window) do
    case watched(state)[window] do
      %{cast: nil} = watch -> cast(state, watch.ref, nil)
      %{} = watch -> put_watch(state, %{watch | reopened: true})
      nil -> state
    end
  end

  # The driver ended a cast, its window closed.
  defp uncast(cast, state) when is_integer(cast) do
    case Enum.find(Map.values(state.watches), &(&1.cast == cast)) do
      nil -> state
      watch -> waiting(state, watch)
    end
  end

  defp uncast(_malformed, state), do: state

  # One image of a cast: handed to its watch's viewer when it holds none
  # unacknowledged, else held as the newest; one of a cast no watch stands
  # on is dropped. An image whose JPEG does not read is not shown, and the
  # driver is told it was seen so the cast goes on.
  defp image(%{"id" => cast, "seq" => seq, "jpeg" => jpeg}, state)
       when is_integer(cast) and is_integer(seq) and is_binary(jpeg) do
    case Enum.find(Map.values(state.watches), &(&1.cast == cast)) do
      nil ->
        state

      watch ->
        case Base.decode64(jpeg) do
          {:ok, bytes} when watch.shown == nil ->
            hand(state, watch, seq, Programs.Output.new(bytes))

          {:ok, bytes} ->
            put_watch(state, %{watch | held: {cast, seq, Programs.Output.new(bytes)}})

          :error ->
            write(state, Frame.message(%{"t" => "seen", "id" => cast, "seq" => seq}), :seen)
            state
        end
    end
  end

  defp image(_malformed, state), do: state

  defp hand(state, watch, seq, image) do
    n = watch.n + 1
    tell(watch, {:image, n, image})
    put_watch(state, %{watch | n: n, shown: {n, watch.cast, seq}})
  end

  # The next input of a watch goes to the writer once the last is done.
  defp pump_input(state, ref) do
    case state.watches[ref] do
      %{writing: false, input: [_ | _] = events, cast: cast} = watch when is_integer(cast) ->
        frame =
          Frame.encode(
            IO.iodata_to_binary([
              ~s({"t":"input","id":),
              Integer.to_string(cast),
              ~s(,"evs":[),
              Enum.map_intersperse(events, ",", & &1.bytes),
              "]}"
            ])
          )

        write(state, frame, {:input, ref, cast})
        put_watch(state, %{watch | writing: true, input: []})

      _nothing_or_busy ->
        state
    end
  end

  defp stop_cast(state, %{cast: nil}), do: state

  defp stop_cast(state, watch) do
    write(state, Frame.message(%{"t" => "uncast", "id" => watch.cast}), :uncast)

    case Map.pop(state.pending, watch.cast) do
      {%{kind: :cast, timer: timer}, pending} ->
        Process.cancel_timer(timer)
        %{state | pending: pending}

      {_none_or_action, _pending} ->
        state
    end
  end

  # A watch ends: its viewer is told `reason` (nothing when it asked or
  # is gone), the driver ends its cast, and the browser's idle clock runs
  # from now.
  defp end_watch(state, watch, reason) do
    Process.demonitor(watch.monitor, [:flush])
    if reason, do: tell(watch, {:ended, reason})
    state = stop_cast(state, watch)

    queued = Enum.reject(state.queued, &(&1.kind == :cast and &1.watch == watch.ref))

    idle(%{
      state
      | watches: Map.delete(state.watches, watch.ref),
        queued: queued,
        last_act: now()
    })
  end

  # The idle clock runs from the last action while nothing waits.
  defp idle(state) do
    with {timer, _token} <- state.idle, do: Process.cancel_timer(timer)

    if state.phase == :ready and state.pending == %{} and state.queued == [] and
         state.watches == %{} do
      token = make_ref()
      left = max(idle_ms() - (now() - state.last_act), 0)
      %{state | idle: {Process.send_after(self(), {:idle, token}, left), token}}
    else
      %{state | idle: nil}
    end
  end

  # ---------------------------------------------------------------------------
  # The session's input, one write after another in the order asked, each
  # at most the wire's one input.

  defp write(%{session: nil}, _frame, _tag), do: :ok
  # A frame goes to the writer as an `Opus.Programs.Output`, which shows
  # its size alone, since it may carry what a turn types.
  defp write(state, frame, tag),
    do: send(state.writer, {:write, state.session, Programs.Output.new(frame), tag})

  # Just before a request's first byte is written, after every queue it
  # waited in (the holder's mailbox, the browser's start, this writer's
  # mailbox behind earlier writes), the writer asks the holder whether it
  # still wants the request (`{:wanted, id}`), the one decision whether it
  # reaches the driver; what is not wanted is not written, so nothing of it
  # runs. Acknowledgements and requests to send again are written as they
  # come.
  defp write_loop(watch, owner, browser) do
    receive do
      {:write, session, %Programs.Output{bytes: frame}, tag} ->
        if wanted?(owner, tag) do
          case write_all(browser, session, frame) do
            :ok -> :ok
            {:error, reason} -> send(owner, {:write_failed, tag, reason})
          end
        end

        # The holder sends a watch's next input once this one is done with.
        with {:input, _ref, _cast} <- tag, do: send(owner, {:written, tag})
        write_loop(watch, owner, browser)

      {:DOWN, ^watch, :process, _owner, _reason} ->
        :ok
    end
  end

  defp wanted?(owner, {:request, id}) do
    GenServer.call(owner, {:wanted, id}, @request_ms)
  catch
    :exit, _holder_gone -> false
  end

  defp wanted?(owner, {:input, ref, cast}) do
    GenServer.call(owner, {:wanted_input, ref, cast}, @request_ms)
  catch
    :exit, _holder_gone -> false
  end

  defp wanted?(_owner, _control), do: true

  defp write_all(_browser, _session, ""), do: :ok

  defp write_all(browser, session, bytes) do
    size = min(byte_size(bytes), Prima.LocusBackends.max_chunk_bytes())
    <<piece::binary-size(^size), rest::binary>> = bytes

    case Programs.input(browser, session, piece) do
      :ok -> write_all(browser, session, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp idle_ms, do: setting("browser_idle_ms")

  # Both settings the holder reads are positive whole numbers, as their
  # validators admit them.
  defp setting(key) do
    case Arca.PlatformSettings.effective(key) do
      {:ok, value} when is_integer(value) and value > 0 -> value
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
