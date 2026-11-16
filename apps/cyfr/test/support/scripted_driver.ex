# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedDriver do
  @moduledoc """
  Aqua's browser driver as a script, on the terminal sessions of a
  scripted backends service (`Cyfr.Test.ScriptedBackends`, `set(fake,
  :terminal, pid)`): it speaks the driver's framing as the driver does
  (`Opus.Browser.Frame`, whose vectors bind it to the driver), with
  Chrome's part answered by the test. Test-only.

  On a session's start it writes `hello`. Each request is reported to the
  test as `{:driver, :req, session, request}` and answered by `answer`
  (a function of the request: `{:ok, map}`, `{:error, code, sentence}`
  or `:hold`, which holds it until `release/2`). An answer goes out in
  chunks of `chunk` bytes, base64, one frame unacknowledged at a time, the
  next only after the host's `ack` of the last; `again` rewinds a response
  and sends it again from the chunk it names, and one it no longer holds,
  or never held, is answered `gone`. A response is kept until its last
  chunk is acknowledged or for `keep_ms`. `flood/2` sends the next
  released response's every chunk at once, as a driver that ignored the
  acknowledgements would, to force a tail. Every `again` is reported as
  `{:driver, :again, session, id, seq}`.

  A cast (C12) is a request of op `cast`, reported and answered as any
  request is; its images are the test's to write (`image/4`), and the
  host's `seen`, `uncast` and `input` are reported as `{:driver, :seen,
  session, cast, seq}`, `{:driver, :uncast, session, cast}` and
  `{:driver, :input, session, cast, events}`.

  A put (C15) is a request of op `page` that says how many `part`
  messages follow it (`of`): each part is reported as `{:driver, :part,
  session, id, seq, bytes}`, its base64 read, and once the last is in the
  put is reported as `{:driver, :put, session, request, bytes}`, the
  files' bytes laid end to end, and answered as any request is. A page's
  call is the test's to write (`call/6`, naming the put it belongs to by
  its request's id, its body's bytes carried in base64 as the driver
  carries them), and the host's `answer` is reported
  as `{:driver, :answer, session, id, status, body}`.
  """

  use GenServer

  alias Opus.Browser.Frame

  @doc "Start a driver reporting to `test`; options: `answer`, `chunk`, `keep_ms`, `hello`."
  def start(test, opts \\ []) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {test, opts})
    pid
  end

  @doc "Answer the held request `id` now, as `answer` would."
  def release(driver, id), do: GenServer.call(driver, {:release, id})

  @doc "Send the next response whole, every chunk at once."
  def flood(driver, on \\ true), do: GenServer.call(driver, {:flood, on})

  @doc "Write `bytes` on every session as the driver's own output."
  def write(driver, bytes), do: GenServer.call(driver, {:write, bytes})

  @doc "The frame of image `seq` of cast `cast`, its JPEG `jpeg`."
  def image_frame(cast, seq, jpeg),
    do:
      Frame.message(%{
        "t" => "image",
        "id" => cast,
        "seq" => seq,
        "jpeg" => Base.encode64(jpeg)
      })

  @doc "Write image `seq` of cast `cast` on every session."
  def image(driver, cast, seq, jpeg), do: write(driver, image_frame(cast, seq, jpeg))

  @doc """
  Pass up a page's call `id` from window `win` on every session: the id of
  the `page` request whose put it belongs to, its `op` and its `body`'s
  bytes.
  """
  def call(driver, id, win, put, op, body),
    do:
      write(
        driver,
        Frame.message(%{
          "t" => "call",
          "id" => id,
          "win" => win,
          "put" => put,
          "op" => op,
          "body" => Base.encode64(body)
        })
      )

  @impl true
  def init({test, opts}) do
    {:ok,
     %{
       test: test,
       answer: Keyword.get(opts, :answer, fn _request -> {:ok, %{}} end),
       chunk: Keyword.get(opts, :chunk, 49_152),
       keep_ms: Keyword.get(opts, :keep_ms, 120_000),
       hello: Keyword.get(opts, :hello, %{}),
       flood: false,
       fake: nil,
       sessions: %{}
     }}
  end

  @impl true
  def handle_call({:release, id}, _from, state) do
    state =
      Enum.reduce(state.sessions, state, fn {session, s}, state ->
        case Map.pop(s.held, id) do
          {nil, _held} ->
            state

          {request, held} ->
            state = put_in(state.sessions[session], %{s | held: held})
            respond(state, session, id, answer_of(state, request, :released))
        end
      end)

    {:reply, :ok, state}
  end

  def handle_call({:flood, on}, _from, state), do: {:reply, :ok, %{state | flood: on}}

  def handle_call({:write, bytes}, _from, state) do
    for {session, _s} <- state.sessions,
        do: Cyfr.Test.ScriptedBackends.write_raw(state.fake, session, bytes)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:terminal_opened, fake, session}, state) do
    session_state = %{
      buffer: "",
      responses: %{},
      order: [],
      outstanding: nil,
      held: %{},
      puts: %{}
    }

    state = %{state | fake: fake, sessions: Map.put(state.sessions, session, session_state)}

    hello =
      Map.merge(
        %{"t" => "hello", "v" => 1, "chunk" => state.chunk, "keep_ms" => state.keep_ms},
        state.hello
      )

    write_frame(state, session, hello)
    send(state.test, {:driver, :opened, session})
    {:noreply, state}
  end

  def handle_info({:terminal_input, _fake, session, bytes}, state) do
    case state.sessions[session] do
      nil ->
        {:noreply, state}

      s ->
        {bodies, rest} = Frame.decode(s.buffer <> bytes, Frame.max_to_driver())
        state = put_in(state.sessions[session].buffer, rest)
        {:noreply, Enum.reduce(bodies, state, &message(&2, session, Jason.decode!(&1)))}
    end
  end

  def handle_info({:expire, session, id}, state) do
    case get_in(state.sessions, [session, :responses, id]) do
      nil -> {:noreply, state}
      _response -> {:noreply, drop(state, session, id)}
    end
  end

  # ---------------------------------------------------------------------------

  # A put waits for its parts; the last of them lets it be answered.
  defp message(state, session, %{"t" => "req", "id" => id, "of" => of} = request) when of > 0 do
    send(state.test, {:driver, :req, session, request})
    put_in(state.sessions[session].puts[id], %{request: request, parts: []})
  end

  defp message(state, session, %{"t" => "req", "id" => id} = request) do
    send(state.test, {:driver, :req, session, request})
    answer_request(state, session, id, request)
  end

  defp message(state, session, %{"t" => "part", "id" => id, "seq" => seq, "part" => part}) do
    bytes = Base.decode64!(part)
    send(state.test, {:driver, :part, session, id, seq, bytes})

    case state.sessions[session].puts[id] do
      %{request: %{"of" => of} = request, parts: parts} when length(parts) + 1 == of ->
        state = update_in(state.sessions[session].puts, &Map.delete(&1, id))
        send(state.test, {:driver, :put, session, request, IO.iodata_to_binary(parts ++ [bytes])})
        answer_request(state, session, id, request)

      %{parts: parts} = put ->
        put_in(state.sessions[session].puts[id], %{put | parts: parts ++ [bytes]})

      nil ->
        state
    end
  end

  defp message(state, session, %{"t" => "answer", "id" => id, "status" => status, "body" => body}) do
    send(state.test, {:driver, :answer, session, id, status, body})
    state
  end

  # An acknowledgement names the last chunk of the unbroken run the host
  # holds: it acknowledges every chunk up to it, and the last one ends the
  # response.
  defp message(state, session, %{"t" => "ack", "id" => id, "seq" => seq}) do
    s = state.sessions[session]

    state =
      case s.outstanding do
        {^id, sent} when sent <= seq -> put_in(state.sessions[session].outstanding, nil)
        _other -> state
      end

    case s.responses[id] do
      nil ->
        pump(state, session)

      %{of: of} when seq >= of - 1 ->
        state |> drop(session, id) |> pump(session)

      response ->
        state
        |> put_in([Access.key(:sessions), session, :responses, id], %{
          response
          | next: max(response.next, seq + 1)
        })
        |> pump(session)
    end
  end

  defp message(state, session, %{"t" => "again", "id" => id, "seq" => seq}) do
    send(state.test, {:driver, :again, session, id, seq})
    s = state.sessions[session]

    cond do
      Map.has_key?(s.held, id) ->
        state

      response = s.responses[id] ->
        state =
          if match?({^id, _}, s.outstanding),
            do: put_in(state.sessions[session].outstanding, nil),
            else: state

        state
        |> put_in([Access.key(:sessions), session, :responses, id], %{response | next: seq})
        |> pump(session)

      true ->
        write_frame(state, session, %{"t" => "gone", "id" => id})
        state
    end
  end

  defp message(state, session, %{"t" => "seen", "id" => cast, "seq" => seq}) do
    send(state.test, {:driver, :seen, session, cast, seq})
    state
  end

  defp message(state, session, %{"t" => "uncast", "id" => cast}) do
    send(state.test, {:driver, :uncast, session, cast})
    state
  end

  defp message(state, session, %{"t" => "input", "id" => cast, "evs" => events}) do
    send(state.test, {:driver, :input, session, cast, events})
    state
  end

  defp message(state, _session, _other), do: state

  defp answer_request(state, session, id, request) do
    case answer_of(state, request, :arrived) do
      :hold ->
        send(state.test, {:driver, :holding, session, id})
        update_in(state.sessions[session].held, &Map.put(&1, id, request))

      answered ->
        respond(state, session, id, answered)
    end
  end

  defp answer_of(state, request, moment) do
    case {state.answer.(request), moment} do
      {:hold, :released} -> {:ok, %{}}
      {answered, _moment} -> answered
    end
  end

  defp respond(state, session, id, answered) do
    text =
      case answered do
        {:ok, map} ->
          Jason.encode!(%{"ok" => map})

        {:error, code, sentence} ->
          Jason.encode!(%{"error" => %{"code" => code, "message" => sentence}})
      end

    parts = chunks(text, state.chunk)
    Process.send_after(self(), {:expire, session, id}, state.keep_ms)

    if state.flood do
      for {part, seq} <- Enum.with_index(parts),
          do: write_frame(state, session, chunk_frame(id, seq, length(parts), part))

      response = %{parts: parts, of: length(parts), next: length(parts)}
      state = %{state | flood: false}
      state = put_in(state.sessions[session].responses[id], response)
      update_in(state.sessions[session].order, &(&1 ++ [id]))
    else
      state =
        put_in(state.sessions[session].responses[id], %{parts: parts, of: length(parts), next: 0})

      state = update_in(state.sessions[session].order, &(&1 ++ [id]))
      pump(state, session)
    end
  end

  # The one send slot: the next chunk of the first response with one to
  # send, while nothing is unacknowledged.
  defp pump(state, session) do
    s = state.sessions[session]

    with nil <- s.outstanding,
         id when id != nil <-
           Enum.find(s.order, fn id ->
             response = s.responses[id]
             response != nil and response.next < response.of
           end) do
      response = s.responses[id]

      write_frame(
        state,
        session,
        chunk_frame(id, response.next, response.of, Enum.at(response.parts, response.next))
      )

      put_in(state.sessions[session].outstanding, {id, response.next})
    else
      _busy_or_none -> state
    end
  end

  defp drop(state, session, id) do
    state
    |> update_in([Access.key(:sessions), session, :responses], &Map.delete(&1, id))
    |> update_in([Access.key(:sessions), session, :order], &List.delete(&1, id))
  end

  defp chunk_frame(id, seq, of, part),
    do: %{"t" => "res", "id" => id, "seq" => seq, "of" => of, "part" => Base.encode64(part)}

  defp write_frame(state, session, map),
    do: Cyfr.Test.ScriptedBackends.write_raw(state.fake, session, Frame.message(map))

  defp chunks(text, size) when byte_size(text) <= size, do: [text]

  defp chunks(text, size),
    do: [
      binary_part(text, 0, size) | chunks(binary_part(text, size, byte_size(text) - size), size)
    ]
end
