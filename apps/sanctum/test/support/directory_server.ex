# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.DirectoryServer do
  @moduledoc """
  A scripted identity directory for the suites, speaking HTTPS under a
  test authority on loopback, named by a test resolver.

    * `Resolver` answers the test directories' names at loopback (and
      `metadata.test` at a metadata address), telling the running test
      each name it was asked.
    * `Server` is a TLS listener that reads one HTTP/1.1 request per
      connection, tells the test it connected and what it asked, and
      answers `handler.(request)`: `{status, headers, body}`, `:close` to
      close without answering, or `:hang` to answer nothing.
    * `start!/2` serves a directory that keeps its logs in an agent, held
      to `Prima.Identity`'s rules: it registers a genesis, appends a
      rotation that names its head, and applies a recovery against the
      revision it expects, recording each recovery's outcome by request
      id, as `Emissary.Web.DirectoryController` answers them. `next/3`
      scripts how it answers an identifier's next write.

  A suite calls `tls/0` once (`setup_all`), `listen!/0` in its setup (the
  observer and the private-egress listing, restored on exit), and passes
  `opts/1` to the client.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Prima.Identity
  alias Prima.Identity.{Entry, RecoverRequest}

  @hosts ~w(dir-a.test dir-b.test loopback.test metadata.test)

  defmodule Resolver do
    @moduledoc false
    # Names every test directory answers at, and tells the running test
    # each name it was asked, so a case can show no lookup was made.
    def getaddr(name, :inet) do
      name = to_string(name)

      case :persistent_term.get({__MODULE__, :observer}, nil) do
        pid when is_pid(pid) -> send(pid, {:resolved, name})
        nil -> :ok
      end

      case name do
        "metadata.test" -> {:ok, {169, 254, 169, 254}}
        "dir-" <> _ -> {:ok, {127, 0, 0, 1}}
        "loopback.test" -> {:ok, {127, 0, 0, 1}}
        _ -> {:error, :nxdomain}
      end
    end

    def getaddr(_name, :inet6), do: {:error, :nxdomain}
  end

  defmodule Server do
    @moduledoc false
    # A TLS listener on loopback that reads one HTTP/1.1 request per
    # connection, reports it to the test and answers `handler.(request)`:
    # `{status, headers, body}`, `:close` to close without answering, or
    # `:hang` to answer nothing.

    def start(ssl_options, handler, observer) do
      {:ok, listen} =
        :ssl.listen(
          0,
          ssl_options ++ [ip: {127, 0, 0, 1}, active: false, mode: :binary, reuseaddr: true]
        )

      {:ok, {_address, port}} = :ssl.sockname(listen)
      pid = spawn(fn -> accept(listen, handler, observer) end)
      %{port: port, pid: pid, listen: listen}
    end

    def stop(%{pid: pid, listen: listen}) do
      Process.exit(pid, :kill)
      :ssl.close(listen)
    end

    defp accept(listen, handler, observer) do
      case :ssl.transport_accept(listen) do
        {:ok, socket} ->
          # Told before the handshake: a client that opened a connection
          # is seen to have, whether or not it then trusts the server.
          send(observer, :connected)
          serve(socket, handler, observer)
          accept(listen, handler, observer)

        {:error, _closed} ->
          :ok
      end
    end

    defp serve(socket, handler, observer) do
      with {:ok, socket} <- :ssl.handshake(socket, 5_000),
           {:ok, request} <- read(socket, "") do
        send(observer, {:request, request})

        case handler.(request) do
          :close ->
            :ok

          :hang ->
            Process.sleep(30_000)

          {status, headers, body} ->
            headers = [{"content-length", byte_size(body)}, {"connection", "close"} | headers]
            head = Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)
            :ssl.send(socket, "HTTP/1.1 #{status} Answer\r\n" <> head <> "\r\n" <> body)
        end

        :ssl.close(socket)
      end
    end

    defp read(socket, acc) do
      case :binary.split(acc, "\r\n\r\n") do
        [head, rest] ->
          [line | lines] = String.split(head, "\r\n")
          [method, target, _version] = String.split(line, " ", parts: 3)

          headers =
            for line <- lines, [name, value] = String.split(line, ":", parts: 2) do
              {String.downcase(name), String.trim(value)}
            end

          length =
            case List.keyfind(headers, "content-length", 0) do
              {_name, value} -> String.to_integer(value)
              nil -> 0
            end

          with {:ok, body} <- body(socket, rest, length) do
            {:ok, %{method: method, target: target, headers: headers, body: body}}
          end

        [_partial] ->
          with {:ok, data} <- :ssl.recv(socket, 0, 5_000), do: read(socket, acc <> data)
      end
    end

    defp body(_socket, acc, length) when byte_size(acc) >= length, do: {:ok, acc}

    defp body(socket, acc, length) do
      with {:ok, data} <- :ssl.recv(socket, 0, 5_000), do: body(socket, acc <> data, length)
    end
  end

  @doc "A test authority and a server certificate naming `hosts`."
  @spec tls([String.t()]) :: keyword()
  def tls(hosts \\ @hosts) do
    san =
      {:Extension, {2, 5, 29, 17}, false, Enum.map(hosts, &{:dNSName, String.to_charlist(&1)})}

    key = [key: {:namedCurve, :secp256r1}, digest: :sha256]

    :public_key.pkix_test_data(%{
      server_chain: %{root: key, intermediates: [], peer: key ++ [extensions: [san]]},
      client_chain: %{root: key, intermediates: [], peer: key}
    })
  end

  @doc "The directory client's options for the test authority and resolver."
  @spec opts(keyword()) :: keyword()
  def opts(tls), do: [resolver: Resolver, cacerts: tls[:client_config][:cacerts]]

  @doc """
  The calling test as the resolver's observer, and the test directories'
  names listed as the operator's private egress targets, both restored on
  exit.
  """
  @spec listen!([String.t()]) :: :ok
  def listen!(hosts \\ ["dir-a.test", "dir-b.test", "metadata.test"]) do
    targets = Application.fetch_env(:sanctum, :private_egress_targets)
    Application.put_env(:sanctum, :private_egress_targets, hosts)
    :persistent_term.put({Resolver, :observer}, self())

    on_exit(fn ->
      case targets do
        {:ok, value} -> Application.put_env(:sanctum, :private_egress_targets, value)
        :error -> Application.delete_env(:sanctum, :private_egress_targets)
      end

      :persistent_term.erase({Resolver, :observer})
    end)
  end

  @doc """
  Serve a scripted directory at `host` (`dir-a.test` by default): its
  `url`, the `server` and the agent `dir` holding its logs. Stopped on
  exit.
  """
  @spec start!(keyword(), String.t()) :: %{url: String.t(), server: map(), dir: pid()}
  def start!(tls, host \\ "dir-a.test") do
    {:ok, dir} = Agent.start_link(fn -> %{logs: %{}, next: %{}, recorded: %{}} end)
    server = Server.start(tls[:server_config], handler(dir), self())
    on_exit(fn -> Server.stop(server) end)
    %{url: "https://#{host}:#{server.port}", server: server, dir: dir}
  end

  @doc "Serve `entries` as `identifier`'s log."
  @spec publish(pid(), String.t(), [Entry.t()]) :: :ok
  def publish(dir, identifier, entries),
    do: Agent.update(dir, &put_in(&1, [:logs, identifier], entries))

  @doc "The log the directory serves for `identifier`, or nil."
  @spec log(pid(), String.t()) :: [Entry.t()] | nil
  def log(dir, identifier), do: Agent.get(dir, &get_in(&1, [:logs, identifier]))

  @doc """
  How the directory answers `identifier`'s next write (a registration, a
  rotation or a recovery): `:refuse` refuses it as unverified; `:drop`
  commits it and closes without an answer, a lost reply; `{:race, fun}`
  commits `fun.(head)` first, so the write meets a moved log;
  `{:after, fun}` commits it and then `fun.(its_hash)` after it.
  """
  @spec next(pid(), String.t(), term()) :: :ok
  def next(dir, identifier, mode), do: Agent.update(dir, &put_in(&1, [:next, identifier], mode))

  @doc "The requests the server has reported to the calling test, oldest first."
  @spec requests() :: [map()]
  def requests do
    receive do
      {:request, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  @doc "The handler a scripted directory answers with."
  @spec handler(pid()) :: (map() -> term())
  def handler(dir) do
    fn
      %{method: "GET", target: target} ->
        case String.split(URI.parse(target).path, "/") do
          ["", "directory", "v1", identifier, "requests", request_id] ->
            outcome(dir, identifier, request_id)

          ["", "directory", "v1", identifier] ->
            page(dir, identifier, target)
        end

      %{method: "POST", target: "/directory/v1/genesis", body: body} ->
        register(dir, body)

      %{method: "POST", target: target, body: body} ->
        case String.split(target, "/") do
          ["", "directory", "v1", identifier, "entries"] -> append(dir, identifier, body)
          ["", "directory", "v1", identifier, "recover"] -> recover(dir, identifier, body)
        end
    end
  end

  defp page(dir, identifier, target) do
    query = URI.decode_query(URI.parse(target).query || "")
    after_seq = String.to_integer(Map.get(query, "after", "-1"))

    case log(dir, identifier) do
      nil ->
        json(404, %{"error" => "not_found"})

      log ->
        page = log |> Enum.drop(after_seq + 1) |> Enum.take(100)
        last = after_seq + length(page)
        next = if last < length(log) - 1, do: last, else: nil

        json(200, %{
          "identifier" => identifier,
          "from" => after_seq + 1,
          "entries" => Enum.map(page, &Entry.encode/1),
          "next" => next,
          "head" => head_of(log),
          "length" => length(log)
        })
    end
  end

  defp register(dir, body) do
    {:ok, genesis} = body |> Jason.decode!() |> Entry.decode()
    identifier = Identity.identifier(genesis)

    Agent.get_and_update(dir, fn state ->
      {mode, next} = Map.pop(state.next, identifier, :accept)
      state = %{state | next: next}

      cond do
        mode == :refuse ->
          {json(422, %{"error" => "unverified", "reason" => "wrong_signer"}), state}

        match?({:error, _}, Identity.verify_chain([genesis])) ->
          {json(422, %{"error" => "unverified", "reason" => "wrong_signer"}), state}

        true ->
          logs = Map.put_new(state.logs, identifier, [genesis])
          answer = if mode == :drop, do: :close, else: accepted(identifier, [genesis])
          {answer, %{state | logs: logs}}
      end
    end)
  end

  defp append(dir, identifier, body) do
    {:ok, entry} = body |> Jason.decode!() |> Entry.decode()
    hash = Identity.hash(entry)

    Agent.get_and_update(dir, fn state ->
      {mode, next} = Map.pop(state.next, identifier, :accept)
      log = raced(Map.fetch!(state.logs, identifier), mode)

      {answer, log} =
        cond do
          mode == :refuse ->
            {json(422, %{"error" => "unverified", "reason" => "bad_signature"}), log}

          hash == head_of(log) ->
            {accepted(identifier, log), log}

          entry.prev == head_of(log) ->
            committed(identifier, log ++ [entry], mode)

          true ->
            {json(409, %{"error" => "stale_head", "head" => head_of(log)}), log}
        end

      {answer, %{state | logs: Map.put(state.logs, identifier, log), next: next}}
    end)
  end

  # A recovery is applied against whatever the log holds now, and its
  # outcome is recorded by request id: the same request again answers it.
  defp recover(dir, identifier, body) do
    {:ok, request} = body |> Jason.decode!() |> RecoverRequest.decode()

    Agent.get_and_update(dir, fn state ->
      {mode, next} = Map.pop(state.next, identifier, :accept)
      state = %{state | next: next}
      log = raced(Map.fetch!(state.logs, identifier), mode)
      state = put_in(state, [:logs, identifier], log)
      key = {identifier, request.request_id}

      case Map.fetch(state.recorded, key) do
        {:ok, recorded} ->
          {recorded_answer(identifier, recorded), state}

        :error ->
          {:ok, chain} = Identity.verify_chain(log)
          {:ok, entry} = Entry.recover(head_of(log), request)

          cond do
            mode == :refuse ->
              {json(422, %{"error" => "unverified", "reason" => "wrong_signer"}), state}

            request.expected_revision != chain.revision ->
              recorded = %{outcome: :stale_policy, request: request, revision: chain.revision}
              state = put_in(state, [:recorded, key], recorded)
              {recorded_answer(identifier, recorded), state}

            match?({:error, _}, Identity.extend(chain, entry)) ->
              {json(422, %{"error" => "unverified", "reason" => "wrong_signer"}), state}

            true ->
              log = log ++ [entry]
              recorded = %{outcome: :accepted, entry: entry, seq: length(log) - 1}
              state = put_in(state, [:recorded, key], recorded)

              {answer, log} =
                committed(identifier, log, mode, recovery_answer(identifier, recorded))

              {answer, put_in(state, [:logs, identifier], log)}
          end
      end
    end)
  end

  defp outcome(dir, identifier, request_id) do
    case Agent.get(dir, &Map.get(&1.recorded, {identifier, request_id})) do
      nil ->
        json(404, %{"error" => "not_found"})

      %{outcome: :accepted, entry: entry, seq: seq} ->
        json(200, %{
          "outcome" => "accepted",
          "identifier" => identifier,
          "request_id" => request_id,
          "request_digest" => Identity.request_digest(entry.request),
          "seq" => seq,
          "entry_hash" => Identity.hash(entry),
          "entry" => Entry.encode(entry)
        })

      %{outcome: :stale_policy, request: request, revision: revision} ->
        json(200, %{
          "outcome" => "stale_policy",
          "identifier" => identifier,
          "request_id" => request_id,
          "request_digest" => Identity.request_digest(request),
          "recorded" => %{"revision" => revision}
        })
    end
  end

  defp recorded_answer(identifier, %{outcome: :accepted} = recorded),
    do: recovery_answer(identifier, recorded)

  defp recorded_answer(_identifier, %{outcome: :stale_policy, revision: revision}),
    do: json(409, %{"error" => "stale_policy", "recorded" => %{"revision" => revision}})

  defp recovery_answer(identifier, %{entry: entry, seq: seq}) do
    json(200, %{
      "identifier" => identifier,
      "seq" => seq,
      "entry_hash" => Identity.hash(entry),
      "entry" => Entry.encode(entry)
    })
  end

  defp raced(log, {:race, moved}), do: log ++ [moved.(head_of(log))]
  defp raced(log, _mode), do: log

  defp committed(identifier, log, mode, answer \\ nil) do
    answer = answer || accepted(identifier, log)

    case mode do
      :drop -> {:close, log}
      {:after, after_it} -> {answer, log ++ [after_it.(head_of(log))]}
      _accept -> {answer, log}
    end
  end

  defp accepted(identifier, log) do
    json(200, %{
      "identifier" => identifier,
      "seq" => length(log) - 1,
      "entry_hash" => head_of(log)
    })
  end

  defp head_of(log), do: Identity.hash(List.last(log))

  defp json(status, body),
    do: {status, [{"content-type", "application/json"}], Jason.encode!(body)}
end
