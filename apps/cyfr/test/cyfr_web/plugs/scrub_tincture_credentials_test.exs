# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.ScrubTinctureCredentialsTest do
  @moduledoc """
  A private tincture's served files and a canvas's host page carry their
  asset credential in the path, because a navigation, a script or an image
  fetch carries no header. Whatever else is true of that design, the
  credential must not survive into anything that names the request: the
  plug redacts it from `conn.request_path` by shape, while routing and the
  action still read it. The end-to-end check, through the endpoint's and
  the router's telemetry and the log, is the page's own test
  (`Emissary.Web.CanvasControllerTest`).
  """
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias CyfrWeb.Plugs.ScrubTinctureCredentials

  @credential "AbCdEfGhIjKlMnOpQrSt.uvwxyz0123456789_-"

  defp run(path) do
    :get
    |> conn(path)
    |> ScrubTinctureCredentials.call([])
  end

  test "redacts the credential segment, and routing still reads it" do
    conn = run("/_s/#{@credential}/local/game/1.0.0/assets/app.js")

    assert conn.request_path == "/_s/[REDACTED]/local/game/1.0.0/assets/app.js"
    refute conn.request_path =~ @credential
    # Routing matches on `path_info`, which keeps the credential.
    assert conn.path_info == ["_s", @credential, "local", "game", "1.0.0", "assets", "app.js"]
  end

  test "redacts by shape: a credential outside the grammar is redacted as well" do
    for segment <- ["short", "..", "has%20space", String.duplicate("x", 2_000)] do
      conn = run("/_s/#{segment}/index.html")
      assert conn.request_path == "/_s/[REDACTED]/index.html", segment
    end

    assert run("/_s/#{@credential}").request_path == "/_s/[REDACTED]"
  end

  test "a response answered before the action carries the redacted path" do
    sent =
      "/_s/#{@credential}/local/game/1.0.0/index.html"
      |> run()
      |> Map.put(:request_path, "/_s/#{@credential}/local/game/1.0.0/index.html")
      |> send_resp(429, "rate limited")

    assert sent.status == 429
    refute sent.request_path =~ @credential
  end

  test "leaves every other path as it is" do
    for path <- ["/t/home/local/demo", "/t/home/local/demo/_s/x/app.js", "/api/health", "/"] do
      assert run(path).request_path == path
    end
  end

  test "redact_path/1 names the served-file prefix of the URL grammar" do
    path = Prima.TinctureUrl.asset_path(@credential, ["local", "game", "1.0.0", "index.html"])
    assert ScrubTinctureCredentials.redact_path(path) =~ "/_s/[REDACTED]/"
  end

  # A value no request path may carry once the plug has run.
  @canary "c4n4ryP4geCredential0123456789_-"
  @frame "frm_8f3c2a1b9d"

  test "a canvas page credential is redacted, early refusals and malformed credentials included" do
    page = Prima.CanvasWire.page_path(@canary, @frame)
    assert String.starts_with?(page, Prima.CanvasWire.page_prefix())

    conn = run(page)
    assert conn.request_path == Prima.CanvasWire.page_prefix() <> "[REDACTED]/" <> @frame
    refute conn.request_path =~ @canary
    # Routing still reads the credential and the frame.
    assert conn.path_info == ["_c", "v1", @canary, @frame]

    # By shape: a credential outside the grammar, a path with no frame or
    # with more after it, and doubled slashes, which route as single ones.
    for path <- [
          "/_c/v1/#{@canary}!not-a-credential/#{@frame}",
          "/_c/v1/#{@canary}",
          "/_c/v1/#{@canary}/",
          "/_c/v1/#{@canary}/#{@frame}/extra",
          "/_c/v1//#{@canary}/#{@frame}",
          "/_c//v1//#{@canary}//#{@frame}",
          "/_c/v1/.#{@canary}./#{@frame}",
          "/_c/v1/#{String.duplicate(@canary, 64)}/#{@frame}"
        ] do
      scrubbed = run(path).request_path
      refute scrubbed =~ @canary, path
      assert scrubbed =~ "[REDACTED]", path
    end

    # A response answered before the action, as the rate limit answers
    # its 429, carries the redacted path too.
    sent =
      page
      |> run()
      |> Map.put(:request_path, page)
      |> send_resp(429, "rate limited")

    assert sent.status == 429
    refute sent.request_path =~ @canary

    # The served-file prefix is counted as routing counts it as well.
    refute run("/_s//#{@canary}/local/game/1.0.0/app.js").request_path =~ @canary

    # A prefix written with escapes is the prefix the router decodes and
    # routes, the served files' as much as the page's.
    for path <- [
          "/%5Fc/v1/#{@canary}/#{@frame}",
          "/_c/%76%31/#{@canary}/#{@frame}",
          "/%5f%63/%76%31/#{@canary}/#{@frame}",
          "/%5Fs/#{@canary}/local/game/1.0.0/app.js"
        ] do
      scrubbed = run(path).request_path
      refute scrubbed =~ @canary, path
      assert scrubbed =~ "/[REDACTED]/", path
    end

    # A segment whose escape does not decode is compared as it is written:
    # it routes nowhere, and the path is left as it came.
    assert run("/_c/v1%zz/#{@frame}/x").request_path == "/_c/v1%zz/#{@frame}/x"

    # A path the page prefix does not begin is not a page's.
    for path <- ["/_c", "/_c/v1", "/_c/v2/#{@frame}/x", "/a/_c/v1/x/y"] do
      assert run(path).request_path == path
    end
  end
end

defmodule CyfrWeb.Plugs.ScrubTinctureCredentialsTest.Spans do
  @moduledoc """
  No exported OpenTelemetry span carries a tincture credential. With
  `CYFR_OTEL_ENABLED=on` an
  instrumentation names a request by its raw path before any plug runs
  (`OpentelemetryBandit` reads Bandit's request-start connection), so no
  exported span may carry a credential the plug would have redacted. The
  SDK runs here with the runtime configuration's own `:opentelemetry`
  settings, its OTLP exporter replaced by one that sends each exported span
  to the test, and requests go through a real Bandit listener.

  Synchronous: it restarts the SDK, sets the operating-system environment
  the runtime configuration reads and attaches Bandit's instrumentation,
  and restores all three.
  """

  use ExUnit.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer
  require Record

  Record.defrecordp(
    :span,
    Record.extract(:span,
      from: Path.join(Mix.Project.deps_path(), "opentelemetry/include/otel_span.hrl")
    )
  )

  @root Path.expand("../../../../..", __DIR__)

  # Letters and digits only, so no percent-encoding of it differs from it.
  @canary "c4n4rySp4nCredential0123456789AbCdEf"
  @frame "frm_8f3c2a1b9d"

  # An exporter that tells `owner` it holds a batch, waits for `owner` to
  # let it go, and then sends `owner` the spans it was handed.
  defmodule HeldExporter do
    @moduledoc false
    def init(owner), do: {:ok, owner}
    def shutdown(_owner), do: :ok

    def export(tab, _resource, owner) do
      ref = make_ref()
      send(owner, {:holding, self(), ref})

      receive do
        {:release, ^ref} -> :ok
      after
        10_000 -> :ok
      end

      send(owner, {:exported, :ets.tab2list(tab)})
      :ok
    end
  end

  defmodule Ok do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)

    try do
      Enum.each(vars, &put_os_env/1)
      fun.()
    after
      Enum.each(previous, &put_os_env/1)
    end
  end

  defp put_os_env({k, nil}), do: System.delete_env(k)
  defp put_os_env({k, v}), do: System.put_env(k, v)

  # The `:opentelemetry` settings the prod branch of the runtime
  # configuration makes, `otel` the value of `CYFR_OTEL_ENABLED`, with no
  # `OTEL_*` variable of the host's in the way.
  defp runtime_otel_env(otel) do
    vars = %{
      "CYFR_SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(48)),
      "RELEASE_NAME" => "cyfr",
      "CYFR_DATABASE" => nil,
      "CYFR_OTEL_ENABLED" => otel,
      "OTEL_TRACES_EXPORTER" => nil
    }

    with_env(vars, fn ->
      config =
        Config.Reader.read!(Path.join(@root, "config/runtime.exs"),
          env: :prod,
          imports: :disabled
        )

      {Keyword.get(config, :opentelemetry, []), get_in(config, [:cyfr, :opentelemetry_enabled])}
    end)
  end

  defp effective(app_env, vars \\ %{}) do
    with_env(Map.merge(%{"OTEL_TRACES_EXPORTER" => nil}, vars), fn ->
      :otel_configuration.merge_with_os(app_env)
    end)
  end

  # The configured traces exporter with OTLP's, wherever it stands in it,
  # replaced by one that sends each exported span to `pid`.
  defp to_test_exporter(:otlp, pid), do: {:otel_exporter_pid, pid}
  defp to_test_exporter({:opentelemetry_exporter, _}, pid), do: {:otel_exporter_pid, pid}

  defp to_test_exporter({module, inner}, pid) when is_atom(module),
    do: {module, to_test_exporter(inner, pid)}

  defp to_test_exporter(other, _pid), do: other

  # Restarts the SDK under `app_env`. The SDK's settings are restored and
  # it is restarted after the test, whether it passed or not, and Bandit's
  # instrumentation is detached: anything the test's supervisor runs stops
  # before the callback.
  defp restart_sdk!(app_env) do
    saved = Application.get_all_env(:opentelemetry)

    on_exit(fn ->
      :telemetry.detach({OpentelemetryBandit, :otel_bandit})
      _ = Application.stop(:opentelemetry)

      for {key, _} <- Application.get_all_env(:opentelemetry),
          do: Application.delete_env(:opentelemetry, key)

      Application.put_all_env(opentelemetry: saved)
      {:ok, _} = Application.ensure_all_started(:opentelemetry)
    end)

    :ok = Application.stop(:opentelemetry)

    for {key, _} <- Application.get_all_env(:opentelemetry),
        do: Application.delete_env(:opentelemetry, key)

    Application.put_all_env(opentelemetry: app_env)
    {:ok, _} = Application.ensure_all_started(:opentelemetry)
    :ok
  end

  # Restarts the SDK under `app_env`, attaches Bandit's instrumentation as
  # the composition root does, and starts a listener.
  defp start_traced_listener!(app_env) do
    :ok = restart_sdk!(app_env)
    :ok = OpentelemetryBandit.setup()

    server =
      start_supervised!({Bandit, plug: Ok, ip: :loopback, port: 0, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  # One request, written as it stands so no client normalizes its target,
  # marked by its user agent so its span can be told from any other.
  defp request!(port, target) do
    marker = "span-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{target} HTTP/1.1\r\nhost: localhost\r\nuser-agent: #{marker}\r\n" <>
          "connection: close\r\n\r\n"
      )

    response = read_all(socket, "")
    :gen_tcp.close(socket)
    assert response =~ ~r/\AHTTP\/1\.1 200/, "#{target} was not served: #{response}"
    marker
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  # The exported span `marker` names, as the exporter received it: spans of
  # anything else are passed over, and none within the deadline fails.
  defp exported!(marker) do
    receive do
      {:span, exported} ->
        if attributes(exported)["user_agent.original"] == marker,
          do: exported,
          else: exported!(marker)
    after
      5_000 -> flunk("no span exported for #{marker}")
    end
  end

  defp attributes(exported) do
    exported
    |> span(:attributes)
    |> :otel_attributes.map()
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  # Each exported span that carries the credential, by the request it
  # names, with the attributes that carry it.
  defp leaks(exported_by_target) do
    for {target, exported} <- exported_by_target,
        inspect(exported, limit: :infinity, printable_limit: :infinity) =~ @canary,
        do: {target, for({k, v} <- attributes(exported), inspect(v) =~ @canary, do: k)}
  end

  describe "with the runtime configuration's SDK settings" do
    setup do
      {app_env, true} = runtime_otel_env("on")
      exporter = to_test_exporter(app_env[:traces_exporter], self())

      # The prod settings export in batches through OTLP; only the OTLP
      # exporter is replaced, and the batch delay shortened.
      assert app_env[:span_processor] == :batch
      assert exporter != app_env[:traces_exporter]

      port =
        app_env
        |> Keyword.merge(traces_exporter: exporter, bsp_scheduled_delay_ms: 10)
        |> start_traced_listener!()

      %{port: port}
    end

    test "no exported span carries a credential from a request's path or query", %{port: port} do
      cases = [
        {"/_s/#{@canary}/local/game/1.0.0/index.html",
         "/_s/[REDACTED]/local/game/1.0.0/index.html", nil},
        {"/_c/v1/#{@canary}/#{@frame}", "/_c/v1/[REDACTED]/#{@frame}", nil},
        {"/_c/v1/#{@canary}/#{@frame}?_t=#{@canary}&keep=1", "/_c/v1/[REDACTED]/#{@frame}",
         "_t=[REDACTED]&keep=1"},
        {"/%5Fc/%76%31/#{@canary}/#{@frame}", "/%5Fc/%76%31/[REDACTED]/#{@frame}", nil},
        {"/t/home/local/demo?%5Fsession=#{@canary}&_key=#{@canary}&page=2", "/t/home/local/demo",
         "%5Fsession=[REDACTED]&_key=[REDACTED]&page=2"}
      ]

      exported =
        for {target, _path, _query} <- cases, do: {target, exported!(request!(port, target))}

      assert leaks(exported) == []

      for {{target, path, query}, {target, span}} <- Enum.zip(cases, exported) do
        attrs = attributes(span)
        assert attrs["url.path"] == path, target
        assert attrs["url.query"] == query, target
      end
    end

    test "a span for an ordinary request keeps its path and query", %{port: port} do
      exported = port |> request!("/t/home/local/demo?x=1&page=2") |> exported!()

      attrs = attributes(exported)
      assert attrs["url.path"] == "/t/home/local/demo"
      assert attrs["url.query"] == "x=1&page=2"
      assert attrs["http.request.method"] == :GET
      assert span(exported, :kind) == :server
    end

    test "a span of any instrumentation is scrubbed, attributes set after its start included" do
      marker = "span-manual-" <> Integer.to_string(System.unique_integer([:positive]))

      Tracer.with_span "manual", %{attributes: %{"user_agent.original" => marker}} do
        Tracer.set_attributes(%{
          :"url.query" => "_session=#{@canary}&a=1",
          "http.route" => "/%5Fs/#{@canary}/a.js",
          "url.path" => "/_c/v1//#{@canary}/#{@frame}",
          "server.address" => "cyfr.test"
        })
      end

      exported = exported!(marker)
      assert leaks([{"manual span", exported}]) == []

      attrs = attributes(exported)

      assert attrs["url.query"] == "_session=[REDACTED]&a=1"
      assert attrs["http.route"] == "/%5Fs/[REDACTED]/a.js"
      assert attrs["url.path"] == "/_c/v1//[REDACTED]/#{@frame}"
      assert attrs["server.address"] == "cyfr.test"
    end
  end

  describe "while the SDK stops" do
    test "a span ending after the scrub reaches the exporter in no batch" do
      owner = self()

      # The batch is exported only by the stop, and the exporter that sends
      # is held once it has the batch, after the scrub.
      :ok =
        restart_sdk!(
          span_processor: :batch,
          bsp_scheduled_delay_ms: 600_000,
          traces_exporter: {CyfrWeb.ScrubSpanCredentials, {HeldExporter, owner}}
        )

      tracer = :opentelemetry.get_tracer(:scrub_span_credentials_test)

      early =
        :otel_tracer.start_span(tracer, "early", %{
          attributes: %{"url.path" => "/_s/#{@canary}/early.js"}
        })

      _ = :otel_span.end_span(early)

      late =
        :otel_tracer.start_span(tracer, "late", %{
          attributes: %{"url.path" => "/_c/v1/#{@canary}/#{@frame}"}
        })

      stopper = Task.async(fn -> Application.stop(:opentelemetry) end)
      assert_receive {:holding, exporter, ref}, 10_000

      # The stop's export holds the scrubbed batch; this span ends while
      # the SDK still takes spans in.
      _ = :otel_span.end_span(late)
      send(exporter, {:release, ref})

      assert_receive {:exported, exported}, 10_000
      assert Task.await(stopper, 10_000) == :ok

      assert leaks(for s <- exported, do: {span(s, :name), s}) == []
      assert Enum.map(exported, &span(&1, :name)) == ["early"]
      assert attributes(hd(exported))["url.path"] == "/_s/[REDACTED]/early.js"
    end
  end

  describe "the runtime configuration" do
    test "with OTel on, every span processor exports through the scrub" do
      {app_env, true} = runtime_otel_env("on")

      assert [
               {:otel_batch_processor,
                %{exporter: {CyfrWeb.ScrubSpanCredentials, {:opentelemetry_exporter, %{}}}}}
             ] = effective(app_env).processors

      assert with_env(%{"OTEL_TRACES_EXPORTER" => nil}, fn ->
               Cyfr.Application.ensure_configured_traces_exporter!(app_env)
             end) == :ok
    end

    test "with OTel on, a boot whose environment replaces the scrub is refused" do
      {app_env, true} = runtime_otel_env("on")

      # The SDK lets the environment replace the configured exporter.
      assert [{:otel_batch_processor, %{exporter: {:opentelemetry_exporter, _}}}] =
               effective(app_env, %{"OTEL_TRACES_EXPORTER" => "otlp"}).processors

      with_env(%{"OTEL_TRACES_EXPORTER" => "otlp"}, fn ->
        assert_raise RuntimeError, ~r/OTEL_TRACES_EXPORTER/, fn ->
          Cyfr.Application.ensure_configured_traces_exporter!(app_env)
        end
      end)
    end

    test "with OTel off, nothing is installed and nothing exports" do
      {app_env, enabled} = runtime_otel_env(nil)

      assert enabled == nil
      assert app_env[:traces_exporter] == :none

      config = effective(app_env)
      refute inspect(config, limit: :infinity) =~ "ScrubSpanCredentials"

      for {_processor, opts} <- config.processors,
          do: assert(Map.get(opts, :exporter) in [:none, :undefined, nil])
    end
  end
end
