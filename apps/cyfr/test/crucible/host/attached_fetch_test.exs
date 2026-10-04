# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Host.AttachedFetchTest do
  @moduledoc """
  A guest's request that names a connection is made by the control plane
  (`Crucible.Host.AttachedFetch`), end to end through the host and its
  listener (`Crucible.HostListener`) against a loopback upstream: a
  catalyst published with an attach rule, its entry consented through
  `Sanctum.Consent.Plan` and `Commit`, an attempt of it under the
  authority that consent grants.

  Admitted, the upstream receives the request with the credential the
  rule attaches, and the answer streams back as sealed frames with the
  credential masked out of the head and across chunks; the value joins the
  attempt's masking set and is audited by field and destination. Refused,
  the answer names the call id, is recorded, and nothing reaches the
  upstream: a connection the edge does not bind, a header or query member
  the rule owns, a URL outside the destination, a URL outside the grant's
  egress, a private upstream the grant does not name, an expired or spent
  binding, and the rate. The address connected to is the address pinned,
  whatever the resolver answers after; a redirect is answered and never
  followed; a body past the node's bound, the attempt's deadline and a
  runner connection that closes each end the stream and close the
  upstream connection.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Crucible.Host.AttachedFetch
  alias Crucible.HostListener
  alias Cyfr.Test.AttemptFixtures
  alias Prima.{AttachedRequest, WorkerAuth, WorkerWire}
  alias Sanctum.Consent.{Commit, Plan}

  @math_wasm_path Path.expand("../../support/test_wasm/math.wasm", __DIR__)
  @secret "sk-attached-canary-0123456789"
  @header_rule %{"in" => "header", "name" => "x-api-key", "template" => "{value}"}

  @vectors_path Path.expand("../../../../../tests/fixtures/host_api.json", __DIR__)
  @external_resource @vectors_path
  @vectors @vectors_path |> File.read!() |> Jason.decode!()

  defmodule Upstream do
    @moduledoc """
    The loopback upstream: every request is told to the test, and the
    path names the answer.
    """
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{parent: parent}) do
      {:ok, body, conn} = read_body(conn)

      send(parent, {
        :upstream,
        self(),
        %{
          method: conn.method,
          path: conn.request_path,
          query: conn.query_string,
          headers: conn.req_headers,
          body: body
        }
      })

      answer(conn, conn.request_path, parent)
    end

    # The credential echoed back, in a header and across two pieces of
    # body, the second sent once the test has seen the first.
    defp answer(conn, "/echo", _parent) do
      [key] = get_req_header(conn, "x-api-key")
      half = div(byte_size(key), 2)
      <<first::binary-size(^half), second::binary>> = key
      conn = conn |> put_resp_header("x-echo", key) |> send_chunked(200)
      {:ok, conn} = chunk(conn, "key: " <> first)

      receive do
        :continue -> :ok
      after
        5_000 -> :ok
      end

      {:ok, conn} = chunk(conn, second <> " tail")
      conn
    end

    defp answer(conn, "/redirect", _parent) do
      conn
      |> put_resp_header("location", "/elsewhere")
      |> send_resp(302, "moved")
    end

    defp answer(conn, "/big", _parent), do: send_resp(conn, 200, String.duplicate("x", 200))

    # An answer that keeps coming until the reader goes, which it reports.
    defp answer(conn, "/slow", parent) do
      conn = send_chunked(conn, 200)
      {:ok, conn} = chunk(conn, "first")
      keep_writing(conn, parent, 200)
    end

    # A head CYFR refuses, then a body that keeps coming until the reader
    # goes, which it reports: a content coding, a 206, or a content-range.
    defp answer(conn, "/held", parent) do
      conn =
        case URI.decode_query(conn.query_string) do
          %{"as" => "encoded"} ->
            conn |> put_resp_header("content-encoding", "gzip") |> send_chunked(200)

          %{"as" => "partial"} ->
            conn |> put_resp_header("content-range", "bytes 0-9/100") |> send_chunked(206)

          %{"as" => "ranged"} ->
            conn |> put_resp_header("content-range", "bytes 0-9/100") |> send_chunked(200)
        end

      {:ok, conn} = chunk(conn, "first")
      keep_writing(conn, parent, 200)
    end

    # The credential quoted in a plain body, as an error page quoting the
    # request does; the server compresses it for a client that accepts it.
    defp answer(conn, "/reflect", _parent) do
      [key] = get_req_header(conn, "x-api-key")
      send_resp(conn, 200, "invalid key: " <> key)
    end

    # An answer in the content encoding the query names, whatever the
    # client accepts.
    defp answer(conn, "/encoded", _parent) do
      [key] = get_req_header(conn, "x-api-key")
      %{"as" => encoding} = URI.decode_query(conn.query_string)
      body = "key: " <> key
      body = if encoding == "gzip", do: :zlib.gzip(body), else: body

      conn
      |> put_resp_header("content-encoding", encoding)
      |> send_resp(200, body)
    end

    # The credential reflected as a response header's name, in the case it
    # was sent in.
    defp answer(conn, "/name", _parent) do
      [key] = get_req_header(conn, "x-api-key")

      %{conn | resp_headers: [{key, "seen"} | conn.resp_headers]}
      |> put_resp_header("x-kept", "kept")
      |> send_resp(200, "ok")
    end

    # The rule's own header reflected back, under a value of its own.
    defp answer(conn, "/rule", _parent) do
      conn
      |> put_resp_header("x-api-key", "not-the-credential")
      |> put_resp_header("x-kept", "kept")
      |> send_resp(200, "ok")
    end

    defp answer(conn, _path, _parent), do: send_resp(conn, 200, "hello from upstream")

    defp keep_writing(conn, parent, 0) do
      send(parent, {:upstream_still_open, self()})
      conn
    end

    defp keep_writing(conn, parent, left) do
      receive do
      after
        50 -> :ok
      end

      case chunk(conn, ".") do
        {:ok, conn} ->
          keep_writing(conn, parent, left - 1)

        {:error, _closed} ->
          send(parent, {:upstream_closed, self()})
          conn
      end
    end
  end

  defmodule RawUpstream do
    @moduledoc """
    A loopback upstream writing scripted HTTP/1.1 answers byte for byte:
    repeated header lines, transfer codings and informational answers that
    a server framework would not write. Each request is told to the test.
    """

    def run(parent) do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      send(parent, {:raw_port, port})
      loop(listen, parent)
    end

    defp loop(listen, parent) do
      {:ok, socket} = :gen_tcp.accept(listen)
      [request_line | lines] = socket |> read_head("") |> String.split("\r\n", trim: true)
      [_method, target, _version] = String.split(request_line, " ")

      headers =
        for line <- lines,
            [name, value] <- [String.split(line, ":", parts: 2)],
            do: {String.downcase(name), String.trim(value)}

      send(parent, {:raw_request, target, headers})
      {_name, key} = List.keyfind(headers, "x-api-key", 0, {"x-api-key", "none"})
      :ok = :gen_tcp.send(socket, answer(URI.parse(target).path, key))
      :gen_tcp.close(socket)
      loop(listen, parent)
    end

    defp read_head(socket, read) do
      if String.contains?(read, "\r\n\r\n") do
        read
      else
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_head(socket, read <> data)
      end
    end

    defp gz(key), do: :zlib.gzip("key: " <> key)

    defp fixed(status_line, headers, body) do
      status_line <>
        "\r\n" <>
        Enum.map_join(headers, "", fn {name, value} -> name <> ": " <> value <> "\r\n" end) <>
        "connection: close\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body
    end

    # Two content-encoding lines: together `gzip, identity`, a gzip body.
    defp answer("/ce-twice", key),
      do:
        fixed(
          "HTTP/1.1 200 OK",
          [{"content-encoding", "gzip"}, {"content-encoding", "identity"}],
          gz(key)
        )

    defp answer("/te-gzip-chunked", key) do
      body = gz(key)
      size = Integer.to_string(byte_size(body), 16)

      "HTTP/1.1 200 OK\r\ntransfer-encoding: gzip, chunked\r\nconnection: close\r\n\r\n" <>
        size <> "\r\n" <> body <> "\r\n0\r\n\r\n"
    end

    defp answer("/te-gzip", key),
      do: "HTTP/1.1 200 OK\r\ntransfer-encoding: gzip\r\nconnection: close\r\n\r\n" <> gz(key)

    # A part of a body quoting the credential, asked for or not.
    defp answer("/partial", key),
      do:
        fixed(
          "HTTP/1.1 206 Partial Content",
          [{"content-range", "bytes 0-9/100"}],
          binary_part("key: " <> key, 0, 10)
        )

    # The credential's forms as header names, as Mint hands them over.
    # Its unpadded base64, for a credential whose length is no multiple of
    # three, so its padded forms end in a character no name holds.
    defp answer("/b64-unpadded-name", key),
      do:
        fixed(
          "HTTP/1.1 200 OK",
          [{Base.url_encode64(key, padding: false), "seen"}, {"x-kept", "kept"}],
          "ok"
        )

    # Parts of a body in a 206 whose ranges sit in each part, so its head
    # carries no content-range.
    defp answer("/multipart-206", key) do
      body =
        "--part\r\ncontent-type: text/plain\r\ncontent-range: bytes 0-9/100\r\n\r\n" <>
          binary_part("key: " <> key, 0, 10) <> "\r\n--part--\r\n"

      fixed(
        "HTTP/1.1 206 Partial Content",
        [{"content-type", "multipart/byteranges; boundary=part"}],
        body
      )
    end

    # A whole answer under a range header nobody asked for.
    defp answer("/content-range", key),
      do: fixed("HTTP/1.1 200 OK", [{"content-range", "bytes 0-9/100"}], "key: " <> key)

    defp answer("/b64-name", key),
      do: fixed("HTTP/1.1 200 OK", [{Base.url_encode64(key), "seen"}, {"x-kept", "kept"}], "ok")

    defp answer("/hex-name", key),
      do:
        fixed(
          "HTTP/1.1 200 OK",
          [{Base.encode16(key, case: :lower), "seen"}, {"x-kept", "kept"}],
          "ok"
        )

    # An informational answer quoting the credential, then the answer.
    defp answer("/early", key),
      do:
        "HTTP/1.1 103 Early Hints\r\nx-early: " <>
          key <> "\r\n\r\n" <> fixed("HTTP/1.1 200 OK", [], "plain")

    # A chunked body whose trailer quotes the credential.
    defp answer("/trailer", key),
      do:
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ntrailer: x-key\r\n" <>
          "connection: close\r\n\r\n5\r\nplain\r\n0\r\nx-key: " <> key <> "\r\n\r\n"

    # A chunked answer with no body, whose trailer section quotes the
    # credential: Finch hands it over as a second header block.
    defp answer("/trailer-empty", key),
      do:
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ntrailer: x-trailer, x-key\r\n" <>
          "connection: close\r\n\r\n0\r\nx-trailer: visible-trailer\r\nx-key: " <>
          key <> "\r\n\r\n"

    # A 101 nothing asked for, its head saying its body is gzip, the gzip
    # of the credential in the same write; and one carrying a content-range.
    defp answer("/switching-gzip", key),
      do: "HTTP/1.1 101 Switching Protocols\r\ncontent-encoding: gzip\r\n\r\n" <> gz(key)

    defp answer("/switching-range", key),
      do:
        "HTTP/1.1 101 Switching Protocols\r\ncontent-range: bytes 0-9/100\r\n\r\n" <>
          binary_part("key: " <> key, 0, 10)

    defp answer(_path, _key), do: fixed("HTTP/1.1 200 OK", [], "plain")
  end

  defmodule Resolver do
    @moduledoc """
    A resolver the cases script: each name answers the addresses queued
    for it, in order, the last one again once the queue is spent, and
    every lookup is noted. An address literal answers as `:inet` does.
    """

    def start_link(answers),
      do: Agent.start_link(fn -> %{answers: answers, looked_up: []} end, name: __MODULE__)

    def child_spec(answers),
      do: %{id: __MODULE__, start: {__MODULE__, :start_link, [answers]}}

    def looked_up, do: __MODULE__ |> Agent.get(& &1.looked_up) |> Enum.reverse()

    def getaddr(name, family) do
      name = name |> to_string() |> String.downcase()

      case :inet.parse_strict_address(String.to_charlist(name)) do
        {:ok, ip} ->
          {:ok, ip}

        {:error, _name} ->
          Agent.get_and_update(__MODULE__, fn state ->
            state = %{state | looked_up: [{name, family} | state.looked_up]}

            case Map.get(state.answers, name, []) do
              [ip] -> {{:ok, ip}, state}
              [ip | rest] -> {{:ok, ip}, put_in(state.answers[name], rest)}
              [] -> {{:error, :nxdomain}, state}
            end
          end)
      end
    end
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "attached_fetch_#{System.unique_integer([:positive])}")

    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    upstream =
      start_supervised!(
        {Bandit,
         plug: {Upstream, %{parent: self()}},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(upstream)
    {:ok, ctx: Sanctum.TestContext.local(:prism), port: port}
  end

  # ---------------------------------------------------------------------------
  # Scenarios
  # ---------------------------------------------------------------------------

  # The egress a catalyst asks for and its consent grants: the loopback
  # upstream, by address and by name, and its private address.
  defp egress(over \\ %{}) do
    Map.merge(
      %{
        "domains" => ["127.0.0.1", "upstream.test"],
        "methods" => ["GET", "POST", "DELETE"],
        "schemes" => ["http"],
        "private_ips" => ["127.0.0.1"]
      },
      over
    )
  end

  # A catalyst whose manifest declares the need `api_key` attached by
  # `:rule` and asks for `:egress`; an attach-only entry of its provider to
  # `:destination`, bound to the need through the consent walk with
  # `:lifetime`; and an attempt of the catalyst under the authority that
  # consent grants, with `:limits` and `:timeout_ms` when a case names them.
  defp scenario!(ctx, port, opts \\ []) do
    name = "attached-#{System.unique_integer([:positive])}"
    ref = "catalyst:local." <> name

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "catalyst",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:upstream.test",
          "reason" => "to call the upstream with your key",
          "fields" => ["KEY"],
          "attach" => Keyword.get(opts, :rule, @header_rule)
        }
      },
      "caps" => %{"egress" => Keyword.get(opts, :egress, egress())}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: name,
        version: "1.0.0",
        type: "catalyst",
        manifest: Jason.encode!(manifest)
      })

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "#{name} key",
        kind: "api_key",
        provider_hint: "upstream.test",
        fields: %{"KEY" => Keyword.get(opts, :secret, @secret)},
        destination:
          Keyword.get(opts, :destination, %{
            "hosts" => ["127.0.0.1", "upstream.test"],
            "scheme" => "http",
            "port" => port,
            "methods" => ["GET", "POST"]
          })
      })

    binding =
      %{need: "api_key", entry_id: entry.id}
      |> Prima.MapUtil.put_present(:lifetime, Keyword.get(opts, :lifetime))

    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, bindings: [binding]}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _committed} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    {:ok, authority} = Crucible.authority_for(ctx, :default, ref)

    {:ok, component_ref, _type, _component} =
      Crucible.Admission.inspect_component(ctx, ref <> ":1.0.0")

    limits = Map.merge(Prima.Authority.limits(authority), Keyword.get(opts, :limits, %{}))

    %{
      ref: ref,
      component_ref: component_ref,
      authority: authority,
      entry: entry,
      limits: limits,
      fixture: attempt!(ctx, authority, component_ref, limits, opts)
    }
  end

  defp attempt!(ctx, authority, component_ref, limits, opts) do
    AttemptFixtures.attached!(
      ctx: ctx,
      authority: authority,
      component_ref: component_ref,
      limits: limits,
      timeout_ms: Keyword.get(opts, :timeout_ms, 60_000)
    )
  end

  # Another root of the same catalyst under the same consent.
  defp another_root!(ctx, scenario),
    do: attempt!(ctx, scenario.authority, scenario.component_ref, scenario.limits, [])

  defp request(url, opts \\ []) do
    %AttachedRequest{
      call_id: AttachedRequest.call_id(:crypto.strong_rand_bytes(16)),
      connection: Keyword.get(opts, :connection, "api_key"),
      method: Keyword.get(opts, :method, "GET"),
      url: url,
      headers: Keyword.get(opts, :headers, []),
      body: Keyword.get(opts, :body, ""),
      purpose: Keyword.get(opts, :purpose, :fetch)
    }
  end

  # The request made for `fixture`'s attempt, in a process of its own, its
  # frames sent here as they are written.
  defp fetch(fixture, %AttachedRequest{} = request, opts \\ []) do
    test = self()

    emit =
      Keyword.get(opts, :emit, fn frame ->
        send(test, {:frame, request.call_id, frame})
        :ok
      end)

    caller = AttemptFixtures.caller(fixture)

    Task.async(fn ->
      AttachedFetch.run(caller, request, emit, Keyword.take(opts, [:resolver]))
    end)
  end

  defp fetched(fixture, request, opts \\ []),
    do: fixture |> fetch(request, opts) |> Task.await(20_000)

  # The request run by a caller that outlives it, as the host listener's
  # connection does, so the request's watcher never stops it for the
  # caller's end.
  defp run_held(fixture, request, emit \\ nil) do
    test = self()
    caller = AttemptFixtures.caller(fixture)

    emit =
      emit ||
        fn frame ->
          send(test, {:frame, request.call_id, frame})
          :ok
        end

    held(fn -> AttachedFetch.run(caller, request, emit, []) end)
  end

  # `fun` run by a caller that runs on until it is sent `:release`: what it
  # answered (or the exception it raised), every process the caller spawned
  # that has not ended within five seconds of the answer, and the caller.
  # Once they have ended, nothing of the request is left in the caller's
  # mailbox.
  defp held(fun) do
    test = self()

    holder =
      spawn_link(fn ->
        result =
          try do
            fun.()
          rescue
            exception -> {:raised, exception.__struct__}
          end

        me = self()
        spawned = for pid <- Process.list(), Process.info(pid, :parent) == {:parent, me}, do: pid
        running = Enum.reject(spawned, &ended?(&1, 5_000))
        {:messages, left} = Process.info(self(), :messages)
        send(test, {:held, result, running, left})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:held, result, running, left}, 20_000
    assert left == [], "the request left #{inspect(left)} in its caller's mailbox"
    {result, running, holder}
  end

  # A TLS upstream on loopback under a test authority no trust store holds,
  # its certificate naming `host`: it pauses its handshake at the client's
  # hello to tell the test the name and protocols the client offered, then
  # tells it how the handshake ended.
  defp tls_upstream!(host) do
    test = self()
    ref = make_ref()
    key = [key: {:namedCurve, :secp256r1}, digest: :sha256]
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(host)}]}

    tls =
      :public_key.pkix_test_data(%{
        server_chain: %{root: key, intermediates: [], peer: key ++ [extensions: [san]]},
        client_chain: %{root: key, intermediates: [], peer: key}
      })

    spawn_link(fn ->
      {:ok, listen} =
        :ssl.listen(
          0,
          tls[:server_config] ++
            [ip: {127, 0, 0, 1}, active: false, mode: :binary, reuseaddr: true, handshake: :hello]
        )

      {:ok, {_address, port}} = :ssl.sockname(listen)
      send(test, {ref, :port, port})
      {:ok, socket} = :ssl.transport_accept(listen, :infinity)
      {:ok, socket, hello} = :ssl.handshake(socket, 5_000)
      send(test, {ref, :hello, Map.take(hello, [:sni, :alpn])})
      send(test, {ref, :handshake, :ssl.handshake_continue(socket, [], 5_000)})
      :ssl.close(listen)
    end)

    assert_receive {^ref, :port, port}, 5_000
    {ref, port, tls[:client_config][:cacerts]}
  end

  # The default trust store (`:public_key.cacerts_get/0`, which Mint reads
  # when no CA option is passed) made to hold `ders` for this test, and
  # restored when it ends; the path's own options are untouched.
  defp trust!(ders) do
    path = Path.join(System.tmp_dir!(), "attached-ca-#{System.unique_integer([:positive])}.pem")
    pem = :public_key.pem_encode(for der <- ders, do: {:Certificate, der, :not_encrypted})
    File.write!(path, pem)
    on_exit(fn -> :public_key.cacerts_clear() end)
    :ok = :public_key.cacerts_load(path)
    File.rm!(path)
  end

  # The scenario for an `https` upstream named `upstream.test`.
  defp https_scenario!(ctx, port, opts \\ []) do
    scenario!(
      ctx,
      port,
      [
        egress: egress(%{"schemes" => ["https"]}),
        destination: %{
          "hosts" => ["upstream.test"],
          "scheme" => "https",
          "port" => port,
          "methods" => ["GET"]
        }
      ] ++ opts
    )
  end

  # An emit that hands each frame to the test and raises on the first frame
  # of the kind `byte` names (`?h` a head, `?e` an end), as a runner's
  # connection breaking there would.
  defp breaking_on(byte, request) do
    test = self()

    fn <<_length::32, kind, _sealed::binary>> = frame ->
      if kind == byte and not Process.get(:broke, false) do
        Process.put(:broke, true)
        raise "the runner's connection broke"
      else
        send(test, {:frame, request.call_id, frame})
        :ok
      end
    end
  end

  # An upstream answering its first connection with `answer`, byte for
  # byte, then telling the test what reading that connection finds: the
  # client closing it, or nothing within five seconds. It waits for its
  # connection as long as the test runs, since it ends with the test.
  defp one_shot!(answer) do
    test = self()
    ref = make_ref()

    spawn_link(fn ->
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      send(test, {ref, :port, port})
      {:ok, socket} = :gen_tcp.accept(listen, :infinity)
      _head = request_head(socket, "")
      :ok = :gen_tcp.send(socket, answer)
      send(test, {ref, :socket, :gen_tcp.recv(socket, 0, 5_000)})
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end)

    assert_receive {^ref, :port, port}, 5_000
    {ref, port}
  end

  defp request_head(socket, read) do
    if String.contains?(read, "\r\n\r\n") do
      read
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      request_head(socket, read <> data)
    end
  end

  defp ended?(pid, timeout) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> true
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        false
    end
  end

  defp assert_name_dropped(ctx, raw, path, form, secret \\ "sk-Attached-MIXED-Canary-42") do
    {read, _sent} = raw_fetch(ctx, raw, path, secret: secret)

    assert [%{kind: :head, headers: headers} | _] = read
    assert {"x-kept", "kept"} in headers
    refute Enum.any?(headers, fn {name, _value} -> name =~ String.downcase(form) end)
    assert body_of(read) == "ok"
  end

  # A request to the raw upstream: the frames the guest reads and the
  # headers the upstream was sent.
  defp raw_fetch(ctx, raw, path, opts \\ []) do
    %{fixture: fixture} = scenario!(ctx, raw, Keyword.take(opts, [:secret]))
    request = request("http://127.0.0.1:#{raw}#{path}", Keyword.take(opts, [:headers]))

    assert :ok = fetched(fixture, request)
    assert_receive {:raw_request, _target, sent}, 5_000
    {frames(fixture, request.call_id), sent}
  end

  # The frames written for `call_id`, read in order under the attempt's
  # seal key until the stream ends.
  defp frames(fixture, call_id),
    do: collect(WorkerAuth.frame_reader(fixture.keys.seal, call_id), call_id, [])

  defp collect(%{state: :done}, _call_id, read), do: read

  defp collect(reader, call_id, read) do
    receive do
      {:frame, ^call_id, bytes} ->
        {:ok, frames, "", reader} = WorkerAuth.read_frames(reader, bytes)
        collect(reader, call_id, read ++ frames)
    after
      15_000 ->
        flunk("the stream of #{call_id} did not end: #{inspect(Enum.map(read, & &1.kind))}")
    end
  end

  defp body_of(frames), do: for(%{kind: :chunk, body: body} <- frames, into: "", do: body)

  defp received_upstream do
    receive do
      {:upstream, _pid, request} -> request
    after
      5_000 -> flunk("the upstream received nothing")
    end
  end

  defp header(request, name),
    do: for({^name, value} <- request.headers, do: value)

  defp denials(fixture) do
    {:ok, rows} = Arca.PolicyLog.list(athanor_id: fixture.athanor_id, limit: 100)
    Enum.filter(rows, &(&1.component_ref == fixture.component_ref))
  end

  # The pins the attempt was answered, as the node's pin table keeps them.
  defp pins(fixture),
    do: :ets.match_object(Crucible.Host.Egress, {{fixture.attempt, :_}, :_, :_})

  # Whether the node's `http:` rate still has room for one request: the
  # take answers it.
  defp rate_left?(scenario) do
    Crucible.Attempt.call(
      scenario.fixture.execution_id,
      AttemptFixtures.caller(scenario.fixture),
      {:take_rate, "http:" <> scenario.component_ref}
    ) == :ok
  end

  # The root a `once` binding of the scenario's consent was consumed by.
  defp consumed_by(scenario) do
    Arca.Repo.one!(
      from(r in Arca.Schemas.ConsentVaultRef,
        where: r.consent_id == ^scenario.authority.consent_id,
        select: r.consumed_by_root
      )
    )
  end

  defp refused!(answer, type) do
    assert {:error, {:guest_error, ^type, message}} = answer
    message
  end

  # ---------------------------------------------------------------------------
  # Admitted
  # ---------------------------------------------------------------------------

  describe "an admitted request" do
    test "reaches the upstream with the credential attached and answers sealed frames", %{
      ctx: ctx,
      port: port
    } do
      test = self()
      handler = "attached-fetch-audit-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:cyfr, :opus, :secret, :dispensed],
        fn _event, _measurements, metadata, _config -> send(test, {:dispensed, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://127.0.0.1:#{port}/hello?q=1", method: "POST", body: "ping")

      assert :ok = fetched(fixture, request)

      upstream = received_upstream()
      assert upstream.method == "POST" and upstream.path == "/hello" and upstream.query == "q=1"
      assert upstream.body == "ping"
      assert header(upstream, "x-api-key") == [@secret]
      assert header(upstream, "accept-encoding") == ["identity"]

      read = frames(fixture, request.call_id)
      assert [%{kind: :head, status: 200}, %{kind: :chunk} | _] = read
      assert List.last(read).kind == :end
      assert body_of(read) == "hello from upstream"

      # The audit names the field, the connection and the destination,
      # never the value.
      assert_received {:dispensed, audit}
      assert audit.field == "KEY" and audit.connection == "api_key"
      assert audit.destination == "http://127.0.0.1:#{port}"
      assert audit.execution_id == fixture.execution_id and audit.runner == fixture.runner
      refute inspect(audit) =~ @secret

      # The value joined the attempt's masking set: a failure message
      # carrying it is masked.
      assert %{"ok" => message} =
               AttemptFixtures.call(fixture, "fail", %{
                 "outcome" =>
                   AttemptFixtures.outcome(fixture, "failed", %{"error" => "saw #{@secret}"})
               })

      refute message =~ @secret
      assert message =~ "[REDACTED]"
    end

    test "asks the upstream to close its connection after the answer", %{ctx: ctx, port: port} do
      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://127.0.0.1:#{port}/plain")

      assert :ok = fetched(fixture, request)
      assert {:upstream, _pid, %{headers: headers}} = receive_upstream()
      assert {"connection", "close"} in headers
      assert [%{kind: :head} | _] = frames(fixture, request.call_id)
    end

    test "an upstream echoing the credential is masked in the head and across a chunk boundary",
         %{ctx: ctx, port: port} do
      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://127.0.0.1:#{port}/echo")
      task = fetch(fixture, request)

      assert {:upstream, upstream, _request} = receive_upstream()
      reader = WorkerAuth.frame_reader(fixture.keys.seal, request.call_id)

      # The head, then the first piece of body: the half of the credential
      # it ends with is held back.
      {first, reader} = next_frames(reader, request.call_id, 2)
      assert [%{kind: :head, headers: headers}, %{kind: :chunk, body: "key: "}] = first
      assert {"x-echo", "[REDACTED]"} in headers

      send(upstream, :continue)
      rest = collect(reader, request.call_id, [])
      assert :ok = Task.await(task, 20_000)

      frames = first ++ rest
      assert body_of(frames) == "key: [REDACTED] tail"
      assert List.last(frames).kind == :end
      half = binary_part(@secret, 0, div(byte_size(@secret), 2))
      refute Enum.any?(frames, &(inspect(&1) =~ half))
    end

    test "a query rule attaches its member and refuses a URL already naming it", %{
      ctx: ctx,
      port: port
    } do
      rule = %{"in" => "query", "name" => "key", "template" => "{value}"}
      %{fixture: fixture} = scenario!(ctx, port, rule: rule)

      request = request("http://127.0.0.1:#{port}/q?a=b")
      assert :ok = fetched(fixture, request)
      assert received_upstream().query == "a=b&key=#{@secret}"
      assert List.last(frames(fixture, request.call_id)).kind == :end

      message =
        fixture
        |> fetched(request("http://127.0.0.1:#{port}/q?key=mine"))
        |> refused!("invalid_request")

      assert message =~ "key"
      refute_received {:upstream, _, _}
    end

    test "connects to the pinned address, whatever the resolver answers after the pin", %{
      ctx: ctx,
      port: port
    } do
      start_supervised!({Resolver, %{"upstream.test" => [{127, 0, 0, 1}, {10, 255, 255, 1}]}})
      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://upstream.test:#{port}/pinned")

      assert :ok = fetched(fixture, request, resolver: Resolver)

      upstream = received_upstream()
      assert upstream.path == "/pinned"
      assert header(upstream, "host") == ["upstream.test:#{port}"]
      assert List.last(frames(fixture, request.call_id)).kind == :end

      # Resolved once, at the pin: the address the resolver would answer
      # now was never asked for.
      assert Resolver.looked_up() == [{"upstream.test", :inet}]
    end

    test "a redirect is answered as a head and an end, and never followed", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://127.0.0.1:#{port}/redirect")

      assert :ok = fetched(fixture, request)
      assert received_upstream().path == "/redirect"

      assert [%{kind: :head, status: 302, headers: headers}, %{kind: :end}] =
               frames(fixture, request.call_id)

      assert {"location", "/elsewhere"} in headers
      refute_receive {:upstream, _, %{path: "/elsewhere"}}, 200
    end
  end

  # ---------------------------------------------------------------------------
  # An answer only as the upstream wrote it
  # ---------------------------------------------------------------------------

  describe "an answer the masker reads as written" do
    test "a guest asking for an encoding gets an identity answer, its echo masked", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port)

      request =
        request("http://127.0.0.1:#{port}/reflect", headers: [{"Accept-Encoding", "gzip, br"}])

      assert :ok = fetched(fixture, request)

      # The guest's encodings were overridden: the upstream was asked for
      # identity alone.
      upstream = received_upstream()
      assert header(upstream, "accept-encoding") == ["identity"]

      read = frames(fixture, request.call_id)
      assert [%{kind: :head, status: 200, headers: headers} | _] = read
      refute List.keymember?(headers, "content-encoding", 0)
      assert body_of(read) == "invalid key: [REDACTED]"
      assert List.last(read).kind == :end
    end

    test "an answer in any content encoding but identity ends in an error, with no body", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port)

      for encoding <- ["gzip", "br", "x-unheard-of"] do
        request = request("http://127.0.0.1:#{port}/encoded?as=#{encoding}")
        assert :ok = fetched(fixture, request)
        assert received_upstream().path == "/encoded"

        assert [%{kind: :error, type: "http_error", message: message}] =
                 frames(fixture, request.call_id),
               encoding

        assert message =~ "encoded"
      end
    end

    test "a header named by the credential is dropped, in lower and in mixed case", %{
      ctx: ctx,
      port: port
    } do
      for secret <- [@secret, "sk-Attached-MIXED-Canary-42"] do
        %{fixture: fixture} = scenario!(ctx, port, secret: secret)
        request = request("http://127.0.0.1:#{port}/name")

        assert :ok = fetched(fixture, request)
        assert received_upstream().path == "/name"

        read = frames(fixture, request.call_id)
        assert [%{kind: :head, headers: headers} | _] = read
        assert {"x-kept", "kept"} in headers

        refute Enum.any?(headers, fn {name, _value} ->
                 String.downcase(name) =~ String.downcase(secret)
               end),
               secret

        assert body_of(read) == "ok"
      end
    end

    test "the rule's own header reflected back is dropped, whatever its value", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://127.0.0.1:#{port}/rule")

      assert :ok = fetched(fixture, request)
      assert received_upstream().path == "/rule"

      assert [%{kind: :head, headers: headers} | _] = frames(fixture, request.call_id)
      assert {"x-kept", "kept"} in headers
      refute List.keymember?(headers, "x-api-key", 0)
    end
  end

  describe "an answer decided on every line of its head" do
    setup do
      parent = self()
      start_supervised!({Task, fn -> RawUpstream.run(parent) end})
      assert_receive {:raw_port, raw}, 5_000
      {:ok, raw: raw}
    end

    test "repeated content-encoding lines and a transfer coding end in an error, no body", %{
      ctx: ctx,
      raw: raw
    } do
      for path <- ["/ce-twice", "/te-gzip-chunked", "/te-gzip"] do
        {read, _sent} = raw_fetch(ctx, raw, path)

        assert [%{kind: :error, type: "http_error", message: message}] = read, path
        assert message =~ "encoded"
      end
    end

    test "a guest's range is not sent, and a part nobody asked for ends in an error", %{
      ctx: ctx,
      raw: raw
    } do
      {read, sent} =
        raw_fetch(ctx, raw, "/partial",
          headers: [
            {"Range", "bytes=0-9"},
            {"If-Range", "\"v1\""},
            {"Request-Range", "bytes=0-9"},
            {"Accept-Encoding", "gzip"}
          ]
        )

      refute List.keymember?(sent, "range", 0)
      refute List.keymember?(sent, "if-range", 0)
      refute List.keymember?(sent, "request-range", 0)
      assert List.keyfind(sent, "accept-encoding", 0) == {"accept-encoding", "identity"}
      assert [%{kind: :error, type: "http_error", message: message}] = read
      assert message =~ "partial"
    end

    test "a content-range on any status ends in an error, with no body", %{ctx: ctx, raw: raw} do
      {read, _sent} = raw_fetch(ctx, raw, "/content-range")
      assert [%{kind: :error, type: "http_error", message: message}] = read
      assert message =~ "partial"
    end

    test "a 206 whose ranges sit only in its body parts ends in an error, with no body", %{
      ctx: ctx,
      raw: raw
    } do
      {read, _sent} = raw_fetch(ctx, raw, "/multipart-206")
      assert [%{kind: :error, type: "http_error", message: message}] = read
      assert message =~ "partial"
    end

    # Twenty-seven characters: its base64 has no padding and every
    # character is a header name's.
    @mixed "sk-Attached-MIXED-Canary-42"

    test "a header named by the credential's base64 is dropped, its case lost in transit", %{
      ctx: ctx,
      raw: raw
    } do
      assert_name_dropped(ctx, raw, "/b64-name", Base.url_encode64(@mixed))
    end

    test "a header named by the credential's hex is dropped", %{ctx: ctx, raw: raw} do
      assert_name_dropped(ctx, raw, "/hex-name", Base.encode16(@mixed, case: :lower))
    end

    test "a header named by the credential's unpadded base64 is dropped", %{ctx: ctx, raw: raw} do
      # Twenty-nine characters: every padded base64 form ends in "=".
      secret = "sk-Attached-MIXED-Canary-4200"

      assert_name_dropped(
        ctx,
        raw,
        "/b64-unpadded-name",
        Base.url_encode64(secret, padding: false),
        secret
      )
    end

    test "an answer switching protocols ends in an error, no head and no body", %{
      ctx: ctx,
      raw: raw
    } do
      for path <- ["/switching-gzip", "/switching-range"] do
        {read, _sent} = raw_fetch(ctx, raw, path)
        assert [%{kind: :error, type: "http_error"}] = read, path
      end
    end

    test "a 101 is refused at its status, as switching protocols", %{ctx: ctx, raw: raw} do
      for path <- ["/switching-gzip", "/switching-range"] do
        {read, _sent} = raw_fetch(ctx, raw, path)
        assert [%{kind: :error, message: message}] = read, path
        assert message =~ "an answer switching protocols is not relayed", path
      end
    end

    test "an informational answer and a trailer are never relayed", %{ctx: ctx, raw: raw} do
      for path <- ["/early", "/trailer"] do
        {read, _sent} = raw_fetch(ctx, raw, path)

        assert [%{kind: :head, status: 200, headers: headers} | _] = read
        refute List.keymember?(headers, "x-early", 0), path
        refute inspect(read) =~ @secret, path
        assert body_of(read) == "plain"
        assert List.last(read).kind == :end
      end
    end

    test "a trailer section after an empty chunked body is never relayed", %{
      ctx: ctx,
      raw: raw
    } do
      {read, _sent} = raw_fetch(ctx, raw, "/trailer-empty")

      assert [%{kind: :head, status: 200, headers: headers} | _] = read
      refute List.keymember?(headers, "x-trailer", 0)
      refute List.keymember?(headers, "x-key", 0)
      refute inspect(read) =~ "visible-trailer"
      refute inspect(read) =~ @secret
      assert body_of(read) == ""
      assert List.last(read).kind == :end
    end
  end

  # ---------------------------------------------------------------------------
  # Refused before admission
  # ---------------------------------------------------------------------------

  describe "a request refused before admission" do
    test "a connection the edge does not bind, or a header the rule owns, reaches nothing", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port)
      url = "http://127.0.0.1:#{port}/x"

      fixture
      |> fetched(request(url, connection: "other"))
      |> refused!("connection_not_granted")

      fixture
      |> fetched(request(url, headers: [{"X-API-KEY", "mine"}]))
      |> refused!("credential_header_refused")

      refute_received {:upstream, _, _}
      refute_received {:frame, _, _}
      assert length(denials(fixture)) == 2
    end

    test "a URL outside the entry's destination is refused, by port, scheme or method", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port)

      for {url, method} <- [
            {"http://127.0.0.1:#{port + 1}/x", "GET"},
            {"https://127.0.0.1:#{port}/x", "GET"},
            {"http://127.0.0.1:#{port}/x", "DELETE"}
          ] do
        fixture
        |> fetched(request(url, method: method))
        |> refused!("destination_mismatch")
      end

      refute_received {:upstream, _, _}
    end

    test "a URL inside the destination but outside the grant's egress is the egress denial", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port, egress: egress(%{"domains" => ["127.0.0.1"]}))

      message =
        fixture
        |> fetched(request("http://upstream.test:#{port}/x"))
        |> refused!("domain_blocked")

      assert message == "HTTP egress refused: upstream.test is not in the egress domains"
      refute_received {:upstream, _, _}

      assert [denial] = denials(fixture)
      assert denial.event_type == "domain_blocked"
      assert denial.decision_reason == "attached: " <> message
    end

    test "a method outside the grant's egress is refused and recorded, before pin or rate", %{
      ctx: ctx,
      port: port
    } do
      scenario =
        scenario!(ctx, port,
          egress: egress(%{"methods" => ["GET"]}),
          limits: %{rate_limit: %{requests: 1, window: "1m"}}
        )

      message =
        scenario.fixture
        |> fetched(request("http://127.0.0.1:#{port}/x", method: "POST"))
        |> refused!("method_blocked")

      assert message == "HTTP egress refused: the method POST is not in the egress methods"
      assert [denial] = denials(scenario.fixture)
      assert denial.event_type == "method_blocked"
      assert denial.decision_reason == "attached: " <> message
      assert pins(scenario.fixture) == []
      assert rate_left?(scenario)
      refute_received {:upstream, _, _}
    end

    test "a scheme outside the grant's egress is refused and recorded, before pin or rate", %{
      ctx: ctx,
      port: port
    } do
      scenario =
        scenario!(ctx, port,
          egress: egress(%{"schemes" => ["https"]}),
          limits: %{rate_limit: %{requests: 1, window: "1m"}}
        )

      message =
        scenario.fixture
        |> fetched(request("http://127.0.0.1:#{port}/x"))
        |> refused!("scheme_blocked")

      assert message == "HTTP egress refused: the scheme http is not in the egress schemes"
      assert [denial] = denials(scenario.fixture)
      assert denial.event_type == "scheme_blocked"
      assert denial.decision_reason == "attached: " <> message
      assert pins(scenario.fixture) == []
      assert rate_left?(scenario)
      refute_received {:upstream, _, _}
    end

    test "a node not at its trusted digest is refused before the vault is asked", %{
      ctx: ctx,
      port: port
    } do
      scenario =
        scenario!(ctx, port,
          lifetime: %{kind: "once"},
          limits: %{rate_limit: %{requests: 1, window: "1m"}}
        )

      # The activation graph the run was admitted under pins another digest
      # for the node than the release the registry answers.
      authority = %{
        scenario.authority
        | activation: Map.put(scenario.authority.activation, scenario.ref, "sha256:not-it")
      }

      fixture = attempt!(ctx, authority, scenario.component_ref, scenario.limits, [])

      fixture
      |> fetched(request("http://127.0.0.1:#{port}/x"))
      |> refused!("connection_not_granted")

      assert consumed_by(scenario) == nil
      assert pins(fixture) == []
      assert rate_left?(%{scenario | fixture: fixture})
      refute_received {:upstream, _, _}
    end

    test "a destination mismatch consumes no once, charges no rate and makes no pin", %{
      ctx: ctx,
      port: port
    } do
      scenario =
        scenario!(ctx, port,
          lifetime: %{kind: "once"},
          limits: %{rate_limit: %{requests: 1, window: "1m"}}
        )

      scenario.fixture
      |> fetched(request("http://127.0.0.1:#{port + 1}/x"))
      |> refused!("destination_mismatch")

      assert consumed_by(scenario) == nil
      assert pins(scenario.fixture) == []
      assert rate_left?(scenario)
      refute_received {:upstream, _, _}
    end

    test "the vector's egress refusal is the one the host answers", %{ctx: ctx, port: port} do
      [vector] = Enum.filter(@vectors["calls"], &(&1["callback"] == "attached_fetch"))
      %{"args" => args} = Jason.decode!(vector["body"])
      [listed] = Enum.filter(vector["refusals"], &(&1["answer"] =~ "domain_blocked"))

      # The vector's request goes to an https destination the entry names,
      # under a grant whose domains leave its host out.
      %{fixture: fixture} =
        scenario!(ctx, port,
          egress: egress(%{"schemes" => ["https"], "methods" => ["POST"]}),
          destination: %{"hosts" => ["api.example.com"], "scheme" => "https"}
        )

      body = :attached_fetch |> WorkerWire.request_body(args) |> Jason.encode!()

      answer =
        fixture
        |> AttemptFixtures.header(body)
        |> Crucible.Host.call(body, fn _frame -> flunk("a refusal emits no frame") end)
        |> Jason.decode!()

      assert answer == Jason.decode!(listed["answer"])
    end

    test "a private upstream under a grant without private_ips is refused before connecting", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port, egress: egress(%{"private_ips" => []}))

      fixture
      |> fetched(request("http://127.0.0.1:#{port}/x"))
      |> refused!("private_ip_blocked")

      refute_received {:upstream, _, _}
      assert [denial] = denials(fixture)
      assert denial.decision_reason =~ "attached: "
    end

    test "a request past the node's request size is refused", %{ctx: ctx, port: port} do
      %{fixture: fixture} = scenario!(ctx, port, limits: %{max_request_size: 64})

      fixture
      |> fetched(
        request("http://127.0.0.1:#{port}/x", method: "POST", body: String.duplicate("b", 100))
      )
      |> refused!("request_too_large")

      refute_received {:upstream, _, _}
    end

    test "the rate is taken once per attached request, on the control plane", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} =
        scenario!(ctx, port, limits: %{rate_limit: %{requests: 1, window: "1m"}})

      first = request("http://127.0.0.1:#{port}/one")
      assert :ok = fetched(fixture, first)
      assert List.last(frames(fixture, first.call_id)).kind == :end
      assert received_upstream().path == "/one"

      fixture
      |> fetched(request("http://127.0.0.1:#{port}/two"))
      |> refused!("rate_limited")

      refute_received {:upstream, _, _}
    end
  end

  # ---------------------------------------------------------------------------
  # Lifetimes
  # ---------------------------------------------------------------------------

  describe "a binding's lifetime" do
    test "a once binding admits its root again and refuses another root", %{
      ctx: ctx,
      port: port
    } do
      scenario = scenario!(ctx, port, lifetime: %{kind: "once"})
      %{fixture: fixture} = scenario

      for path <- ["/first", "/again"] do
        request = request("http://127.0.0.1:#{port}#{path}")
        assert :ok = fetched(fixture, request)
        assert List.last(frames(fixture, request.call_id)).kind == :end
        assert received_upstream().path == path
      end

      ctx
      |> another_root!(scenario)
      |> fetched(request("http://127.0.0.1:#{port}/other-root"))
      |> refused!("grant_expired")

      refute_received {:upstream, _, _}
    end

    test "an until binding is refused once its instant passes", %{ctx: ctx, port: port} do
      until = DateTime.utc_now() |> DateTime.add(4, :second) |> DateTime.truncate(:second)

      %{fixture: fixture} =
        scenario!(ctx, port, lifetime: %{kind: "until", until: DateTime.to_iso8601(until)})

      request = request("http://127.0.0.1:#{port}/before")
      assert :ok = fetched(fixture, request)
      assert List.last(frames(fixture, request.call_id)).kind == :end
      assert received_upstream().path == "/before"

      wait_until(
        fn -> DateTime.compare(DateTime.utc_now(), until) == :gt end,
        8_000,
        "the binding's instant to pass"
      )

      fixture
      |> fetched(request("http://127.0.0.1:#{port}/after"))
      |> refused!("grant_expired")

      refute_received {:upstream, _, _}
    end
  end

  # ---------------------------------------------------------------------------
  # Ending a stream
  # ---------------------------------------------------------------------------

  describe "a stream that ends early" do
    test "a body past the node's response size ends with an error frame", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port, limits: %{max_response_size: 64})
      request = request("http://127.0.0.1:#{port}/big")

      assert :ok = fetched(fixture, request)
      frames = frames(fixture, request.call_id)
      assert %{kind: :error, type: "response_too_large"} = List.last(frames)
      assert body_of(frames) == ""
    end

    test "the attempt's deadline ends it with an error and closes the upstream connection", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port, timeout_ms: 1_500)
      request = request("http://127.0.0.1:#{port}/slow")

      assert :ok = fetched(fixture, request)
      frames = frames(fixture, request.call_id)
      assert %{kind: :error, type: "timeout"} = List.last(frames)
      assert_receive {:upstream_closed, _pid}, 10_000
    end

    test "a refused answer stops its request: the process ends and the connection closes", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port)

      for as <- ["encoded", "partial", "ranged"] do
        request = request("http://127.0.0.1:#{port}/held?as=#{as}")
        {result, running, holder} = run_held(fixture, request)
        assert_receive {:upstream, upstream, %{path: "/held"}}, 5_000

        assert :ok = result
        assert [%{kind: :error, type: "http_error"}] = frames(fixture, request.call_id), as
        assert running == [], "#{as}: the request's process is still running"

        # The caller still runs, so only the refusal can have closed it.
        assert_receive {:upstream_closed, ^upstream}, 5_000
        send(holder, :release)
      end
    end

    test "an answer whose status is no HTTP status ends in one error frame, its request stopped",
         %{ctx: ctx} do
      {ref, port} = one_shot!("HTTP/1.1 999 Canary\r\ncontent-length: 100\r\n\r\nx")
      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://127.0.0.1:#{port}/")
      test = self()
      body = AttemptFixtures.body("attached_fetch", AttachedRequest.to_args(request))
      header = AttemptFixtures.header(fixture, body)

      emit = fn frame ->
        send(test, {:frame, request.call_id, frame})
        :ok
      end

      {answer, running, holder} = held(fn -> Crucible.Host.call(header, body, emit) end)

      refute answer =~ "lost"

      assert [%{kind: :error, type: "http_error", message: message}] =
               frames(fixture, request.call_id)

      assert message =~ "no valid status"
      assert running == []
      assert_receive {^ref, :socket, {:error, :closed}}, 5_000
      send(holder, :release)
    end

    test "a refused answer complete in its head closes its connection, never pooled", %{ctx: ctx} do
      for {as, answer} <- [
            encoded: "HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: 0\r\n\r\n",
            partial: "HTTP/1.1 206 Partial Content\r\ncontent-length: 0\r\n\r\n",
            ranged: "HTTP/1.1 200 OK\r\ncontent-range: bytes 0-0/1\r\ncontent-length: 0\r\n\r\n"
          ] do
        {ref, port} = one_shot!(answer)
        %{fixture: fixture} = scenario!(ctx, port)
        request = request("http://127.0.0.1:#{port}/")
        {result, running, holder} = run_held(fixture, request)

        assert :ok = result
        assert [%{kind: :error, type: "http_error"}] = frames(fixture, request.call_id), "#{as}"
        assert running == []

        # The caller still runs, so only the refusal can have closed it.
        assert_receive {^ref, :socket, {:error, :closed}},
                       5_000,
                       "#{as}: the connection stays open"

        send(holder, :release)
      end
    end

    test "an exception while relaying ends in one error frame after the last one written", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port)

      # The runner's connection breaks on the head, or on the first chunk
      # after it, and takes every frame after the break.
      for {breaks_at, written} <- [{1, []}, {2, [:head]}] do
        request = request("http://127.0.0.1:#{port}/slow")
        test = self()

        emit = fn frame ->
          count = Process.get(:frames, 0) + 1
          Process.put(:frames, count)

          if count == breaks_at do
            raise "the runner's connection broke"
          else
            send(test, {:frame, request.call_id, frame})
            :ok
          end
        end

        {result, running, holder} = run_held(fixture, request, emit)
        assert_receive {:upstream, upstream, %{path: "/slow"}}, 5_000

        assert :ok = result
        frames = frames(fixture, request.call_id)
        assert Enum.map(frames, & &1.kind) == written ++ [:error]
        assert %{type: "http_error"} = List.last(frames)
        assert running == []
        assert_receive {:upstream_closed, ^upstream}, 5_000
        send(holder, :release)
      end
    end

    test "an admitted answer's connection closes when it completes, kept by no pool", %{
      ctx: ctx
    } do
      {ref, port} = one_shot!("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://127.0.0.1:#{port}/")
      {result, running, holder} = run_held(fixture, request)

      assert :ok = result
      frames = frames(fixture, request.call_id)
      assert [:head | _] = Enum.map(frames, & &1.kind)
      assert %{kind: :end} = List.last(frames)
      assert body_of(frames) == "ok"
      assert running == []

      # The upstream keeps the connection open; only the request's end can
      # have closed it, and the caller still runs.
      assert_receive {^ref, :socket, {:error, :closed}}, 5_000
      send(holder, :release)
    end

    test "an exception after an admitted answer was read whole still closes its connection", %{
      ctx: ctx
    } do
      for {breaks_on, answer, written} <- [
            {?h, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n", []},
            {?e, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok", [:head, :chunk]}
          ] do
        {ref, port} = one_shot!(answer)
        %{fixture: fixture} = scenario!(ctx, port)
        request = request("http://127.0.0.1:#{port}/")
        {result, running, holder} = run_held(fixture, request, breaking_on(breaks_on, request))

        assert :ok = result
        frames = frames(fixture, request.call_id)
        assert Enum.map(frames, & &1.kind) == written ++ [:error], <<breaks_on>>
        assert running == []
        assert_receive {^ref, :socket, {:error, :closed}}, 5_000, "#{<<breaks_on>>}: still open"
        send(holder, :release)
      end
    end

    test "a runner connection that no longer takes a frame stops the request", %{
      ctx: ctx,
      port: port
    } do
      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://127.0.0.1:#{port}/slow")
      test = self()

      # The head is written, and nothing after it.
      emit = fn frame ->
        case Process.get(:written) do
          nil ->
            Process.put(:written, true)
            send(test, {:frame, request.call_id, frame})
            :ok

          true ->
            {:error, :closed}
        end
      end

      assert :ok = fetched(fixture, request, emit: emit)
      assert_receive {:frame, _, _}
      assert_receive {:upstream_closed, _pid}, 10_000
    end
  end

  # ---------------------------------------------------------------------------
  # Over TLS
  # ---------------------------------------------------------------------------

  describe "an upstream over TLS" do
    test "is named by the pinned host, spoken to in HTTP/1.1, and refused an unverified chain",
         %{ctx: ctx} do
      start_supervised!({Resolver, %{"upstream.test" => [{127, 0, 0, 1}]}})
      {ref, port, _roots} = tls_upstream!("upstream.test")
      %{fixture: fixture} = https_scenario!(ctx, port)

      request = request("https://upstream.test:#{port}/tls")
      assert :ok = fetched(fixture, request, resolver: Resolver)
      assert [%{kind: :error, type: "http_error"}] = frames(fixture, request.call_id)

      # The client connected to the pinned address, named the pinned host
      # for SNI, negotiated no protocol (an HTTP/1.1 client offers none; one
      # that could speak HTTP/2 offers h2), and refused the chain: its
      # authority is in no trust store, and nothing was sent.
      assert_receive {^ref, :hello, %{sni: ~c"upstream.test", alpn: :undefined}}, 5_000
      assert_receive {^ref, :handshake, {:error, {:tls_alert, {:unknown_ca, _sentence}}}}, 5_000
    end

    test "refuses a trusted chain that names another host, before anything is sent", %{ctx: ctx} do
      start_supervised!({Resolver, %{"upstream.test" => [{127, 0, 0, 1}]}})
      {ref, port, roots} = tls_upstream!("other.test")
      trust!(roots)
      %{fixture: fixture} = https_scenario!(ctx, port)
      request = request("https://upstream.test:#{port}/tls")

      assert :ok = fetched(fixture, request, resolver: Resolver)
      assert [%{kind: :error, type: "http_error"}] = frames(fixture, request.call_id)

      # The chain is trusted now; the name it carries is not the pinned
      # host, which the client named for SNI and holds the certificate to.
      assert_receive {^ref, :hello, %{sni: ~c"upstream.test"}}, 5_000
      assert_receive {^ref, :handshake, {:error, {:tls_alert, {:bad_certificate, _}}}}, 5_000
    end

    test "gives up on an upstream that never answers its hello after the connect timeout", %{
      ctx: ctx
    } do
      start_supervised!({Resolver, %{"upstream.test" => [{127, 0, 0, 1}]}})
      test = self()
      ref = make_ref()

      # A listener that takes the connection and the client's hello, and
      # never answers it.
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, port} = :inet.port(listen)
        send(test, {ref, :port, port})
        {:ok, socket} = :gen_tcp.accept(listen, :infinity)
        _hello = :gen_tcp.recv(socket, 0, 60_000)
        send(test, {ref, :after, :gen_tcp.recv(socket, 0, 60_000)})
      end)

      assert_receive {^ref, :port, port}, 5_000
      %{fixture: fixture} = https_scenario!(ctx, port, timeout_ms: 60_000)
      request = request("https://upstream.test:#{port}/never")
      started = System.monotonic_time(:millisecond)

      assert :ok = fixture |> fetch(request, resolver: Resolver) |> Task.await(60_000)
      elapsed = System.monotonic_time(:millisecond) - started

      # Well inside the attempt's deadline: the connect timeout ends it.
      assert [%{kind: :error, type: "timeout"}] = frames(fixture, request.call_id)
      assert elapsed < 15_000, "the request gave up after #{elapsed} ms"
      assert_receive {^ref, :after, {:error, :closed}}, 5_000
    end
  end

  # ---------------------------------------------------------------------------
  # The decision on an answer
  # ---------------------------------------------------------------------------

  describe "the decision on an answer as the client hands it over" do
    @encoded_sentence "HTTP request failed: an encoded answer is not relayed"
    @partial_sentence "HTTP request failed: a partial answer is not relayed"

    test "an informational block is set aside, whatever its lines, and the final head decides" do
      early = [{"content-encoding", "gzip"}, {"content-range", "bytes 0-9/100"}]
      final = [{"content-type", "text/plain"}]

      for status <- [100, 102, 103, 199] do
        assert {:head, 200, ^final} =
                 AttachedFetch.decision([
                   {:status, status},
                   {:headers, early},
                   {:status, 200},
                   {:headers, final},
                   {:data, "body"}
                 ])
      end
    end

    test "a block a client takes as the final head is checked, whatever its status code" do
      for status <- [100, 102, 103, 199],
          {lines, sentence} <- [
            {[{"content-encoding", "gzip"}], @encoded_sentence},
            {[{"transfer-encoding", "gzip, chunked"}], @encoded_sentence},
            {[{"content-range", "bytes 0-9/100"}], @partial_sentence}
          ],
          ending <- [[{:data, "key"}], []] do
        assert {:refused, ^sentence} =
                 AttachedFetch.decision([{:status, status}, {:headers, lines}] ++ ending)
      end
    end

    test "a final head is refused before any body, at any status from 200" do
      for status <- [200, 204, 206, 302, 404, 599] do
        assert {:refused, _sentence} =
                 AttachedFetch.decision([
                   {:status, status},
                   {:headers, [{"content-encoding", "br"}]}
                 ])
      end

      assert {:refused, @partial_sentence} =
               AttachedFetch.decision([{:status, 206}, {:headers, []}])
    end

    test "a 101, and a status outside 100..599, are refused at the status" do
      assert {:refused, "HTTP request failed: an answer switching protocols is not relayed"} =
               AttachedFetch.decision([{:status, 101}, {:headers, []}, {:data, "x"}])

      for status <- [0, 99, 600, 999] do
        assert {:refused, "HTTP request failed: an answer with no valid status is not relayed"} =
                 AttachedFetch.decision([{:status, status}])
      end

      assert {:head, 599, []} = AttachedFetch.decision([{:status, 599}, {:headers, []}])
    end

    test "a trailer section decides nothing" do
      assert {:head, 200, [{"x-kept", "kept"}]} =
               AttachedFetch.decision([
                 {:status, 200},
                 {:headers, [{"x-kept", "kept"}]},
                 {:data, "body"},
                 {:trailers, [{"content-encoding", "gzip"}]},
                 {:headers, [{"content-range", "bytes 0-9/100"}]}
               ])
    end
  end

  # ---------------------------------------------------------------------------
  # Through the listener
  # ---------------------------------------------------------------------------

  describe "through the host listener" do
    setup do
      listener = start_supervised!({HostListener, port: 0})
      {:ok, url: "http://127.0.0.1:#{HostListener.port(listener)}"}
    end

    test "an admitted request is a chunked answer of sealed frames, in order", %{
      ctx: ctx,
      port: port,
      url: url
    } do
      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://127.0.0.1:#{port}/through")

      response = post(url, fixture, request)
      assert response.status == 200

      assert Req.Response.get_header(response, "content-type") == [
               WorkerWire.attached_frames_content_type()
             ]

      reader = WorkerAuth.frame_reader(fixture.keys.seal, request.call_id)
      assert {:ok, frames, "", %{state: :done}} = WorkerAuth.read_frames(reader, response.body)
      assert [%{kind: :head, status: 200} | _] = frames
      assert body_of(frames) == "hello from upstream"
      assert header(received_upstream(), "x-api-key") == [@secret]
    end

    test "a refusal before admission is one sealed answer naming the call id", %{
      ctx: ctx,
      port: port,
      url: url
    } do
      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://127.0.0.1:#{port}/x", connection: "other")

      response = post(url, fixture, request)
      assert response.status == 200

      assert Req.Response.get_header(response, "content-type") == [
               "application/json; charset=utf-8"
             ]

      {:ok, json} =
        WorkerAuth.open_call(fixture.keys.seal, :answer, response.private.fields, response.body)

      assert %{"error" => "guest_error", "type" => "connection_not_granted", "call_id" => id} =
               Jason.decode!(json)

      assert id == request.call_id
      refute_received {:upstream, _, _}
    end

    test "a runner that goes away mid-stream stops the request and closes the upstream", %{
      ctx: ctx,
      port: port,
      url: url
    } do
      %{fixture: fixture} = scenario!(ctx, port)
      request = request("http://127.0.0.1:#{port}/slow")
      {_fields, body, header} = sealed_call(fixture, request)
      %URI{port: listener_port} = URI.parse(url)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", listener_port, [:binary, active: false])

      :ok =
        :gen_tcp.send(socket, [
          "POST #{WorkerWire.host_route(:attached_fetch)} HTTP/1.1\r\n",
          "host: 127.0.0.1\r\n",
          "#{WorkerWire.auth_header()}: #{header}\r\n",
          "content-length: #{byte_size(body)}\r\n",
          "\r\n",
          body
        ])

      # The answer's head and its first frame arrive; then the runner goes.
      {:ok, head} = :gen_tcp.recv(socket, 0, 10_000)
      assert head =~ "200"
      :ok = :gen_tcp.close(socket)

      assert_receive {:upstream_closed, _pid}, 10_000
    end
  end

  # A sealed, signed attached_fetch call of `request` for `fixture`, posted
  # to its route, the raw answer kept beside the fields it was sealed for.
  defp post(url, fixture, request) do
    {fields, body, header} = sealed_call(fixture, request)

    response =
      Req.request!(
        url: url <> WorkerWire.host_route(:attached_fetch),
        method: :post,
        headers: [{WorkerWire.auth_header(), header}],
        body: body,
        retry: false,
        decode_body: false,
        receive_timeout: 20_000
      )

    %{response | private: Map.put(response.private, :fields, fields)}
  end

  defp sealed_call(fixture, request) do
    fields = AttemptFixtures.caller(fixture)
    json = AttemptFixtures.body("attached_fetch", AttachedRequest.to_args(request))
    {:ok, sealed} = WorkerAuth.seal_call(fixture.keys.seal, :body, fields, json)
    {:ok, header} = WorkerAuth.host_call_header(fixture.call_key, fields, sealed)
    {fields, sealed, header}
  end

  defp receive_upstream do
    receive do
      {:upstream, _pid, _request} = received -> received
    after
      5_000 -> flunk("the upstream received nothing")
    end
  end

  # The next `count` frames of `call_id`, and the reader after them.
  defp next_frames(reader, call_id, count) do
    Enum.reduce(1..count, {[], reader}, fn _n, {read, reader} ->
      receive do
        {:frame, ^call_id, bytes} ->
          {:ok, frames, "", reader} = WorkerAuth.read_frames(reader, bytes)
          {read ++ frames, reader}
      after
        10_000 -> flunk("frame #{length(read) + 1} of #{call_id} never came")
      end
    end)
  end
end
