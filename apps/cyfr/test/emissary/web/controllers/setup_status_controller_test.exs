# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.SetupStatusControllerTest do
  @moduledoc """
  `POST /api/setup/status` through the endpoint, one test per exchange of
  `tests/fixtures/setup_status.json`, each held to its status and answer,
  and to writing no row, setting no cookie and carrying the token into no
  log or answer. The command line's client reads the same exchanges
  (`apps/codex/internal/setup/status_test.go`).
  """

  # The setup token is process-wide configuration.
  use CyfrWeb.ConnCase, async: false

  @moduletag :capture_log

  alias Arca.Schemas.User
  alias Sanctum.Newcomer
  alias Sanctum.Test.Newcomers

  @fixture Path.expand("../../../../../../tests/fixtures/setup_status.json", __DIR__)
  @external_resource @fixture
  @vectors @fixture |> File.read!() |> Jason.decode!()
  @path @vectors["path"]

  @token String.duplicate("5e", 32)
  @other String.duplicate("a7", 32)

  setup do
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Newcomers.directory!()
    Arca.Repo.delete_all(User)
    :ok
  end

  # ---- the installation an exchange meets ------------------------------------

  defp hold("empty"), do: :ok
  defp hold("person"), do: person()
  defp hold("set_up"), do: person() |> first_method()

  defp hold("restore_pending") do
    {:ok, _attempt} =
      Arca.IdentityAttempts.open(Prima.Actor.system(), %{
        kind: "restore",
        request_id: "req_#{System.unique_integer([:positive])}",
        identifier: "per_" <> Prima.Digest.sha256_hex("genesis"),
        directory_url: "https://dir.example",
        entry: "recover-request",
        request_digest: Prima.Digest.sha256("recover"),
        expected_revision: 0,
        token_digest: Prima.Digest.sha256("token"),
        staged_live_public_key: :crypto.strong_rand_bytes(32),
        staged_operational_public_key: :crypto.strong_rand_bytes(32),
        staged_live_key_sealed: "sealed-live",
        staged_operational_key_sealed: "sealed-op"
      })

    :ok
  end

  defp hold("unreachable"),
    do: Arca.Repo.query!("ALTER TABLE installation_claims RENAME TO installation_claims_away")

  defp person do
    {:ok, %{person: person}} =
      Newcomer.admit({:setup, @token}, {:command_line, "laptop", Newcomers.identity()})

    person.id
  end

  defp first_method(person_id) do
    {:ok, :marked} =
      Arca.Repo.transaction(fn -> Arca.PersonIdentities.first_method!(person_id) end)

    :ok
  end

  # Every row of every table, so a read that writes anywhere shows.
  defp rows do
    sql =
      if Arca.repo_adapter() == Ecto.Adapters.Postgres,
        do: "SELECT tablename FROM pg_tables WHERE schemaname = current_schema()",
        else: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"

    for [table] <- Arca.Repo.query!(sql).rows, into: %{} do
      {table, Arca.Repo.query!(~s(SELECT * FROM "#{table}")).rows |> Enum.sort()}
    end
  end

  # ---- the request an exchange makes -----------------------------------------

  defp listener(conn, "none"), do: conn
  defp listener(conn, "proxy"), do: Sanctum.ClientIp.put_ingress(conn, :proxy)
  defp listener(conn, _loopback), do: Sanctum.ClientIp.put_ingress(conn, :loopback)

  defp bearer(conn, "setup"), do: put_req_header(conn, "authorization", "Bearer " <> @token)
  defp bearer(conn, "other"), do: put_req_header(conn, "authorization", "Bearer " <> @other)
  defp bearer(conn, "basic"), do: put_req_header(conn, "authorization", "Basic " <> @token)
  defp bearer(conn, "none"), do: conn

  defp bearer(conn, "unconfigured") do
    Application.delete_env(:sanctum, :setup_token)
    bearer(conn, "setup")
  end

  defp body(%{"padded_to" => bytes}) do
    open = ~s({"version":1)
    open <> String.duplicate(" ", bytes - byte_size(open) - 1) <> "}"
  end

  defp body(exchange), do: exchange["body"] || @vectors["request"]

  defp request(exchange) do
    conn =
      build_conn()
      |> listener(exchange["listener"])
      |> bearer(exchange["token"])
      |> put_req_header("content-type", exchange["content_type"] || "application/json")

    conn =
      Enum.reduce(exchange["headers"] || %{}, conn, fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    send = fn -> post(conn, exchange["request_path"] || @path, body(exchange)) end

    if exchange["parser"] do
      {status, headers, body} = assert_error_sent(exchange["status"], send)
      %{status: status, headers: headers, body: body}
    else
      answered = send.()
      %{status: answered.status, headers: answered.resp_headers, body: answered.resp_body}
    end
  end

  defp header(response, name), do: for({^name, value} <- response.headers, do: value)

  defp ask(store, token) do
    hold(store)
    request(%{"token" => token})
  end

  defp state(response), do: Jason.decode!(response.body)["state"]

  # ---- the exchanges ---------------------------------------------------------

  for exchange <- @vectors["exchanges"] do
    test "#{exchange["name"]}" do
      exchange = unquote(Macro.escape(exchange))
      hold(exchange["store"])
      before = rows()

      previous = Logger.level()
      on_exit(fn -> Logger.configure(level: previous) end)
      Logger.configure(level: :debug)

      {response, log} =
        ExUnit.CaptureLog.with_log([level: :debug], fn -> request(exchange) end)

      Logger.configure(level: previous)

      assert response.status == exchange["status"]

      # The request's own line: this log is the one the token is kept out
      # of. A refusal of the front comes before the endpoint's log.
      if response.status != 403, do: assert(log =~ (exchange["request_path"] || @path))

      case exchange do
        %{"answer" => answer} -> assert Jason.decode!(response.body) == answer
        %{"refusal" => code} -> assert Jason.decode!(response.body)["code"] == code
        %{"parser" => true} -> :ok
      end

      assert header(response, "cache-control") == ["no-store"]
      assert header(response, "set-cookie") == []
      assert rows() == before

      for text <- [log, response.body, inspect(response.headers)] do
        refute text =~ @token
        refute text =~ @other
      end
    end
  end

  test "the wire's definition is the vectors'" do
    assert Prima.SetupStatus.max_body_bytes() == @vectors["max_body_bytes"]
    assert Prima.SetupStatus.request?(Jason.decode!(@vectors["request"]))

    for state <- [:open, :closed, :unavailable] do
      {status, body} = Prima.SetupStatus.answer(state)

      assert %{"status" => ^status} =
               Enum.find(@vectors["exchanges"], &(get_in(&1, ["answer", "state"]) == "#{state}"))

      assert body == %{version: @vectors["version"], state: "#{state}"}
    end
  end

  # ---- what no one can tell apart ---------------------------------------------

  describe "an invalid token and a spent one" do
    defp seen(response) do
      {response.status, response.body, response.headers |> List.keydelete("x-request-id", 0)}
    end

    test "answer alike, header for header" do
      invalid = ask("empty", "other")
      spent = ask("set_up", "setup")
      invalid_after_setup = request(%{"token" => "other"})

      assert state(spent) == "closed"
      assert seen(invalid) == seen(spent)
      assert seen(invalid_after_setup) == seen(spent)
    end
  end

  # ---- the read beside the admission --------------------------------------------

  describe "a first method landing while the route is read" do
    test "answers open until it commits and closed from then on, and takes nothing from it" do
      person_id = person()
      assert state(request(%{"token" => "setup"})) == "open"

      claim = Task.async(fn -> first_method(person_id) end)
      answers = until_closed(System.monotonic_time(:millisecond) + 5_000, [])
      assert :ok = Task.await(claim)

      assert Enum.dedup(Enum.reverse(answers)) in [["closed"], ["open", "closed"]]
      assert Arca.Repo.aggregate(User, :count) == 1
    end

    # The limiter is reset between reads: this test is of the store, not the
    # bucket, and a loaded host may read many times before the commit.
    defp until_closed(deadline, answers) do
      Prima.Test.RateLimiter.reset!()
      answer = state(request(%{"token" => "setup"}))

      cond do
        answer == "closed" -> [answer | answers]
        System.monotonic_time(:millisecond) > deadline -> flunk("still #{answer} at the deadline")
        true -> until_closed(deadline, [answer | answers])
      end
    end
  end

  # ---- the bucket -----------------------------------------------------------------

  describe "the rate limit" do
    test "answers 429, no-store, past its window's requests, and a proxy request counts for nothing" do
      for _ <- 1..200 do
        assert request(%{"token" => "setup", "listener" => "proxy"}).status == 403
      end

      for _ <- 1..120, do: assert(request(%{"token" => "setup"}).status == 200)

      refused = request(%{"token" => "setup"})
      assert refused.status == 429
      assert Jason.decode!(refused.body)["code"] == "rate_limited"
      assert header(refused, "cache-control") == ["no-store"]
      assert [_seconds] = header(refused, "retry-after")
    end

    test "counts a malformed request as it counts any other" do
      malformed = %{"token" => "setup", "body" => "{", "parser" => true, "status" => 400}

      for _ <- 1..120, do: assert(request(malformed).status == 400)

      assert request(%{"token" => "setup"}).status == 429
    end

    test "counts a request whose path is spelled in escapes as it counts any other" do
      for _ <- 1..120 do
        assert request(%{"token" => "setup", "request_path" => "/api/setup/%73tatus"}).status ==
                 200
      end

      assert request(%{"token" => "setup"}).status == 429
    end
  end

  # ---- the fence every route stands behind ------------------------------------

  describe "a member that lost its slot" do
    test "keeps the fence: 503, no-store, and that refusal alone is recorded" do
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
      before = rows()
      Arca.ControlPlane.record(:lost)

      response = request(%{"token" => "setup"})

      assert response.status == 503
      assert header(response, "cache-control") == ["no-store"]
      assert Jason.decode!(response.body)["state"] == nil

      changed = rows() |> Enum.reject(fn {table, held} -> before[table] == held end)
      assert [{"decision_logs", held}] = changed
      assert length(held) == length(before["decision_logs"]) + 1
    end
  end

  # ---- every other route ----------------------------------------------------------

  describe "the route's front" do
    test "leaves every other request as it came" do
      front = Emissary.Web.Plugs.SetupStatusFront

      for {method, path} <- [
            {:get, @path},
            {:get, "/api/health"},
            {:post, "/api/setup"},
            {:post, "/api/setup/status/more"},
            {:post, "/api/setup/%zz"},
            {:put, @path}
          ] do
        conn =
          Plug.Test.conn(method, path)
          |> Sanctum.ClientIp.put_ingress(:proxy)
          |> put_req_header("origin", "http://localhost")

        untouched = front.call(conn, front.init([]))

        refute untouched.halted, path
        assert untouched.resp_headers == conn.resp_headers, path
      end
    end

    test "answers the route's path as the router decodes it, and no other" do
      for path <- [@path, "/%61pi/setup/status", "/api/%73etup/status", "/api/setup/%73tatus"] do
        assert Prima.SetupStatus.path?(split(path)), path
      end

      for path <- [
            "/api/setup",
            "/api/setup/%zz",
            "/api/setup/status/more",
            "/api/setup%2Fstatus"
          ] do
        refute Prima.SetupStatus.path?(split(path)), path
      end
    end

    defp split(path), do: String.split(path, "/", trim: true)
  end

  # ---- the real listeners, and what their instrumentation records ---------------------

  describe "on the real listeners, under the instrumentation a release attaches" do
    setup do
      known = handlers()

      on_exit(fn ->
        for id <- handlers() -- known, do: :telemetry.detach(id)
      end)

      OpentelemetryBandit.setup()
      OpentelemetryPhoenix.setup(adapter: :bandit)
      Cyfr.OtelTenantHandler.attach()

      on_exit(fn ->
        ExUnit.CaptureLog.capture_log(fn -> :otel_batch_processor.set_exporter(:none) end)
      end)

      :otel_batch_processor.set_exporter(:otel_exporter_pid, self())

      previous = Logger.level()
      on_exit(fn -> Logger.configure(level: previous) end)
      Logger.configure(level: :debug)
      :ok
    end

    defp handlers do
      for event <- [[:phoenix], [:bandit]], %{id: id} <- :telemetry.list_handlers(event), do: id
    end

    defp listening(ingress) do
      server =
        start_supervised!(
          {Bandit,
           plug: {CyfrWeb.Ingress, {ingress, CyfrWeb.Endpoint}},
           port: 0,
           ip: :loopback,
           startup_log: false},
          id: ingress
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      port
    end

    defp posted(port) do
      request =
        "POST #{@path} HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n" <>
          "authorization: Bearer #{@token}\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(@vectors["request"])}\r\n\r\n#{@vectors["request"]}"

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, request)
      read_all(socket, "")
    end

    defp read_all(socket, read) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, more} -> read_all(socket, read <> more)
        {:error, :closed} -> read
      end
    end

    defp spans(found) do
      receive do
        {:span, span} -> spans([span | found])
      after
        0 -> found
      end
    end

    test "the loopback listener opens, the proxy listener refuses, and no span or log holds the token" do
      {{open, refused}, log} =
        ExUnit.CaptureLog.with_log([level: :debug], fn ->
          {posted(listening(:loopback)), posted(listening(:proxy))}
        end)

      assert open =~ ~r{\AHTTP/1\.1 200 }
      assert open =~ ~s("state":"open")
      assert refused =~ ~r{\AHTTP/1\.1 403 }

      :otel_tracer_provider.force_flush()
      Process.sleep(100)
      recorded = spans([])

      assert recorded != [], "no span was recorded, so this holds nothing"
      assert Enum.any?(recorded, &(inspect(&1, limit: :infinity) =~ @path))

      for text <- [log | Enum.map(recorded, &inspect(&1, limit: :infinity))] do
        refute text =~ @token
        refute text =~ "authorization"
      end
    end
  end

  # ---- the instrumentation's own roster -------------------------------------------

  # A release adds the three the real listeners' setup above attaches. A new
  # handler on these events fails here, and belongs in that setup.
  test "nothing but Phoenix's own log lines listens to a request otherwise" do
    owners =
      for prefix <- [[:phoenix], [:bandit]],
          %{id: {owner, _event}} <- :telemetry.list_handlers(prefix),
          uniq: true,
          do: owner

    assert Enum.sort(owners) == [Phoenix.LiveView.Logger, Phoenix.Logger]
  end
end
