# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DirectoryControllerTest do
  @moduledoc """
  The identity directory's routes, through the endpoint: each answer and
  each refusal on the wire, the body bounded before it is decoded, and the
  home's client (`Sanctum.Directory.Client`) speaking to them over HTTPS,
  end to end.
  """

  # The directory setting, this member's rate counters, the private-egress
  # configuration and the resolver's observer are process-wide.
  use CyfrWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Prima.Identity
  alias Prima.Identity.{Entry, RecoverRequest}
  alias Sanctum.Directory.Client

  @directory "https://dir.example"

  setup do
    Prima.RateLimiter.reset()
    on_exit(&Prima.RateLimiter.reset/0)
    Cyfr.Test.Settings.put("directory_serve", "writer")
    :ok
  end

  # ---- fixtures ----------------------------------------------------------------

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  defp person(directory \\ @directory) do
    {live, _} = keypair()
    {op_pub, op_priv} = keypair()
    {rec_pub, rec_priv} = keypair()

    {:ok, genesis} =
      Entry.genesis(
        live_key: live,
        operational_key: op_pub,
        recovery_keys: [rec_pub],
        directory: directory
      )

    genesis = Identity.sign(genesis, op_priv)

    %{
      genesis: genesis,
      identifier: Identity.identifier(genesis),
      operational: op_priv,
      recovery: rec_priv,
      recovery_key: rec_pub,
      directory: directory,
      head: Identity.hash(genesis),
      revision: 0
    }
  end

  defp rotation(person, signer \\ nil) do
    {live, _} = keypair()
    {:ok, entry} = Entry.rotate(person.head, live)
    Identity.sign(entry, signer || person.operational)
  end

  defp request(person, opts \\ []) do
    {live, _} = keypair()
    {op, _} = keypair()

    {:ok, request} =
      RecoverRequest.new(
        identifier: Keyword.get(opts, :identifier, person.identifier),
        directory: Keyword.get(opts, :directory, person.directory),
        live_key: live,
        operational_key: op,
        recovery_keys: Keyword.get(opts, :recovery_keys),
        expected_revision: Keyword.get(opts, :revision, person.revision),
        request_id: Keyword.get(opts, :request_id, "req_#{System.unique_integer([:positive])}")
      )

    Identity.sign(request, person.recovery)
  end

  defp from_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  defp register(conn, person),
    do: post_json(conn, "/directory/v1/genesis", Entry.encode(person.genesis))

  defp register!(conn, person) do
    assert %{"seq" => 0} = json_response(register(conn, person), 200)
    person
  end

  defp append(conn, person, entry),
    do: post_json(conn, "/directory/v1/#{person.identifier}/entries", Entry.encode(entry))

  defp recover(conn, identifier, request),
    do: post_json(conn, "/directory/v1/#{identifier}/recover", RecoverRequest.encode(request))

  # ---- the answers -------------------------------------------------------------

  describe "POST /directory/v1/genesis" do
    test "answers the identifier the genesis hashes to; the same genesis again is 200, one log",
         %{conn: conn} do
      alice = person()

      assert %{"identifier" => id, "seq" => 0, "entry_hash" => hash} =
               json_response(register(conn, alice), 200)

      assert id == alice.identifier and hash == alice.head

      assert json_response(register(build_conn(), alice), 200) == %{
               "identifier" => id,
               "seq" => 0,
               "entry_hash" => hash
             }

      assert %{"entries" => [_one], "length" => 1, "next" => nil} =
               json_response(get(build_conn(), "/directory/v1/#{id}"), 200)
    end

    test "is 429 past five a minute from one address, with its bound", %{conn: conn} do
      for _ <- 1..5 do
        assert %{"error" => "invalid"} =
                 conn
                 |> from_ip({198, 51, 100, 5})
                 |> post_json("/directory/v1/genesis", %{})
                 |> json_response(422)
      end

      refused = build_conn() |> from_ip({198, 51, 100, 5}) |> register(person())

      assert %{"error" => "rate_limited", "retry_after" => seconds} = json_response(refused, 429)
      assert get_resp_header(refused, "retry-after") == [Integer.to_string(seconds)]
    end

    test "is 503 at the identity quota, retryable after a minute", %{conn: conn} do
      register!(conn, person())
      Cyfr.Test.Settings.put("directory_max_identities", 1)

      refused = register(build_conn(), person())
      assert %{"error" => "capacity", "exhausted" => "identities"} = json_response(refused, 503)
      assert get_resp_header(refused, "retry-after") == ["60"]
    end

    test "a body over 16 KiB is refused 413, before any of it is decoded, however the path is spelled",
         %{conn: conn} do
      body = ~s({"pad":") <> String.duplicate("x", Prima.Identity.max_entry_bytes()) <> ~s("})

      # The router drops empty segments, so each of these reaches the
      # directory's routes and must meet its limit.
      for path <- [
            "/directory/v1/genesis",
            "http://www.example.com//directory/v1/genesis",
            "http://www.example.com//directory//v1/#{person().identifier}/entries"
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
      # Recoveries naming 301 recovery keys each, about 14 KiB an entry.
      alice = register!(conn, person())

      alice =
        Enum.reduce(0..5, alice, fn revision, person ->
          big = [person.recovery_key | for(_ <- 1..300, do: elem(keypair(), 0))]
          req = request(person, recovery_keys: big)
          answer = json_response(recover(build_conn(), person.identifier, req), 200)
          %{person | head: answer["entry_hash"], revision: revision + 1}
        end)

      first = get(build_conn(), "/directory/v1/#{alice.identifier}")
      assert byte_size(first.resp_body) <= 65_536

      assert %{"from" => 0, "next" => 4, "length" => 7, "head" => head} =
               page = json_response(first, 200)

      assert head == alice.head

      second = get(build_conn(), "/directory/v1/#{alice.identifier}?after=4")
      assert %{"from" => 5, "next" => nil, "entries" => rest} = json_response(second, 200)

      assert {:ok, %{head: ^head, length: 7}} = Identity.verify_chain(page["entries"] ++ rest)
    end

    test "an unknown identifier is 404, and a position that is not one is 422", %{conn: conn} do
      assert %{"error" => "not_found"} =
               json_response(get(conn, "/directory/v1/#{person().identifier}"), 404)

      alice = register!(build_conn(), person())

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

  describe "POST /directory/v1/:identifier/entries" do
    test "appends a rotation; one on a stale head is 409 with the current head", %{conn: conn} do
      alice = register!(conn, person())
      entry = rotation(alice)

      assert %{"seq" => 1, "entry_hash" => hash} =
               json_response(append(build_conn(), alice, entry), 200)

      assert hash == Identity.hash(entry)

      assert %{"error" => "stale_head", "head" => ^hash} =
               json_response(append(build_conn(), alice, rotation(alice)), 409)
    end

    test "a rotation past the identifier's 100 a day is 503 capacity until its window ends",
         %{conn: conn} do
      alice = register!(conn, person())

      for _ <- 1..100 do
        :ok =
          Arca.RequestRateWindows.claim(
            Prima.Actor.system(),
            :directory_rotation_daily,
            alice.identifier,
            100,
            86_400_000
          )
      end

      refused = append(build_conn(), alice, rotation(alice))

      assert %{"error" => "capacity", "exhausted" => "rotations"} = json_response(refused, 503)
      assert [seconds] = get_resp_header(refused, "retry-after")
      assert String.to_integer(seconds) in 86_000..86_400

      assert %{"seq" => 1} =
               json_response(recover(build_conn(), alice.identifier, request(alice)), 200)
    end

    test "an entry whose chain does not verify is 422", %{conn: conn} do
      alice = register!(conn, person())
      {_pub, stranger} = keypair()

      assert %{"error" => "unverified", "reason" => "wrong_signer"} =
               json_response(append(build_conn(), alice, rotation(alice, stranger)), 422)
    end
  end

  describe "POST /directory/v1/:identifier/recover" do
    test "a lost accepted answer is answered the same, and the outcome is the entry", %{
      conn: conn
    } do
      alice = register!(conn, person())
      req = request(alice)

      assert %{"seq" => 1, "entry" => entry} =
               first = json_response(recover(build_conn(), alice.identifier, req), 200)

      assert json_response(recover(build_conn(), alice.identifier, req), 200) == first
      assert {:ok, %Entry{kind: :recover, request: ^req}} = Entry.decode(entry)

      assert %{"outcome" => "accepted", "entry" => ^entry, "seq" => 1} =
               json_response(
                 get(
                   build_conn(),
                   "/directory/v1/#{alice.identifier}/requests/#{req.request_id}"
                 ),
                 200
               )
    end

    test "a stale revision is 409 with its recorded refusal, the same for the same request id",
         %{conn: conn} do
      alice = register!(conn, person())
      assert json_response(recover(build_conn(), alice.identifier, request(alice)), 200)
      late = request(alice)

      assert %{"error" => "stale_policy", "recorded" => recorded} =
               json_response(recover(build_conn(), alice.identifier, late), 409)

      assert recorded == %{"outcome" => "stale_policy", "expected_revision" => 0, "revision" => 1}

      assert %{"error" => "stale_policy", "recorded" => ^recorded} =
               json_response(recover(build_conn(), alice.identifier, late), 409)

      assert %{"outcome" => "stale_policy", "recorded" => ^recorded} =
               json_response(
                 get(
                   build_conn(),
                   "/directory/v1/#{alice.identifier}/requests/#{late.request_id}"
                 ),
                 200
               )
    end

    test "a request naming another directory is 422", %{conn: conn} do
      alice = register!(conn, person())

      assert %{"error" => "unverified", "reason" => "directory_changed"} =
               json_response(
                 recover(
                   build_conn(),
                   alice.identifier,
                   request(alice, directory: "https://other.example")
                 ),
                 422
               )
    end

    test "a request whose signed identifier is not the path's is 422", %{conn: conn} do
      alice = register!(conn, person())
      bob = register!(build_conn(), person())

      assert %{"error" => "wrong_identifier"} =
               json_response(recover(build_conn(), bob.identifier, request(alice)), 422)
    end
  end

  describe "serving" do
    test "a mirror answers 405 to every write and serves reads", %{conn: conn} do
      alice = register!(conn, person())
      Cyfr.Test.Settings.put("directory_serve", "mirror")

      for refused <- [
            register(build_conn(), person()),
            append(build_conn(), alice, rotation(alice)),
            recover(build_conn(), alice.identifier, request(alice))
          ] do
        assert %{"error" => "read_only"} = json_response(refused, 405)
        assert get_resp_header(refused, "allow") == ["GET"]
      end

      assert %{"length" => 1} =
               json_response(get(build_conn(), "/directory/v1/#{alice.identifier}"), 200)
    end

    test "a node that serves no directory answers 404 not_served", %{conn: conn} do
      Cyfr.Test.Settings.put("directory_serve", "off")

      assert %{"error" => "not_served"} = json_response(register(conn, person()), 404)

      assert %{"error" => "not_served"} =
               json_response(get(build_conn(), "/directory/v1/#{person().identifier}"), 404)
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
      targets = Application.fetch_env(:sanctum, :private_egress_targets)
      Application.put_env(:sanctum, :private_egress_targets, ["dir-a.test", "dir-b.test"])

      on_exit(fn ->
        Front.stop(front)

        case targets do
          {:ok, value} -> Application.put_env(:sanctum, :private_egress_targets, value)
          :error -> Application.delete_env(:sanctum, :private_egress_targets)
        end
      end)

      %{
        port: front.port,
        opts: [resolver: Resolver, cacerts: tls[:client_config][:cacerts]]
      }
    end

    test "registers, rotates, recovers and resolves, verifying and caching each head",
         %{port: port, opts: opts} do
      alice = person("https://dir-a.test:#{port}")
      genesis = Entry.encode(alice.genesis)

      assert {:ok, %{seq: 0}} = Client.register(alice.identifier, genesis, opts)

      assert {:ok, %{state: %{length: 1}, head: first}} =
               Client.resolve(alice.identifier, genesis, opts)

      rotated = rotation(alice)
      assert {:ok, %{seq: 1}} = Client.append(alice.identifier, genesis, rotated, opts)

      assert {:error, {:stale_head, head}} =
               Client.append(alice.identifier, genesis, rotation(alice), opts)

      assert head == Identity.hash(rotated)

      req = request(alice)

      assert {:ok, %{seq: 2, entry: %Entry{request: ^req}} = recovered} =
               Client.recover(alice.identifier, genesis, req, opts)

      assert {:ok, ^recovered} = Client.recover(alice.identifier, genesis, req, opts)

      assert {:ok, %{outcome: :accepted, seq: 2}} =
               Client.outcome(alice.identifier, genesis, req.request_id, opts)

      late = request(alice)

      assert {:error, {:stale_policy, %{"revision" => 1}}} =
               Client.recover(alice.identifier, genesis, late, opts)

      assert {:ok, %{state: state, head: moved}} = Client.resolve(alice.identifier, genesis, opts)
      assert state.length == 3 and state.revision == 1
      assert state.operational_key == req.operational_key
      assert moved.head_hash == recovered.entry_hash
      assert moved.key_epoch != first.key_epoch
      assert {:ok, %{state: ^state}} = Client.cached(alice.identifier)
    end

    test "two people on two directories each resolve at their own", %{port: port, opts: opts} do
      alice = person("https://dir-a.test:#{port}")
      bob = person("https://dir-b.test:#{port}")

      for someone <- [alice, bob] do
        genesis = Entry.encode(someone.genesis)
        assert {:ok, _} = Client.register(someone.identifier, genesis, opts)

        assert {:ok, %{head: %{directory_url: url}}} =
                 Client.resolve(someone.identifier, genesis, opts)

        assert url == someone.directory
      end

      reads = fronted()

      hosts = fn identifier ->
        for {"GET", "/directory/v1/" <> rest, host} <- reads,
            String.starts_with?(rest, identifier),
            uniq: true,
            do: host
      end

      assert hosts.(alice.identifier) == ["dir-a.test"]
      assert hosts.(bob.identifier) == ["dir-b.test"]
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
