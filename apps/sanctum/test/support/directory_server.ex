# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.DirectoryServer do
  @moduledoc """
  A scripted directory for the suites, `cyfr-directory/v2`, speaking HTTPS
  under a test authority on loopback, named by a test resolver.

    * `Resolver` answers the test directories' names at loopback (and
      `metadata.test` at a metadata address), telling the running test
      each name it was asked.
    * `Server` is a TLS listener that reads one HTTP/1.1 request per
      connection, tells the test it connected and what it asked, and
      answers `handler.(request)`: `{status, headers, body}`, `:close` to
      close without answering, or `:hang` to answer nothing.
    * `start!/2` serves a directory that keeps its logs in an agent, held
      to `Prima.Identity`'s rules as `Emissary.Web.DirectoryController`
      answers: it registers a genesis, appends an entry naming its head
      (`exists` for one already after its `prev`, `stale_head`,
      `duplicate_key`, `unverified`), serves a log from a position or
      after an entry's hash, and answers `gone` for a tombstoned account
      (`tombstone/2`). `next/3` scripts how it answers an identifier's
      next write.
    * `account!/2` makes an account there, its genesis signed by a
      recovery key and one device key added; `add_device!/2`,
      `remove_key!/3` and `recover!/2` extend its log as the account's
      pages and terminals do.

  A suite calls `tls/0` once (`setup_all`), `listen!/0` in its setup (the
  observer and the private-egress listing, restored on exit), and passes
  `opts/1` to the client, or `seam!/1` for the paths that pass none.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Prima.Identity
  alias Prima.Identity.{Entry, Key}

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
    {:ok, dir} =
      Agent.start_link(fn -> %{logs: %{}, next: %{}, gone: MapSet.new(), reads: %{}} end)

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

  @doc "The operator's tombstone: every later read and write of `identifier` is `gone`."
  @spec tombstone(pid(), String.t()) :: :ok
  def tombstone(dir, identifier),
    do: Agent.update(dir, &%{&1 | gone: MapSet.put(&1.gone, identifier)})

  @doc """
  How the directory answers `identifier`'s next write: `:refuse` refuses
  it as unverified; `:drop` commits it and closes without an answer, a
  lost reply; `{:race, fun}` commits `fun.(head)` first, so the write
  meets a moved log.
  """
  @spec next(pid(), String.t(), term()) :: :ok
  def next(dir, identifier, mode), do: Agent.update(dir, &put_in(&1, [:next, identifier], mode))

  @doc """
  Answer every read of `identifier`'s log with `answer`, an HTTP answer
  `{status, headers, body}`, until it is set back to nil.
  """
  @spec answer_reads(pid(), String.t(), {pos_integer(), list(), binary()} | nil) :: :ok
  def answer_reads(dir, identifier, answer),
    do: Agent.update(dir, &put_in(&1, [:reads, identifier], answer))

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
    fn %{method: method, target: target} = request ->
      %URI{path: path, query: query} = URI.parse(target)

      case {method, String.split(path, "/")} do
        {"POST", ["", "directory", "v1", "register"]} ->
          register(dir, request.body)

        {"GET", ["", "directory", "v1", identifier]} ->
          after_seq = String.to_integer(Map.get(URI.decode_query(query || ""), "after", "-1"))
          served(dir, identifier, &page(&1, identifier, after_seq))

        {"GET", ["", "directory", "v1", identifier, "from", hash]} ->
          served(dir, identifier, &after_hash(&1, identifier, hash))

        {"POST", ["", "directory", "v1", identifier, "append"]} ->
          append(dir, identifier, request.body)
      end
    end
  end

  defp served(dir, identifier, answer) do
    case Agent.get(dir, &read_state(&1, identifier)) do
      {_gone, _log, {_status, _headers, _body} = scripted} -> scripted
      {true, _log, nil} -> json(410, %{"error" => "gone"})
      {false, nil, nil} -> json(404, %{"error" => "not_found"})
      {false, log, nil} -> answer.(log)
    end
  end

  defp read_state(state, identifier) do
    {MapSet.member?(state.gone, identifier), get_in(state, [:logs, identifier]),
     get_in(state, [:reads, identifier])}
  end

  defp after_hash(log, identifier, hash) do
    case Enum.find_index(log, &(Identity.hash(&1) == hash)) do
      nil -> json(404, %{"error" => "not_found"})
      seq -> page(log, identifier, seq)
    end
  end

  defp page(log, identifier, after_seq) do
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

  defp register(dir, body) do
    {:ok, genesis} = body |> Jason.decode!() |> Entry.decode()
    identifier = Identity.identifier(genesis)

    Agent.get_and_update(dir, fn state ->
      {mode, next} = Map.pop(state.next, identifier, :accept)
      state = %{state | next: next}

      cond do
        MapSet.member?(state.gone, identifier) ->
          {json(410, %{"error" => "gone"}), state}

        mode == :refuse or match?({:error, _}, Identity.verify_chain([genesis])) ->
          {json(422, %{"error" => "unverified", "reason" => "wrong_signer"}), state}

        Map.has_key?(state.logs, identifier) ->
          log = state.logs[identifier]
          {written(identifier, 0, Identity.hash(genesis), "exists", head_of(log)), state}

        true ->
          answer =
            if mode == :drop,
              do: :close,
              else: written(identifier, 0, Identity.hash(genesis), "created")

          {answer, put_in(state, [:logs, identifier], [genesis])}
      end
    end)
  end

  defp append(dir, identifier, body) do
    {:ok, entry} = body |> Jason.decode!() |> Entry.decode()

    Agent.get_and_update(dir, fn state ->
      {mode, next} = Map.pop(state.next, identifier, :accept)
      state = %{state | next: next}

      if MapSet.member?(state.gone, identifier) do
        {json(410, %{"error" => "gone"}), state}
      else
        log = raced(Map.fetch!(state.logs, identifier), mode)
        {answer, log} = appended(identifier, log, entry, mode)
        {answer, put_in(state, [:logs, identifier], log)}
      end
    end)
  end

  defp appended(identifier, log, entry, mode) do
    hash = Identity.hash(entry)
    placed = Enum.find_index(log, &(Identity.hash(&1) == entry.prev))

    cond do
      mode == :refuse ->
        {json(422, %{"error" => "unverified", "reason" => "wrong_signer"}), log}

      entry.prev != head_of(log) and already?(log, placed, entry) ->
        {written(identifier, placed + 1, hash, "exists", head_of(log)), log}

      entry.prev != head_of(log) ->
        {json(409, %{"error" => "stale_head", "head" => head_of(log)}), log}

      true ->
        {:ok, state} = Identity.verify_chain(log)

        case Identity.extend(state, entry) do
          {:ok, _next} ->
            log = log ++ [entry]
            answer = written(identifier, length(log) - 1, hash, "accepted")
            {if(mode == :drop, do: :close, else: answer), log}

          {:error, :duplicate_key} ->
            {json(409, %{"error" => "duplicate_key"}), log}

          {:error, reason} ->
            {json(422, %{"error" => "unverified", "reason" => reason_word(reason)}), log}
        end
    end
  end

  # The entry already the one after its `prev`, byte for byte.
  defp already?(_log, nil, _entry), do: false

  defp already?(log, placed, entry) do
    case Enum.at(log, placed + 1) do
      nil -> false
      stored -> Identity.canonical(stored) == Identity.canonical(entry)
    end
  end

  defp reason_word({tag, _field}), do: Atom.to_string(tag)
  defp reason_word(reason), do: Atom.to_string(reason)

  defp raced(log, {:race, moved}), do: log ++ [moved.(head_of(log))]
  defp raced(log, _mode), do: log

  defp written(identifier, seq, hash, result, head \\ nil) do
    body = %{"identifier" => identifier, "seq" => seq, "entry_hash" => hash, "result" => result}
    json(200, if(head, do: Map.put(body, "head", head), else: body))
  end

  defp head_of(log), do: Identity.hash(List.last(log))

  defp json(status, body),
    do: {status, [{"content-type", "application/json"}], Jason.encode!(body)}

  # ---- accounts ----------------------------------------------------------------

  @doc """
  The test authority and resolver as the directory client's seam
  (`:sanctum, :directory_client`), restored on exit: the paths that read a
  directory without options reach the scripted directory.
  """
  @spec seam!(keyword()) :: :ok
  def seam!(tls) do
    prior = Application.fetch_env(:sanctum, :directory_client)
    Application.put_env(:sanctum, :directory_client, opts(tls))

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:sanctum, :directory_client, value)
        :error -> Application.delete_env(:sanctum, :directory_client)
      end
    end)
  end

  @doc """
  An account at the directory `url`, published in the directory agent
  `dir`: a genesis signed by a fresh recovery key, and one device key that
  recovery key added. Answers `%{identifier, url, recovery, devices,
  log}`: `recovery` the recovery key pair `{public, private}`, `devices`
  the device key pairs listed now, oldest first, and `log` its entries.
  """
  @spec account!(pid(), String.t()) :: map()
  def account!(dir, url) do
    {recovery_pub, recovery_priv} = recovery = keypair()

    {:ok, genesis} =
      Entry.new(
        kind: :genesis,
        seq: 0,
        at: now(),
        signer: Identity.recovery_signer(recovery_pub),
        directory: url,
        recovery: [recovery_pub]
      )

    genesis = Identity.sign(genesis, recovery_priv)

    account = %{
      identifier: Identity.identifier(genesis),
      url: url,
      recovery: recovery,
      devices: [],
      log: [genesis]
    }

    publish(dir, account.identifier, account.log)
    add_device!(dir, account)
  end

  @doc "A new device key the account's recovery key adds, published in `dir`."
  @spec add_device!(pid(), map()) :: map()
  def add_device!(dir, account) do
    {pub, _priv} = device = keypair()
    {:ok, key} = Key.new(alg: :ed25519, kind: :device, pub: pub)
    account = extend!(account, kind: :add_key, key: key)
    publish(dir, account.identifier, account.log)
    %{account | devices: account.devices ++ [device]}
  end

  @doc "The account's key `kid` removed by its recovery key, published in `dir`."
  @spec remove_key!(pid(), map(), String.t()) :: map()
  def remove_key!(dir, account, kid) do
    account = extend!(account, kind: :remove_key, kid: kid)
    publish(dir, account.identifier, account.log)
    %{account | devices: Enum.reject(account.devices, &(kid(&1) == kid))}
  end

  @doc """
  A recovery of the account by its recovery key, published in `dir`: a new
  recovery key and one new device key replace every key and the recovery
  set.
  """
  @spec recover!(pid(), map()) :: map()
  def recover!(dir, account) do
    {recovery_pub, _priv} = recovery = keypair()
    {pub, _} = device = keypair()
    {:ok, key} = Key.new(alg: :ed25519, kind: :device, pub: pub)
    account = extend!(account, kind: :recover, keys: [key], recovery: [recovery_pub])
    publish(dir, account.identifier, account.log)
    %{account | recovery: recovery, devices: [device]}
  end

  @doc "An entry after the account's head, signed by its recovery key, not yet published."
  @spec extend!(map(), keyword()) :: map()
  def extend!(account, fields) do
    {recovery_pub, recovery_priv} = account.recovery
    head = List.last(account.log)

    {:ok, entry} =
      Entry.new(
        [
          prev: Identity.hash(head),
          seq: head.seq + 1,
          at: now(),
          signer: Identity.recovery_signer(recovery_pub)
        ] ++ fields
      )

    %{account | log: account.log ++ [Identity.sign(entry, recovery_priv)]}
  end

  @doc "A device key pair's `kid`."
  @spec kid({binary(), binary()}) :: String.t()
  def kid({pub, _priv}), do: Key.kid(pub)

  @doc "The account's head: its last entry's hash."
  @spec head(map()) :: String.t()
  def head(%{log: log}), do: head_of(log)

  @doc """
  Cache the account's head at this home, read from its directory as a
  first read reads it. Needs the seam (`seam!/1`).
  """
  @spec cached!(map()) :: map()
  def cached!(account) do
    {:ok, head} = Sanctum.IdentityFreshness.fresh!(account.identifier, directory: account.url)
    head
  end

  @doc """
  Make the person `user_id` this home's member by `account`: their
  identity row names its identifier, its directory and its head, and the
  head is cached. Any identity row they held is replaced. Needs the seam
  (`seam!/1`).
  """
  @spec account_person!(String.t(), map()) :: :ok
  def account_person!(user_id, account) do
    import Ecto.Query, only: [from: 2]

    Arca.Repo.delete_all(from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^user_id))

    {:ok, _row} =
      Arca.PersonIdentities.create(Prima.Actor.system(), %{
        user_id: user_id,
        provenance: "remote",
        identifier: account.identifier,
        directory_url: account.url,
        head_hash: head(account)
      })

    _head = cached!(account)
    :ok
  end

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  defp now, do: System.os_time(:millisecond)
end
