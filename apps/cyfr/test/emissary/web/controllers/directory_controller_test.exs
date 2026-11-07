# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DirectoryControllerTest do
  @moduledoc """
  The directory's routes, `cyfr-directory/v2`, through the endpoint: each
  answer and each refusal on the wire, the body bounded before it is
  decoded, a log read after an entry's hash, a tombstoned account gone,
  and the home's client and freshness (`Sanctum.Directory.Client`,
  `Sanctum.IdentityFreshness`) speaking to them over HTTPS, end to end.
  """

  # The directory setting, this node's public URL, this member's rate
  # counters, the private-egress configuration and the resolver's observer
  # are process-wide.
  use CyfrWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Prima.Identity
  alias Prima.Identity.{Entry, Key}
  alias Sanctum.Directory.Client

  @directory "https://dir.example"

  setup do
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    serve_at(@directory)
    Cyfr.Test.Settings.put("directory_serve", "writer")
    :ok
  end

  # This node's public URL, and so the directory it serves
  # (`Sanctum.origin/0`), restored when the test ends.
  defp serve_at(url), do: Prima.Test.Env.put_app_env(:sanctum, :public_url, url)

  # ---- fixtures ----------------------------------------------------------------

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  defp now, do: System.os_time(:millisecond)

  defp device_key(pub) do
    {:ok, key} = Key.new(alg: :ed25519, kind: :device, pub: pub)
    key
  end

  # An account as its pages hold it: the recovery key pair, the genesis
  # naming `directory`, and the head and position it has reached.
  defp account(directory \\ @directory) do
    {pub, priv} = recovery = keypair()

    {:ok, genesis} =
      Entry.new(
        kind: :genesis,
        seq: 0,
        at: now(),
        signer: Identity.recovery_signer(pub),
        directory: directory,
        recovery: [pub]
      )

    genesis = Identity.sign(genesis, priv)

    %{
      genesis: genesis,
      identifier: Identity.identifier(genesis),
      recovery: recovery,
      directory: directory,
      head: Identity.hash(genesis),
      seq: 0
    }
  end

  # An entry after the account's head, signed by its recovery key, or by
  # `private` under the same signer.
  defp entry(account, fields, private \\ nil) do
    {pub, priv} = account.recovery

    {:ok, entry} =
      Entry.new(
        [
          prev: account.head,
          seq: account.seq + 1,
          at: now(),
          signer: Identity.recovery_signer(pub)
        ] ++ fields
      )

    Identity.sign(entry, private || priv)
  end

  defp added(account), do: entry(account, kind: :add_key, key: device_key(elem(keypair(), 0)))

  defp from_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  defp register(conn, account),
    do: post_json(conn, "/directory/v1/register", Entry.encode(account.genesis))

  defp register!(conn, account) do
    assert %{"seq" => 0, "result" => "created"} = json_response(register(conn, account), 200)
    account
  end

  defp append(conn, account, entry),
    do: post_json(conn, "/directory/v1/#{account.identifier}/append", Entry.encode(entry))

  defp append!(account, entry) do
    assert %{"result" => "accepted", "seq" => seq, "entry_hash" => hash} =
             json_response(append(build_conn(), account, entry), 200)

    %{account | head: hash, seq: seq}
  end

  # ---- the answers -------------------------------------------------------------

  describe "POST /directory/v1/register" do
    test "answers the identifier the genesis hashes to, created; the same genesis again exists, naming the head",
         %{conn: conn} do
      alice = account()

      assert %{"identifier" => id, "seq" => 0, "entry_hash" => hash, "result" => "created"} =
               json_response(register(conn, alice), 200)

      assert id == alice.identifier and hash == alice.head
      alice = append!(alice, added(alice))

      assert json_response(register(build_conn(), alice), 200) == %{
               "identifier" => id,
               "seq" => 0,
               "entry_hash" => hash,
               "result" => "exists",
               "head" => alice.head
             }

      assert %{"entries" => [_genesis, _added], "length" => 2, "next" => nil} =
               json_response(get(build_conn(), "/directory/v1/#{id}"), 200)
    end

    test "a genesis naming another directory, or this host on another port or under a path, " <>
           "is 422 wrong_directory and stores nothing",
         %{conn: conn} do
      register!(conn, account())

      for directory <- [
            "https://elsewhere.example",
            "https://dir.example:8443",
            "https://dir.example/directory"
          ] do
        stranger = account(directory)

        assert {^directory, %{"error" => "wrong_directory"}} =
                 {directory, json_response(register(build_conn(), stranger), 422)}

        assert json_response(get(build_conn(), "/directory/v1/#{stranger.identifier}"), 404) ==
                 %{"error" => "not_found"}
      end
    end

    test "is 429 past five a minute from one address, with its bound", %{conn: conn} do
      for _ <- 1..5 do
        assert %{"error" => "invalid"} =
                 conn
                 |> from_ip({198, 51, 100, 5})
                 |> post_json("/directory/v1/register", %{})
                 |> json_response(422)
      end

      refused = build_conn() |> from_ip({198, 51, 100, 5}) |> register(account())

      assert %{"error" => "rate_limited", "retry_after" => seconds} = json_response(refused, 429)
      assert get_resp_header(refused, "retry-after") == [Integer.to_string(seconds)]
    end

    test "is 503 at the identity quota, retryable after a minute", %{conn: conn} do
      register!(conn, account())
      Cyfr.Test.Settings.put("directory_max_identities", 1)

      refused = register(build_conn(), account())
      assert %{"error" => "capacity", "exhausted" => "identities"} = json_response(refused, 503)
      assert get_resp_header(refused, "retry-after") == ["60"]
    end

    test "a body over 16 KiB is refused 413, before any of it is decoded, however the path is spelled",
         %{conn: conn} do
      body = ~s({"pad":") <> String.duplicate("x", Prima.Identity.max_entry_bytes()) <> ~s("})

      # The router drops empty segments, so each of these reaches the
      # directory's routes, or the registry's beside it, and must meet the limit.
      for path <- [
            "/directory/v1/register",
            "http://www.example.com//directory/v1/register",
            "http://www.example.com//directory//v1/#{account().identifier}/append",
            "/v1/namespaces/personal/claim",
            "http://www.example.com//v1//namespaces/personal/claim"
          ] do
        assert_error_sent 413, fn -> post_json(conn, path, body) end
      end
    end

    test "a webhook body past its cap is refused 413 the same way, doubled slash or not",
         %{conn: conn} do
      body =
        ~s({"pad":") <>
          String.duplicate("x", Prima.Limits.default_max_request_size()) <> ~s("})

      for path <- ["/hooks/wh_none", "http://www.example.com//hooks/wh_none"] do
        assert_error_sent 413, fn -> post_json(conn, path, body) end
      end
    end
  end

  describe "GET /directory/v1/:identifier" do
    test "answers the stored canonical entries in pages of at most 64 KiB, linked by next",
         %{conn: conn} do
      # Recoveries listing 64 device keys each, about 10 KiB an entry.
      alice = register!(conn, account())
      {recovery_pub, _} = alice.recovery

      alice =
        Enum.reduce(1..9, alice, fn _, account ->
          keys = for _ <- 1..64, do: device_key(elem(keypair(), 0))
          append!(account, entry(account, kind: :recover, keys: keys, recovery: [recovery_pub]))
        end)

      first = get(build_conn(), "/directory/v1/#{alice.identifier}")
      assert byte_size(first.resp_body) <= 65_536

      assert %{"from" => 0, "next" => next, "length" => 10, "head" => head} =
               page = json_response(first, 200)

      assert is_integer(next)
      assert head == alice.head

      second = get(build_conn(), "/directory/v1/#{alice.identifier}?after=#{next}")
      assert %{"next" => nil, "entries" => rest} = json_response(second, 200)
      assert {:ok, %{head: ^head, seq: 9}} = Identity.verify_chain(page["entries"] ++ rest)
    end

    test "an unknown identifier is 404, and a position that is not one is 422", %{conn: conn} do
      assert %{"error" => "not_found"} =
               json_response(get(conn, "/directory/v1/#{account().identifier}"), 404)

      alice = register!(build_conn(), account())

      for position <- ["x", "-2", "2147483648", "99999999999999999999999"] do
        refused =
          build_conn()
          |> from_ip({198, 51, 100, 77})
          |> get("/directory/v1/#{alice.identifier}?after=#{position}")

        assert %{"error" => "invalid", "field" => "after"} = json_response(refused, 422)
      end

      # Refused before any rate claim: the address has spent nothing.
      assert Arca.Repo.all(
               from(w in Arca.Schemas.RequestRateWindow,
                 where: w.key_hash == ^Prima.Digest.sha256("198.51.100.77")
               )
             ) == []
    end
  end

  describe "GET /directory/v1/:identifier/from/:hash" do
    test "answers the entries after an entry's hash, none at the head, and 404 for a hash the log does not hold",
         %{conn: conn} do
      alice = register!(conn, account())
      at = alice.head
      alice = append!(alice, added(alice))

      assert %{"from" => 1, "entries" => [entry], "next" => nil, "length" => 2} =
               json_response(
                 get(build_conn(), "/directory/v1/#{alice.identifier}/from/#{at}"),
                 200
               )

      assert {:ok, %Entry{kind: :add_key}} = Entry.decode(entry)

      assert %{"from" => 2, "entries" => []} =
               json_response(
                 get(build_conn(), "/directory/v1/#{alice.identifier}/from/#{alice.head}"),
                 200
               )

      for hash <- [Prima.Digest.sha256("elsewhere"), "sha256:nope"] do
        assert %{"error" => "not_found"} =
                 json_response(
                   get(build_conn(), "/directory/v1/#{alice.identifier}/from/#{hash}"),
                   404
                 )
      end
    end
  end

  describe "POST /directory/v1/:identifier/append" do
    test "appends an entry; the same entry again exists; one on a stale head is 409 with the current head",
         %{conn: conn} do
      alice = register!(conn, account())
      first = added(alice)
      moved = append!(alice, first)

      assert %{"result" => "exists", "seq" => 1, "head" => head} =
               json_response(append(build_conn(), alice, first), 200)

      assert head == moved.head

      assert %{"error" => "stale_head", "head" => ^head} =
               json_response(append(build_conn(), alice, added(alice)), 409)
    end

    test "a key listed twice is 409 duplicate_key, and an entry whose chain does not verify is 422",
         %{conn: conn} do
      alice = register!(conn, account())
      {pub, _} = keypair()
      alice = append!(alice, entry(alice, kind: :add_key, key: device_key(pub)))

      assert %{"error" => "duplicate_key"} =
               json_response(
                 append(build_conn(), alice, entry(alice, kind: :add_key, key: device_key(pub))),
                 409
               )

      {_pub, stranger} = keypair()

      assert %{"error" => "unverified", "reason" => "wrong_signer"} =
               json_response(
                 append(
                   build_conn(),
                   alice,
                   entry(alice, [kind: :add_key, key: device_key(elem(keypair(), 0))], stranger)
                 ),
                 422
               )

      assert %{"error" => "invalid", "reason" => "unexpected_genesis"} =
               json_response(append(build_conn(), alice, alice.genesis), 422)
    end

    test "a listed key's write past the identifier's 100 a day is 503 capacity writes until its window ends",
         %{conn: conn} do
      alice = register!(conn, account())
      {device_pub, device_priv} = keypair()
      alice = append!(alice, entry(alice, kind: :add_key, key: device_key(device_pub)))

      for _ <- 1..100 do
        :ok =
          Arca.RequestRateWindows.claim(
            Prima.Actor.system(),
            :directory_writes_daily,
            alice.identifier,
            100,
            86_400_000
          )
      end

      {:ok, by_device} =
        Entry.new(
          prev: alice.head,
          seq: alice.seq + 1,
          at: now(),
          signer: Key.kid(device_pub),
          kind: :add_key,
          key: device_key(elem(keypair(), 0))
        )

      refused = append(build_conn(), alice, Identity.sign(by_device, device_priv))

      assert %{"error" => "capacity", "exhausted" => "writes"} = json_response(refused, 503)
      assert [seconds] = get_resp_header(refused, "retry-after")
      assert String.to_integer(seconds) in 86_000..86_400

      # A recovery key's write is exempt from the day.
      assert %{"seq" => 2} = json_response(append(build_conn(), alice, added(alice)), 200)
    end
  end

  describe "serving" do
    test "a mirror answers 405 to every write and serves reads", %{conn: conn} do
      alice = register!(conn, account())
      Cyfr.Test.Settings.put("directory_serve", "mirror")

      for refused <- [
            register(build_conn(), account()),
            append(build_conn(), alice, added(alice))
          ] do
        assert %{"error" => "read_only"} = json_response(refused, 405)
        assert get_resp_header(refused, "allow") == ["GET"]
      end

      assert %{"length" => 1} =
               json_response(get(build_conn(), "/directory/v1/#{alice.identifier}"), 200)
    end

    test "a node that serves no directory answers 404 not_served", %{conn: conn} do
      Cyfr.Test.Settings.put("directory_serve", "off")

      assert %{"error" => "not_served"} = json_response(register(conn, account()), 404)

      assert %{"error" => "not_served"} =
               json_response(get(build_conn(), "/directory/v1/#{account().identifier}"), 404)
    end

    test "a tombstoned account is 410 gone to every read and write", %{conn: conn} do
      alice = register!(conn, account())
      :ok = Sanctum.Directory.tombstone(alice.identifier)

      for refused <- [
            get(build_conn(), "/directory/v1/#{alice.identifier}"),
            get(build_conn(), "/directory/v1/#{alice.identifier}/from/#{alice.head}"),
            append(build_conn(), alice, added(alice)),
            register(build_conn(), alice)
          ] do
        assert json_response(refused, 410) == %{"error" => "gone"}
      end
    end
  end

  # ---- end to end --------------------------------------------------------------

  defmodule Resolver do
    @moduledoc false
    # The two test directories, on loopback.
    def getaddr(name, :inet) do
      if to_string(name) in ["dir-a.test", "dir-b.test"],
        do: {:ok, {127, 0, 0, 1}},
        else: {:error, :nxdomain}
    end

    def getaddr(_name, :inet6), do: {:error, :nxdomain}
  end

  defmodule Front do
    @moduledoc false
    # A TLS front on loopback that hands each request it reads to the
    # endpoint, as the deployment's proxy does, and writes the answer back.

    def start(ssl_options, observer) do
      {:ok, listen} =
        :ssl.listen(
          0,
          ssl_options ++ [ip: {127, 0, 0, 1}, active: false, mode: :binary, reuseaddr: true]
        )

      {:ok, {_address, port}} = :ssl.sockname(listen)
      pid = spawn(fn -> accept(listen, observer) end)
      %{port: port, pid: pid, listen: listen}
    end

    def stop(%{pid: pid, listen: listen}) do
      Process.exit(pid, :kill)
      :ssl.close(listen)
    end

    defp accept(listen, observer) do
      case :ssl.transport_accept(listen) do
        {:ok, socket} ->
          serve(socket, observer)
          accept(listen, observer)

        {:error, _closed} ->
          :ok
      end
    end

    defp serve(socket, observer) do
      with {:ok, socket} <- :ssl.handshake(socket, 5_000),
           {:ok, {method, target, headers, body}} <- read(socket, "") do
        {"host", host} = List.keyfind(headers, "host", 0)
        send(observer, {:front, method, target, {"host", host}})

        # Plug keeps the host apart from the other headers.
        conn =
          headers
          |> Enum.reject(&(elem(&1, 0) == "host"))
          |> Enum.reduce(Phoenix.ConnTest.build_conn(), fn {name, value}, conn ->
            Plug.Conn.put_req_header(conn, name, value)
          end)

        conn =
          Phoenix.ConnTest.dispatch(
            %{conn | remote_ip: {198, 51, 100, 9}, host: host |> String.split(":") |> hd()},
            CyfrWeb.Endpoint,
            String.downcase(method),
            target,
            if(body == "", do: nil, else: body)
          )

        head =
          conn.resp_headers
          |> Enum.reject(fn {name, _} -> name in ["content-length", "connection"] end)
          |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)

        :ssl.send(
          socket,
          "HTTP/1.1 #{conn.status} Answer\r\ncontent-length: #{byte_size(conn.resp_body)}\r\n" <>
            "connection: close\r\n" <> head <> "\r\n" <> conn.resp_body
        )

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
            {:ok,
             {method, target, Enum.reject(headers, &(elem(&1, 0) == "content-length")), body}}
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

  describe "the home's client, end to end" do
    setup do
      san =
        {:Extension, {2, 5, 29, 17}, false,
         [{:dNSName, ~c"dir-a.test"}, {:dNSName, ~c"dir-b.test"}]}

      key = [key: {:namedCurve, :secp256r1}, digest: :sha256]

      tls =
        :public_key.pkix_test_data(%{
          server_chain: %{root: key, intermediates: [], peer: key ++ [extensions: [san]]},
          client_chain: %{root: key, intermediates: [], peer: key}
        })

      front = Front.start(tls[:server_config], self())
      on_exit(fn -> Front.stop(front) end)
      Prima.Test.Env.put_app_env(:sanctum, :private_egress_targets, ["dir-a.test", "dir-b.test"])

      %{
        port: front.port,
        opts: [resolver: Resolver, cacerts: tls[:client_config][:cacerts]]
      }
    end

    test "registers, appends and reads after a hash; freshness reads the log and walks it",
         %{port: port, opts: opts} do
      alice = account("https://dir-a.test:#{port}")
      serve_at(alice.directory)
      Prima.Test.Env.put_app_env(:sanctum, :directory_client, opts)

      assert {:ok, %{seq: 0, result: :created}} = Client.register(alice.genesis, opts)
      assert {:ok, %{result: :exists, head: head}} = Client.register(alice.genesis, opts)
      assert head == alice.head

      assert {:ok, first} =
               Sanctum.IdentityFreshness.fresh!(alice.identifier, directory: alice.directory)

      assert first.head_hash == alice.head

      {device_pub, _} = keypair()
      add = entry(alice, kind: :add_key, key: device_key(device_pub))

      assert {:ok, %{seq: 1, result: :accepted}} =
               Client.append(alice.identifier, alice.directory, add, opts)

      assert {:ok, %{result: :exists}} =
               Client.append(alice.identifier, alice.directory, add, opts)

      alice = %{alice | head: Identity.hash(add), seq: 1}

      # An entry built on the genesis meets the moved head.
      stale =
        entry(%{alice | head: first.head_hash, seq: 0},
          kind: :add_key,
          key: device_key(elem(keypair(), 0))
        )

      current = alice.head

      assert {:error, {:stale_head, ^current}} =
               Client.append(alice.identifier, alice.directory, stale, opts)

      removal = entry(alice, kind: :remove_key, kid: Key.kid(device_pub))
      assert {:ok, %{seq: 2}} = Client.append(alice.identifier, alice.directory, removal, opts)

      assert {:ok, %{entries: [_add, _removal], length: 3}} =
               Client.entries_after(alice.identifier, alice.directory, first.head_hash, 0, opts)

      assert {:ok, moved} = Sanctum.IdentityFreshness.fresh!(alice.identifier)
      assert moved.head_hash == Identity.hash(removal)
      assert {:ok, %{keys: []}} = Sanctum.IdentityFreshness.state(moved)
    end

    test "two people on two directories each read at their own, and this node's own where it is kept",
         %{port: port, opts: opts} do
      alice = account("https://dir-a.test:#{port}")
      bob = account("https://dir-b.test:#{port}")

      # One endpoint answers under both names, as two nodes sharing one
      # store would: each genesis is registered while it serves the
      # directory that genesis names.
      for someone <- [alice, bob] do
        serve_at(someone.directory)
        assert {:ok, _} = Client.register(someone.genesis, opts)
      end

      _registered = fronted()

      hosts = fn reads, identifier ->
        for {"GET", "/directory/v1/" <> rest, host} <- reads,
            String.starts_with?(rest, identifier),
            uniq: true,
            do: host
      end

      # While this node serves one of the two directories, its own log is
      # read where it is kept, with no request, and the other at its own.
      for {here, there, host} <- [{alice, bob, "dir-b.test"}, {bob, alice, "dir-a.test"}] do
        serve_at(here.directory)
        assert {:ok, %{length: 1}} = Client.log(here.identifier, here.directory, opts)
        assert {:ok, %{length: 1}} = Client.log(there.identifier, there.directory, opts)

        reads = fronted()
        assert hosts.(reads, here.identifier) == []
        assert hosts.(reads, there.identifier) == [host]
      end
    end
  end

  # Every request the front handed on, as `{method, target, host name}`.
  defp fronted do
    receive do
      {:front, method, target, {"host", host}} ->
        [{method, target, host |> String.split(":") |> hd()} | fronted()]
    after
      0 -> []
    end
  end
end
