# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ProgramsLiveTest do
  @moduledoc """
  The Programs page adds a program through its one form, its mark chosen,
  sends its env lines as the program's env, asks the person to confirm a
  program's definition and makes it once confirmed, says why a row was not
  added, says why a row it added or tested could not connect, shows the
  warnings a program it added carries in the flash and on its row, offers
  Restart for an mcp program only, replaces a program's whole definition
  keeping its folder, removes a program once its removal is confirmed,
  and shows a disabled program as stopped. It prefills the program form
  for a program brain from its definition and opens the program's
  terminal in the row's folder once the install is confirmed. A program opens on a
  terminal the server owns for the person: the page attaches once the
  frame's hook stands, hands each write to the hook and keeps none of it,
  types and resizes, lists and closes the person's running sessions, and
  leaving or reloading ends nothing.
  """
  use PrismWeb.ConnCase, async: false

  alias Cyfr.Test.HTTPStub

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, athanor: seated_athanor(), user: user}
  end

  defp ctx(athanor),
    do: Sanctum.Context.actor(Sanctum.Context.internal(athanor_id: athanor.id, scope: :athanor))

  # An entry the person enters in the athanor, as the vault creates one.
  defp entry!(user, athanor, name, destination, disclose \\ false) do
    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: athanor.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, _} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: name,
        kind: "api_key",
        fields: %{"token" => "t-" <> name},
        destination: destination,
        disclose: disclose
      })
  end

  defp flash(view, kind), do: :sys.get_state(view.pid).socket.assigns.flash[kind]

  # How long a test waits for a call's answer to reach the page.
  @answered_ms 5_000

  # The page's answer to a call it makes off the event.
  defp answered(view), do: render_async(view, @answered_ms)

  # The browser gives up on a pushed event it waits on for 30 seconds and
  # reloads (the shipped script's push timeout); a test stands that wait
  # in with this one.
  @push_timeout_ms 1_000

  # An event as the browser pushes it: waited on no longer than the
  # browser waits.
  defp pushed(fun) do
    task = Task.async(fun)

    case Task.yield(task, @push_timeout_ms) do
      {:ok, html} -> html
      nil -> :unanswered
    end
  end

  # The calls the page has running off its events.
  defp running_calls(view) do
    {:ok, pids} = Phoenix.LiveView.Channel.async_pids(view.pid)
    pids
  end

  @root :crypto.strong_rand_bytes(32)

  test "an mcp program whose command expands a vault-bound name is added with its warning",
       %{conn: conn, athanor: athanor, user: user} do
    # The control plane the controller takes is put back however the test
    # ends, registered before it is taken.
    on_exit(fn ->
      :persistent_term.erase({Arca.ControlPlane, :generation})
      Arca.ControlPlane.record(:unclaimed)
    end)

    fake = Cyfr.Test.ScriptedBackends.start(self(), @root)

    Cyfr.Test.ScriptedBackends.supervise_controller(
      url: fake.url,
      root: @root,
      tick_ms: 3_600_000
    )

    assert_receive {:control, "reconcile", _reconcile, _fields}, 2_000
    entry!(user, athanor, "gh", %{"hosts" => ["api.github.com"]}, true)

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("button", "Add program") |> render_click()

    view
    |> form("form[phx-submit=add_program]", %{
      "name" => "github",
      "mark" => "mcp",
      "command" => "npx -y @modelcontextprotocol/server-github --token $GITHUB_TOKEN",
      "env" => "GITHUB_TOKEN=vault:gh"
    })
    |> render_submit()

    answered(view)
    confirm!(view, user, athanor, "mcp_servers.create")

    warning =
      "The command expands GITHUB_TOKEN, a vault-bound env name: the value is placed on " <>
        "the command line, where every process of the program's own session can read it; " <>
        "the safe route is to let the program read it from its environment."

    assert flash(view, "info") == "'github' added (ready)."
    assert flash(view, "warning") == warning
    assert_received {:control, "sync", _sync, _fields}

    html = view |> element("tr[phx-value-name=github]") |> render_click()
    assert html =~ "The command expands GITHUB_TOKEN, a vault-bound env name"
  end

  test "the program form refuses a malformed env line, and a program the catalog refuses",
       %{conn: conn, athanor: athanor, user: user} do
    # The entry the env names, disclosed: an environment hands it on.
    entry!(user, athanor, "gh", %{"hosts" => ["api.github.com"]}, true)

    {view, html} = mount_athanor(conn, "/programs", athanor)
    assert html =~ "Add program"
    refute html =~ "stdio"

    view |> element("button", "Add program") |> render_click()

    html =
      view
      |> form("form[phx-submit=add_program]", %{
        "name" => "github",
        "command" => "npx -y @modelcontextprotocol/server-github",
        "env" => "GITHUB_TOKEN vault:gh"
      })
      |> render_submit()

    assert html =~ "Each env line is NAME=value"

    view
    |> form("form[phx-submit=add_program]", %{
      "name" => "github",
      "command" => "npx -y @modelcontextprotocol/server-github",
      "env" => "GITHUB_TOKEN=vault:gh\n\nNODE_ENV=production"
    })
    |> render_submit()

    html = answered(view)

    assert html =~ "No backends service is configured"
    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx(athanor), "github")
  end

  # A terminal open adds TERM to a row's environment, which the keeper
  # bounds: the form says how many a program may name.
  test "a program naming more variables than a terminal leaves room for is refused in the form",
       %{conn: conn, athanor: athanor} do
    controller!()
    max = Prima.LocusBackends.max_env_names()
    env = Enum.map_join(1..(max + 1), "\n", &"V#{&1}=vault:x")

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("button", "Add program") |> render_click()

    view
    |> form("form[phx-submit=add_program]", %{"name" => "many", "command" => "cat", "env" => env})
    |> render_submit()

    assert answered(view) =~ "config.env names at most #{max} variables besides TERM"
    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx(athanor), "many")
  end

  test "a header naming an entry that may not go to the server's URL is refused in the form",
       %{conn: conn, athanor: athanor, user: user} do
    entry!(user, athanor, "openai-key", %{"hosts" => ["api.openai.com"]})
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("button", "Add server") |> render_click()

    config =
      Jason.encode!(%{
        "url" => "https://evil.example/mcp",
        "headers" => %{"Authorization" => "vault:openai-key"}
      })

    view
    |> form("form[phx-submit=add_server]", %{"name" => "relay", "config" => config})
    |> render_submit()

    answered(view)

    error = view |> element("form[phx-submit=add_server] div.text-red-400") |> render()
    assert error =~ "Failed to add: Header"
    assert error =~ "names no active vault entry whose destination covers this server"
    refute error =~ "openai-key"
    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx(athanor), "relay")
  end

  test "a server added or tested whose connect is refused says why where it was acted on",
       %{conn: conn, athanor: athanor, user: user} do
    entry!(user, athanor, "openai-key", %{"hosts" => ["api.openai.com"]})
    entry!(user, athanor, "local-key", %{"hosts" => ["127.0.0.1"], "port" => 9})

    on_exit(fn ->
      for name <- ["local", "edited"],
          do: Emissary.External.ServerSupervisor.stop(name, athanor.id)
    end)

    # A row edited underneath to send its entry elsewhere.
    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "edited",
        url: "https://evil.example/mcp",
        config_json:
          Jason.encode!(%{
            "headers" => %{"Authorization" => "vault:openai-key"},
            "timeout_ms" => 1_000
          })
      })

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("button", "Add server") |> render_click()

    # Admitted, and then refused by the upstream itself: nothing listens there.
    config =
      Jason.encode!(%{
        "url" => "https://127.0.0.1:9/mcp",
        "headers" => %{"Authorization" => "vault:local-key"}
      })

    view
    |> form("form[phx-submit=add_server]", %{"name" => "local", "config" => config})
    |> render_submit()

    answered(view)

    assert {:ok, _} = Arca.McpServerStorage.get(ctx(athanor), "local")
    assert flash(view, "error") =~ "'local' added — "

    # The edited row's Test says why, in the refusal's own words.
    view |> element("tr[phx-value-name=edited]") |> render_click()
    view |> element(~s(button[phx-click="test"][phx-value-name="edited"])) |> render_click()
    answered(view)

    assert flash(view, "error") ==
             "Test edited: " <> Sanctum.Refusals.render(:destination_mismatch)

    refute flash(view, "error") =~ "openai-key"
  end

  # A connect waits up to a minute (`timeout_ms`), longer than the browser
  # waits on the event; the server here holds the first request until the
  # test releases it, then refuses it.
  test "a Test held past the browser's wait answers at once, says so, starts no second call, and shows its answer",
       %{conn: conn, athanor: athanor} do
    stub = HTTPStub.open()
    test = self()
    seen = :counters.new(1, [])

    HTTPStub.stub(stub, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      :counters.add(seen, 1, 1)

      if :counters.get(seen, 1) == 1 do
        send(test, {:held, self()})

        receive do
          :release -> :ok
        end
      end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "error" => %{"code" => -32001, "message" => "held and refused"}
        })
      )
    end)

    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "slow",
        url: "http://127.0.0.1:#{stub.port}/mcp"
      })

    on_exit(fn -> Emissary.External.ServerSupervisor.stop("slow", athanor.id) end)

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    html = pushed(fn -> render_click(view, "test", %{"name" => "slow"}) end)
    assert_receive {:held, held}, @answered_ms

    try do
      assert is_binary(html), "the page did not answer while the server held the connect"
      assert html =~ "Testing slow…"
      [call] = running_calls(view)

      # A second Test, and another row call, while it runs start nothing.
      assert is_binary(pushed(fn -> render_click(view, "test", %{"name" => "slow"}) end))
      assert is_binary(pushed(fn -> render_click(view, "refresh", %{"name" => "slow"}) end))
      assert running_calls(view) == [call]

      # Held past the browser's wait, and past it twice, the page still
      # says it is testing.
      # sleep-ok: twice the browser's 1 s push wait, in which the page must not leave "Testing
      # slow…"
      Process.sleep(2 * @push_timeout_ms)
      assert render(view) =~ "Testing slow…"
    after
      send(held, :release)
    end

    html = answered(view)
    refute html =~ "Testing slow…"
    assert flash(view, "error") =~ "Test slow: "
    assert flash(view, "error") =~ "held and refused"
  end

  @echoed "sk-echo-live-0123456789"

  for era <- [:modern, :legacy] do
    test "an upstream echoing the header it was sent shows the mask in the flash (#{era} peer)",
         %{conn: conn, athanor: athanor, user: user} do
      stub = HTTPStub.open()
      echo_upstream(stub, unquote(era))

      ctx =
        Sanctum.Context.build(
          user_id: user.user_id,
          athanor_id: athanor.id,
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, _} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "echo-key",
          kind: "api_key",
          fields: %{"token" => @echoed},
          destination: %{"hosts" => ["127.0.0.1"], "scheme" => "http", "port" => stub.port}
        })

      on_exit(fn -> Emissary.External.ServerSupervisor.stop("echo", athanor.id) end)

      {view, _html} = mount_athanor(conn, "/programs", athanor)
      view |> element("button", "Add server") |> render_click()

      config =
        Jason.encode!(%{
          "url" => "http://127.0.0.1:#{stub.port}/mcp",
          "headers" => %{"Authorization" => "vault:echo-key"}
        })

      view
      |> form("form[phx-submit=add_server]", %{"name" => "echo", "config" => config})
      |> render_submit()

      added = answered(view)

      assert flash(view, "error") == "'echo' added — rejected credential [REDACTED]"
      refute added =~ @echoed

      view |> element("tr[phx-value-name=echo]") |> render_click()

      view
      |> element(~s(button[phx-click="test"][phx-value-name="echo"]))
      |> render_click()

      tested = answered(view)

      assert flash(view, "error") == "Test echo: rejected credential [REDACTED]"
      refute tested =~ @echoed
    end
  end

  # An upstream that refuses the connect with an error quoting the
  # Authorization header it was sent: at `server/discover` for a current
  # peer, and at `initialize` for one that answers the current probe as a
  # legacy peer does.
  defp echo_upstream(stub, era) do
    HTTPStub.stub(stub, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [auth] = Plug.Conn.get_req_header(conn, "authorization")

      case {era, request["method"]} do
        {:legacy, "server/discover"} ->
          Plug.Conn.resp(conn, 400, "Bad Request")

        _echoed ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "error" => %{"code" => -32001, "message" => "rejected credential #{auth}"}
            })
          )
      end
    end)
  end

  test "an expanded mcp program offers Restart and an http server does not",
       %{conn: conn, athanor: athanor} do
    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "piped",
        transport: "program",
        mark: "mcp",
        url: nil,
        enabled: false,
        config_json: Jason.encode!(%{"command" => "npx -y fs", "env" => %{}})
      })

    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "webby",
        url: "https://127.0.0.1:9/mcp",
        enabled: false
      })

    {view, html} = mount_athanor(conn, "/programs", athanor)
    assert html =~ "MCP (backends service)"

    html = view |> element("tr[phx-value-name=piped]") |> render_click()
    assert html =~ ~s(phx-click="restart")

    view |> element("tr[phx-value-name=piped]") |> render_click()
    html = view |> element("tr[phx-value-name=webby]") |> render_click()
    refute html =~ ~s(phx-click="restart")
  end

  # A driven program has no MCP client: the table shows no connection
  # and no tools for it, a dash in each, while a tool server and an MCP
  # program keep their status and their count.
  test "a driven row's status and tools are empty, and an MCP row keeps both",
       %{conn: conn, athanor: athanor} do
    _driven = driven_row!(athanor)

    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "piped",
        transport: "program",
        mark: "mcp",
        url: nil,
        enabled: false,
        config_json: Jason.encode!(%{"command" => "npx -y fs", "env" => %{}})
      })

    {view, _html} = mount_athanor(conn, "/programs", athanor)

    cells = fn name ->
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(tr[phx-value-name="#{name}"] td[data-test]))
      |> Enum.map(
        &{List.first(LazyHTML.attribute(&1, "data-test")), String.trim(LazyHTML.text(&1))}
      )
    end

    assert cells.("claude") == [{"home", "kept"}, {"status", "—"}, {"tools", "—"}]

    assert has_element?(
             view,
             ~s(tr[phx-value-name="claude"]),
             "driven by a person or a crew member"
           )

    assert [{"home", "scratch"}, {"status", status}, {"tools", "0"}] = cells.("piped")
    refute status in ["", "—"]
  end

  alias Cyfr.Test.ScriptedBackends, as: Scripted

  # The programs controller on a scripted backends service, put back
  # however the test ends.
  defp controller!, do: elem(box!(), 0)

  # What a button asks in the browser before its press is sent; nil for none.
  defp question(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-confirm")
    |> List.first()
  end

  # The scripted service and the controller, which checks its rows again
  # when a test sends it `:tick`.
  defp box! do
    on_exit(fn ->
      :persistent_term.erase({Arca.ControlPlane, :generation})
      Arca.ControlPlane.record(:unclaimed)
    end)

    fake = Scripted.start(self(), @root)
    controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "reconcile", _reconcile, _fields}, 2_000
    {fake, controller}
  end

  defp person(user, athanor),
    do:
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: athanor.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

  defp driven_row!(athanor, name \\ "claude") do
    {:ok, row} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        config_json: Jason.encode!(%{"command" => "npx -y @anthropic-ai/#{name}", "env" => %{}})
      })

    row
  end

  # The person confirms the one confirmation of `operation` the page asked
  # for, as on another of their devices, and the page makes its change
  # again naming it (`system_layer_repeat/4`) and answers.
  defp confirm!(view, user, athanor, operation) do
    person = person(user, athanor)

    assert {:ok, [%{ref: ref, operation: ^operation}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(person), user.user_id)

    Sanctum.TestContext.prove!(person, ref)

    assert eventually(fn ->
             match?(
               {:ok, %{state: "consumed"}},
               Arca.PendingConfirmations.get(Sanctum.Context.actor(person), ref)
             )
           end)

    answered(view)
  end

  # What the page's confirmation shows, as the store holds it.
  defp asked(user, athanor, operation) do
    person = person(user, athanor)

    assert {:ok, [%{ref: ref, operation: ^operation}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(person), user.user_id)

    {:ok, %{preview: preview}} =
      Arca.PendingConfirmations.get(Sanctum.Context.actor(person), ref)

    Jason.decode!(preview)
  end

  defp open_confirmations(user, athanor) do
    person = person(user, athanor)

    {:ok, open} =
      Arca.PendingConfirmations.list_open(Sanctum.Context.actor(person), user.user_id)

    open
  end

  # Until `fun` holds, or a bound passes.
  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      # sleep-ok: poll interval of eventually's bounded wait (50 tries)
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  # The session the page's last call opened, read from the address it
  # patched to.
  defp opened_session(view) do
    path = assert_patch(view, @answered_ms)
    assert %{"terminal" => session} = URI.decode_query(URI.parse(path).query || "")
    session
  end

  defp open!(view, name, args \\ "") do
    view |> element("tr[phx-value-name=#{name}]") |> render_click()
    view |> form("form#open-#{name}", %{"terminal_args" => args}) |> render_submit()
    answered(view)
    opened_session(view)
  end

  # The frame's hook stands, at its fitted size: the page attaches and
  # answers what was printed before, decoded.
  defp ready!(view, session, rows \\ 30, cols \\ 100) do
    render_hook(view, "terminal_ready", %{"session" => session, "rows" => rows, "cols" => cols})
    assert_reply(view, %{data: data})
    Base.decode64!(data)
  end

  # What the page hands the frame next, which the frame then says it drew,
  # as its hook does once xterm has written it.
  defp output!(view, session) do
    assert_push_event(
      view,
      "terminal_output",
      %{session: ^session, delivery: delivery, data: data},
      2_000
    )

    render_hook(view, "terminal_written", %{"session" => session, "delivery" => delivery})
    Base.decode64!(data)
  end

  test "Open runs a program on a terminal in its own folder with the words typed after its " <>
         "command, and the page carries both ways what the program and the person write",
       %{conn: conn, athanor: athanor, user: user} do
    fake = controller!()
    row = driven_row!(athanor)
    home = row.id

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    session = open!(view, "claude", "login --device-auth")
    [{terminal, _person}] = Registry.lookup(Opus.Programs.Registry, {:terminal, session})
    key = :sys.get_state(terminal).lifetime.key

    assert_receive {:session, "open",
                    %{
                      "mode" => "terminal",
                      "key" => ^key,
                      "home_id" => ^home,
                      "argv" => ["login", "--device-auth"]
                    }, _fields},
                   2_000

    # The chrome is CYFR's own: the program's name and Close, and nothing
    # the program writes.
    assert has_element?(view, ~s([data-test="terminal-name"]), "claude")
    assert has_element?(view, ~s([data-test="terminal-close"]))

    Scripted.write(fake, row.id, "Paste code here if prompted")

    assert eventually(fn -> :sys.get_state(terminal_pid(session)).tail.bytes != "" end)

    # Attached once the frame stands: what was printed before, and the
    # frame's size given to the program.
    assert ready!(view, session) == "Paste code here if prompted\r\n"
    assert_receive {:session, "resize", %{"rows" => 30, "cols" => 100}, _fields}, 2_000

    Scripted.write(fake, row.id, "second")
    assert output!(view, session) == "second\r\n"

    render_hook(view, "terminal_input", %{"session" => session, "terminal_input" => "code-1234\r"})

    typed = Base.encode64("code-1234\r")
    assert_receive {:session, "input", %{"bytes" => ^typed}, _fields}, 2_000

    render_hook(view, "terminal_resize", %{"session" => session, "rows" => 40, "cols" => 120})
    assert_receive {:session, "resize", %{"rows" => 40, "cols" => 120}, _fields}, 2_000

    # Kept, a day unwatched does not end it.
    view |> element(~s([data-test="terminal-keep"])) |> render_click()
    assert {:ok, [%{kept: true}]} = Opus.Programs.running(person(user, athanor))

    # The row lists it while it runs; Close ends it and the frame says so.
    view |> element("tr[phx-value-name=claude]") |> render_click()
    view |> element("tr[phx-value-name=claude]") |> render_click()
    assert has_element?(view, ~s([data-test="running-session"]))

    view |> element(~s([data-test="terminal-close"])) |> render_click()
    assert_receive {:session, "close", _message, _fields}, 2_000

    # The page waits off its process, and says it once the close answered.
    assert eventually(fn ->
             has_element?(view, ~s([data-test="terminal-ended"]), "The program was closed.")
           end)

    assert {:ok, []} = Opus.Programs.running(person(user, athanor))
  end

  test "a program Aqua started is listed as Aqua's, closed here, and never shown here",
       %{conn: conn, athanor: athanor, user: user} do
    _fake = controller!()
    row = driven_row!(athanor)
    me = person(user, athanor)
    actor = Sanctum.Context.actor(me)
    {:ok, thread} = Arca.Test.Days.thread(actor)

    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: user.user_id, sent_by: "person", content: "run claude"},
        turn: %{agent: "aqua", requested_by: user.user_id, origin: :interactive}
      })

    require Ecto.Query
    root = "exe_page_turn_#{System.unique_integer([:positive])}"

    {1, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [root_execution_id: root, status: "running"]
      )

    caller =
      Opus.Programs.turn(Sanctum.Context.enter_guest(me), %{
        "thread_id" => thread.id,
        "root_execution_id" => root,
        "parent_execution_id" => root
      })

    assert {:ok, session} =
             Opus.Programs.start(caller, row.id, %{
               rows: 50,
               cols: 200,
               args: [],
               epoch: row.epoch
             })

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("tr[phx-value-name=claude]") |> render_click()

    assert has_element?(view, ~s([data-test="running-session"]), "started by Aqua")
    refute has_element?(view, ~s([data-test="running-session"] button[phx-click="show_terminal"]))

    view
    |> element(~s([data-test="running-session"] button[phx-value-session="#{session}"]))
    |> render_click()

    assert_receive {:session, "close", _message, _fields}, 2_000
    assert eventually(fn -> Opus.Programs.running(me) == {:ok, []} end)
  end

  test "the page answers while a Close waits for the place, and says closed only after",
       %{conn: conn, athanor: athanor, user: user} do
    fake = controller!()
    row = driven_row!(athanor)

    {:ok, session} =
      Opus.Programs.start(person(user, athanor), row.id, %{rows: 24, cols: 80, args: []})

    {view, _html} = mount_athanor(conn, "/programs?terminal=#{session}", athanor)
    ready!(view, session)
    Scripted.hold(fake, "close")

    view |> element(~s([data-test="terminal-close"])) |> render_click()
    assert_receive {:held, "close", service}, 2_000

    # Events the closing session would hold the page on return at once.
    started = System.monotonic_time(:millisecond)
    render_hook(view, "terminal_input", %{"session" => session, "terminal_input" => "x"})
    render_hook(view, "terminal_resize", %{"session" => session, "rows" => 30, "cols" => 90})
    assert System.monotonic_time(:millisecond) - started < 1_000
    refute has_element?(view, ~s([data-test="terminal-ended"]))

    send(service, :go)

    assert eventually(fn ->
             has_element?(view, ~s([data-test="terminal-ended"]), "The program was closed.")
           end)
  end

  test "an unanswered Close says so, whatever ending the session announced before its answer",
       %{conn: conn, athanor: athanor, user: user} do
    fake = controller!()
    row = driven_row!(athanor)

    {:ok, session} =
      Opus.Programs.start(person(user, athanor), row.id, %{rows: 24, cols: 80, args: []})

    {view, _html} = mount_athanor(conn, "/programs?terminal=#{session}", athanor)
    ready!(view, session)
    Scripted.refuse_once(fake, "close", "internal")

    view |> element(~s([data-test="terminal-close"])) |> render_click()

    assert eventually(fn -> has_element?(view, ~s([data-test="terminal-ended"])) end)

    assert has_element?(
             view,
             ~s([data-test="terminal-ended"]),
             "The close was not confirmed yet; CYFR ends the program."
           )
  end

  test "a second tab hears an unanswered Close as the first does, never as closed",
       %{conn: conn, athanor: athanor, user: user} do
    fake = controller!()
    row = driven_row!(athanor)

    {:ok, session} =
      Opus.Programs.start(person(user, athanor), row.id, %{rows: 24, cols: 80, args: []})

    {first, _html} = mount_athanor(conn, "/programs?terminal=#{session}", athanor)
    ready!(first, session)
    {second, _html} = mount_athanor(conn, "/programs?terminal=#{session}", athanor)
    ready!(second, session)
    Scripted.refuse_once(fake, "close", "internal")

    first |> element(~s([data-test="terminal-close"])) |> render_click()

    assert eventually(fn -> has_element?(second, ~s([data-test="terminal-ended"])) end)

    assert has_element?(
             second,
             ~s([data-test="terminal-ended"]),
             "The close was not confirmed yet; CYFR ends the program."
           )
  end

  test "a lost close task leaves the terminal's ending to be shown",
       %{conn: conn, athanor: athanor, user: user} do
    fake = controller!()
    row = driven_row!(athanor)

    {:ok, session} =
      Opus.Programs.start(person(user, athanor), row.id, %{rows: 24, cols: 80, args: []})

    {view, _html} = mount_athanor(conn, "/programs?terminal=#{session}", athanor)
    ready!(view, session)
    Scripted.hold(fake, "close")

    task = close_task!(view)
    assert_receive {:held, "close", service}, 2_000
    Process.exit(task, :kill)
    send(service, :go)

    assert eventually(fn ->
             has_element?(view, ~s([data-test="terminal-ended"]), "The program was closed.")
           end)
  end

  test "a close task lost before it was answered gives the terminal back",
       %{conn: conn, athanor: athanor, user: user} do
    _fake = controller!()
    row = driven_row!(athanor)

    {:ok, session} =
      Opus.Programs.start(person(user, athanor), row.id, %{rows: 24, cols: 80, args: []})

    {view, _html} = mount_athanor(conn, "/programs?terminal=#{session}", athanor)
    ready!(view, session)
    pid = terminal_pid(session)
    :ok = :sys.suspend(pid)

    try do
      task = close_task!(view)
      Process.exit(task, :kill)

      assert eventually(fn -> render(view) =~ "Failed:" end),
             "the page never heard that its Close was lost"

      # Close is taken again.
      assert is_pid(close_task!(view))
    after
      :sys.resume(pid)
    end
  end

  # The task a click of Close started.
  defp close_task!(view) do
    before = Task.Supervisor.children(Prism.TaskSupervisor)
    view |> element(~s([data-test="terminal-close"])) |> render_click()
    assert [task] = Task.Supervisor.children(Prism.TaskSupervisor) -- before
    task
  end

  defp terminal_pid(session) do
    [{pid, _person}] = Registry.lookup(Opus.Programs.Registry, {:terminal, session})
    pid
  end

  # The browser behind the page names the delivery it drew by the token it
  # was handed with it: only the token of the delivery pushed last hands
  # the page what came since.
  test "an acknowledgment with a wrong token releases no output to the page",
       %{conn: conn, athanor: athanor, user: user} do
    fake = controller!()
    row = driven_row!(athanor)
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    session = open!(view, "claude")
    ready!(view, session)

    Scripted.write(fake, row.id, "one")

    assert_push_event(
      view,
      "terminal_output",
      %{session: ^session, delivery: delivery, data: data},
      2_000
    )

    assert Base.decode64!(data) == "one\r\n"
    Scripted.write(fake, row.id, "two")

    # The guesses are made only once the session has read "two", which it
    # then keeps for the page and a wrong token would release.
    Prima.Test.Wait.wait_until(
      fn ->
        match?(
          {:ok, %{output: %{bytes: "two\r\n"}}},
          Opus.Programs.read(person(user, athanor), session, byte_size("one\r\n"))
        )
      end,
      5_000,
      "the session to have read the second output"
    )

    for guess <- ["1", "2", delivery <> "x"],
        do: render_hook(view, "terminal_written", %{"session" => session, "delivery" => guess})

    refute_push_event(view, "terminal_output", %{session: ^session}, 300)

    render_hook(view, "terminal_written", %{"session" => session, "delivery" => delivery})
    assert output!(view, session) == "two\r\n"
  end

  test "a reload or a second tab attaches to the running screen, and leaving ends nothing",
       %{conn: conn, athanor: athanor, user: user} do
    fake = controller!()
    row = driven_row!(athanor)

    {first, _html} = mount_athanor(conn, "/programs", athanor)
    session = open!(first, "claude")
    ready!(first, session)
    Scripted.write(fake, row.id, "the running screen")
    assert output!(first, session) == "the running screen\r\n"

    {second, _html} = mount_athanor(conn, "/programs?terminal=#{session}", athanor)
    assert ready!(second, session) == "the running screen\r\n"

    # Both draw what comes next.
    Scripted.write(fake, row.id, "both")
    assert output!(first, session) == "both\r\n"
    assert output!(second, session) == "both\r\n"

    # The first tab goes: the program runs on, and the second still draws it.
    ref = Process.monitor(first.pid)
    GenServer.stop(first.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000
    refute_received {:session, "close", _message, _fields}

    assert {:ok, [%{session: ^session, attached: true}]} =
             Opus.Programs.running(person(user, athanor))

    Scripted.write(fake, row.id, "still")
    assert output!(second, session) == "still\r\n"
  end

  test "the frame says when the part that runs programs restarted, and how to go on",
       %{conn: conn, athanor: athanor} do
    fake = controller!()
    _row = driven_row!(athanor)
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    session = open!(view, "claude")
    ready!(view, session)

    Scripted.restart(fake, "bb_again")

    assert eventually(fn ->
             has_element?(
               view,
               ~s([data-test="terminal-ended"]),
               "The program stopped because CYFR restarted the part that runs programs. " <>
                 "Open it again to go on."
             )
           end)
  end

  test "the frame says when its program ended, and that a session no longer running is gone",
       %{conn: conn, athanor: athanor} do
    fake = controller!()
    row = driven_row!(athanor)
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    session = open!(view, "claude")
    ready!(view, session)

    Scripted.end_sessions(fake, row.id, 0)

    assert eventually(fn ->
             has_element?(view, ~s([data-test="terminal-ended"]), "The program ended.")
           end)

    # A session whose owner died outright is said to have ended too.
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    killed = open!(view, "claude")
    ready!(view, killed)
    Process.exit(terminal_pid(killed), :kill)

    assert eventually(fn ->
             has_element?(view, ~s([data-test="terminal-ended"]), "The program ended.")
           end)

    {gone, _html} = mount_athanor(conn, "/programs?terminal=trm_nobody", athanor)
    render_hook(gone, "terminal_ready", %{"session" => "trm_nobody", "rows" => 24, "cols" => 80})

    assert has_element?(
             gone,
             ~s([data-test="terminal-ended"]),
             "This program is not running any more."
           )

    refute has_element?(gone, "#terminal-trm_nobody-screen")
  end

  # The frame was dropped with its screen at the end, so a program that
  # printed why it failed and exited left only "The program ended.".
  test "at the end the screen stays as it was, read-only, beside the ending, until the " <>
         "person closes the frame; a reload after has no screen",
       %{conn: conn, athanor: athanor} do
    fake = controller!()
    row = driven_row!(athanor)
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    session = open!(view, "claude")
    ready!(view, session)
    Scripted.write(fake, row.id, "why it failed")
    assert output!(view, session) == "why it failed\r\n"

    Scripted.end_sessions(fake, row.id, 3)
    assert_push_event(view, "terminal_ended", %{session: ^session}, 3_000)
    assert has_element?(view, ~s([data-test="terminal-ended"]), "The program ended.")
    assert has_element?(view, "#terminal-#{session}-screen[phx-hook=Terminal]")
    refute has_element?(view, ~s([data-test="terminal-close"]))
    refute has_element?(view, ~s([data-test="terminal-keep"]))

    # An acknowledgement the browser sends after the end says nothing new.
    render_hook(view, "terminal_written", %{"session" => session, "delivery" => "stale"})
    assert has_element?(view, ~s([data-test="terminal-ended"]), "The program ended.")

    {reloaded, _html} = mount_athanor(conn, "/programs?terminal=#{session}", athanor)
    render_hook(reloaded, "terminal_ready", %{"session" => session, "rows" => 24, "cols" => 80})

    assert has_element?(
             reloaded,
             ~s([data-test="terminal-ended"]),
             "This program is not running any more."
           )

    refute has_element?(reloaded, "#terminal-#{session}-screen")

    view |> element(~s([data-test="terminal-dismiss"])) |> render_click()
    assert_patch(view)
    refute has_element?(view, ~s([data-test="terminal"]))
  end

  # A page elsewhere can send a signed-in browser to any address, so no
  # address starts anything: a start is the person's press.
  test "an address naming a program to open starts nothing",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    driven_row!(athanor)

    {view, _html} = mount_athanor(conn, "/programs?open=claude&from=aqua", athanor)
    render(view)
    assert running_calls(view) == []
    refute_receive {:session, "open", _message, _fields}, 500
    refute has_element?(view, ~s([data-test="terminal"]))
    assert {:ok, []} = Opus.Programs.running(person(user, athanor))
  end

  test "shown from Aqua's card, the terminal offers the way back to Aqua",
       %{conn: conn, athanor: athanor} do
    controller!()
    driven_row!(athanor)

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    session = open!(view, "claude")

    {view, _html} =
      mount_athanor(conn, "/programs?terminal=#{session}&from=aqua", athanor)

    [back] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-test="back-to-aqua"]))
      |> LazyHTML.attribute("href")

    assert back =~ ~r{/aqua\?setup=1$}
  end

  # What a program writes may be a credential: the page hands it to the
  # frame's hook and keeps none, so its state, printed by a crash report
  # or LiveView's termination log, carries none of it.
  test "no byte a program wrote is in the page's state or a crash report of it",
       %{conn: conn, athanor: athanor} do
    fake = controller!()
    row = driven_row!(athanor)
    canary = "sk-canary-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    session = open!(view, "claude")
    ready!(view, session)
    Scripted.write(fake, row.id, canary)
    assert output!(view, session) =~ canary

    # What LiveView's termination formatter hands a crash report: the
    # page's whole state, components included, before a logger cuts it.
    terminated =
      Phoenix.LiveView.Channel.format_status(:terminate, [%{}, :sys.get_state(view.pid)])

    refute inspect(terminated, limit: :infinity, printable_limit: :infinity) =~ canary

    # The chunk as the page receives it prints as its size.
    message = {Opus.Programs, session, {:bytes, "token", Opus.Programs.Output.new(canary)}}
    refute inspect(message, limit: :infinity, printable_limit: :infinity) =~ canary

    # A call the page does not take (it defines no handle_call) crashes it;
    # its termination report prints its state.
    Process.flag(:trap_exit, true)
    ref = Process.monitor(view.pid)

    log =
      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        catch_exit(GenServer.call(view.pid, :crash_the_page, 5_000))
        assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
      end)

    assert log =~ "terminating"
    refute log =~ canary
  end

  test "Reset folder empties the program's own folder", %{conn: conn, athanor: athanor} do
    controller!()
    home = driven_row!(athanor).id

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("tr[phx-value-name=claude]") |> render_click()
    view |> element(~s([data-test="reset-folder"])) |> render_click()

    answered(view)

    assert_receive {:control, "home", %{"op" => "reset", "home_id" => ^home}, _fields}, 2_000
    assert flash(view, "info") == "The folder is empty again."
    assert render(view) =~ "Reset folder"
    refute render(view) =~ "Reset home"
  end

  test "the program form adds a kept driven program with its bounds once its definition is " <>
         "confirmed",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("button", "Add program") |> render_click()

    # A program's folder is its own: no other program's is offered.
    refute has_element?(view, ~s(form#add-program [name="login_entry"]))
    refute has_element?(view, ~s(form#add-program [name="backend"]))
    # No program is given a memory number: CYFR bounds every one alike.
    refute has_element?(view, ~s(form#add-program [name="memory_mib"]))

    view
    |> form("form#add-program", %{
      "name" => "claude",
      "command" => "npx -y @anthropic-ai/claude-code",
      "mark" => "driven",
      "home" => "kept",
      "disk_mib" => "2048"
    })
    |> render_submit()

    answered(view)

    # Nothing is made before the person confirms the whole definition.
    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx(athanor), "claude")

    assert %{
             "operation" => "mcp_servers.create",
             "resource" => "claude",
             "details" =>
               %{
                 "command" => "npx -y @anthropic-ai/claude-code",
                 "mark" => "driven",
                 "folder" => "new",
                 "hosts" => "every public host",
                 "home_max_bytes" => "2147483648",
                 "environment" => "none"
               } = details
           } = asked(user, athanor, "mcp_servers.create")

    refute Map.has_key?(details, "memory_bytes")

    assert has_element?(view, ~s([data-test="confirmation"]))
    confirm!(view, user, athanor, "mcp_servers.create")

    assert {:ok, row} = Arca.McpServerStorage.get(ctx(athanor), "claude")
    assert {row.transport, row.mark} == {"program", "driven"}
    assert row.home == "kept"
    refute Map.has_key?(row, :memory_bytes)
    assert row.home_max_bytes == 2048 * 1_048_576
    assert {:ok, []} = Arca.VaultStorage.list(ctx(athanor))

    # It was asked once; added from the form, it opens nothing by itself.
    assert open_confirmations(user, athanor) == []
    refute_received {:session, "open", _message, _fields}
    refute has_element?(view, ~s([data-test="terminal"]))

    # Its details show the bounds a row sets, and no memory one.
    view |> element("tr[phx-value-name=claude]") |> render_click()
    assert has_element?(view, ~s([data-test="program-settings"]), "Disk bound")
    refute has_element?(view, ~s([data-test="program-settings"]), "Memory")
  end

  test "Aqua's browser is added from its own definition, prefilled, and confirmed as any program is",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    {view, _html} = mount_athanor(conn, "/programs?add=browser&from=aqua", athanor)
    render(view)

    assert has_element?(view, ~s([data-test="add-browser"]), "asks you to confirm the program")
    assert has_element?(view, ~s(form#add-program input[name="name"][value="aqua-browser"]))
    assert has_element?(view, ~s(form#add-program input[name="command"][value="cyfr-browser"]))
    refute has_element?(view, ~s(form#add-program [name="memory_mib"]))
    assert has_element?(view, ~s(form#add-program input[name="disk_mib"][value="2048"]))

    view |> form("form#add-program", %{}) |> render_submit()
    answered(view)

    assert %{
             "details" =>
               %{
                 "command" => "cyfr-browser",
                 "mark" => "driven",
                 "folder" => "new",
                 "hosts" => "every public host",
                 "home_max_bytes" => "2147483648",
                 "environment" => "none"
               } = details
           } = asked(user, athanor, "mcp_servers.create")

    refute Map.has_key?(details, "memory_bytes")

    confirm!(view, user, athanor, "mcp_servers.create")

    assert {:ok, row} = Arca.McpServerStorage.get(ctx(athanor), "aqua-browser")
    assert Opus.Programs.Definition.browser?(row)
    # Its folder holds the profile; the Chromium it runs is the image's.
    assert row.home_max_bytes == 2 * 1024 * 1_048_576
    assert open_confirmations(user, athanor) == []
    refute_received {:session, "open", _message, _fields}
  end

  test "Aqua's second browser is added as the first is, under its own name and in a folder of its own",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    {view, _html} = mount_athanor(conn, "/programs?add=browser-apart&from=aqua", athanor)
    render(view)

    assert has_element?(view, ~s([data-test="add-browser-apart"]), "none of your sign-ins")
    refute has_element?(view, ~s([data-test="add-browser"]))
    assert has_element?(view, ~s(form#add-program input[name="name"][value="aqua-browser-apart"]))
    assert has_element?(view, ~s(form#add-program input[name="command"][value="cyfr-browser"]))

    view |> form("form#add-program", %{}) |> render_submit()
    answered(view)

    assert %{"details" => %{"command" => "cyfr-browser", "folder" => "new"}} =
             asked(user, athanor, "mcp_servers.create")

    confirm!(view, user, athanor, "mcp_servers.create")

    assert {:ok, row} = Arca.McpServerStorage.get(ctx(athanor), "aqua-browser-apart")
    assert Opus.Programs.Definition.browser?(row)
    assert {:ok, %{id: id}} = Opus.Browser.row(athanor.id, :apart)
    assert id == row.id
    assert {:error, :not_added} = Opus.Browser.row(athanor.id)
  end

  # A program brain the athanor has no row of: the install a card or the
  # setup offers opens the form prefilled from the brain's definition, its
  # name and its command. Installing it asks the person once, as any
  # program's addition does, then opens its terminal; a row of that name
  # that is there is opened, never offered again or replaced.
  test "an install of a program brain asks once, opens its terminal and never replaces a row " <>
         "of its name",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    brain = Opus.Programs.Definition.brain("claude-code")
    query = URI.encode_query(%{"add" => brain.name, "from" => "aqua"})
    {view, _html} = mount_athanor(conn, "/programs?" <> query, athanor)
    render(view)

    assert has_element?(
             view,
             ~s([data-test="install-from"]),
             "to run #{brain.title} as a brain. This is the program"
           )

    assert has_element?(view, ~s(form#add-program input[name="name"][value="#{brain.name}"]))

    assert has_element?(
             view,
             ~s(form#add-program input[name="command"][value="#{brain.command}"])
           )

    assert has_element?(
             view,
             ~s(form#add-program select[name="mark"] option[value="driven"][selected]),
             "driven: a person or a crew member runs it, such as a coding harness"
           )

    # Nothing is made before the person confirms it.
    view |> form("form#add-program", %{}) |> render_submit()
    answered(view)
    command = brain.command
    assert %{"details" => %{"command" => ^command}} = asked(user, athanor, "mcp_servers.create")
    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx(athanor), brain.name)

    confirm!(view, user, athanor, "mcp_servers.create")

    assert {:ok, %{id: home, mark: "driven", home: "kept", epoch: epoch} = row} =
             Arca.McpServerStorage.get(ctx(athanor), brain.name)

    assert_receive {:session, "open", %{"mode" => "terminal", "home_id" => ^home}, _fields},
                   2_000

    opened_session(view)
    assert open_confirmations(user, athanor) == []

    # The row of that name is there: the install opens it, offers no form
    # and changes nothing of it.
    {view, _html} = mount_athanor(conn, "/programs?" <> query, athanor)
    render(view)
    refute has_element?(view, "form#add-program")
    assert flash(view, "info") == "#{brain.name} is already on the Programs page."

    assert {:ok, %{id: ^home, epoch: ^epoch} = again} =
             Arca.McpServerStorage.get(ctx(athanor), brain.name)

    assert again.config_json == row.config_json
  end

  # Each program brain CYFR ships names its own row and its own command,
  # the driver first: its install prefills the form from its definition
  # alone, one path for every brain. A name CYFR ships no brain of opens
  # the same form under that name, with no command to suggest.
  test "each program brain's install prefills the form from its definition, and another name " <>
         "from nothing but its name",
       %{conn: conn, athanor: athanor} do
    brains = Enum.map(Opus.Programs.Definition.brains(), &{&1.name, &1.title, &1.command})

    for {name, title, command} <- brains ++ [{"notes-cli", "notes-cli", nil}] do
      query = URI.encode_query(%{"add" => name, "from" => "aqua"})
      {view, _html} = mount_athanor(conn, "/programs?" <> query, athanor)
      render(view)

      assert has_element?(
               view,
               ~s([data-test="install-from"]),
               "to run #{title} as a brain. This is the program"
             )

      assert has_element?(view, ~s(form#add-program input[name="name"][value="#{name}"]))

      if command do
        assert has_element?(view, ~s(form#add-program input[name="command"][value="#{command}"]))
      else
        assert has_element?(view, ~s(form#add-program input[name="command"]))

        refute has_element?(
                 view,
                 ~s|form#add-program input[name="command"][value]:not([value=""])|
               )
      end

      assert has_element?(
               view,
               ~s(form#add-program select[name="mark"] option[value="driven"][selected])
             )

      assert has_element?(
               view,
               ~s(form#add-program select[name="home"] option[value="kept"][selected])
             )

      assert {:error, :not_found} = Arca.McpServerStorage.get(ctx(athanor), name)
    end
  end

  # A removal is asked through the confirmation, which says what goes with
  # the program before it is given; a tool server's is the browser's.
  test "Remove asks before a program goes, saying its folder goes with it",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    row = driven_row!(athanor)
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("tr[phx-value-name=claude]") |> render_click()
    refute has_element?(view, ~s([data-test="remove-program"][data-confirm]))
    view |> element(~s([data-test="remove-program"])) |> render_click()
    answered(view)

    assert {:ok, _} = Arca.McpServerStorage.get(ctx(athanor), "claude")

    assert %{"details" => %{"folder" => folder, "grants_asking_again" => "none"}} =
             asked(user, athanor, "mcp_servers.delete")

    assert folder == row.id

    assert has_element?(
             view,
             ~s([data-test="confirmation-consequence"]),
             "Removing it ends its sessions and removes its folder with everything kept there. " <>
               "No grant uses it."
           )

    confirm!(view, user, athanor, "mcp_servers.delete")

    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx(athanor), "claude")
    assert flash(view, "info") == "'claude' removed."
  end

  test "a program whose stored hosts do not read is saved again from Edit, then removed",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    row = driven_row!(athanor)
    {:ok, _} = Arca.McpServerStorage.update(ctx(athanor), "claude", %{hosts: "not a list"})
    {:ok, broken} = Arca.McpServerStorage.get(ctx(athanor), "claude")
    assert {:error, _unread} = Sanctum.ToolServerDigest.recorded(broken)

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("tr[phx-value-name=claude]") |> render_click()
    view |> element(~s(button[data-test="edit"])) |> render_click()

    # The person types the hosts again and saves; it reaches more than a
    # list that does not read, so it is asked.
    view
    |> form("form#add-program", %{
      "command" => "npx -y @anthropic-ai/claude",
      "mark" => "driven",
      "home" => "kept",
      "hosts" => "api.anthropic.com"
    })
    |> render_submit()

    answered(view)

    assert %{"details" => %{"hosts" => ["api.anthropic.com"]}} =
             asked(user, athanor, "mcp_servers.update")

    confirm!(view, user, athanor, "mcp_servers.update")
    assert flash(view, "info") =~ "'claude' saved"

    assert {:ok, saved} = Arca.McpServerStorage.get(ctx(athanor), "claude")
    assert {saved.id, saved.hosts} == {row.id, ~s(["api.anthropic.com"])}
    assert {:ok, _record} = Sanctum.ToolServerDigest.recorded(saved)

    # Whole again, it is removed once its removal is confirmed.
    view |> element(~s([data-test="remove-program"])) |> render_click()
    answered(view)
    confirm!(view, user, athanor, "mcp_servers.delete")
    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx(athanor), "claude")
  end

  test "a program's hosts are set in its form, shown on its row and changed there",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("button", "Add program") |> render_click()

    # The form says what the list admits, a shared address among it.
    assert has_element?(view, ~s([data-test="hosts-help"]), "shares an address with another")

    view
    |> form("form#add-program", %{
      "name" => "fetch",
      "command" => "npx -y @modelcontextprotocol/server-fetch",
      "home" => "scratch",
      "hosts" => "api.example.com, registry.npmjs.org"
    })
    |> render_submit()

    answered(view)
    confirm!(view, user, athanor, "mcp_servers.create")

    assert {:ok, row} = Arca.McpServerStorage.get(ctx(athanor), "fetch")
    assert Jason.decode!(row.hosts) == ["api.example.com", "registry.npmjs.org"]

    view |> element("tr[phx-value-name=fetch]") |> render_click()

    assert has_element?(
             view,
             ~s([data-test="program-hosts"]),
             "api.example.com, registry.npmjs.org"
           )

    # Fewer hosts are a change to the definition, confirmed as any is.
    view |> form("form#hosts-fetch", %{"hosts" => "api.example.com"}) |> render_submit()
    answered(view)

    assert %{"details" => %{"hosts" => ["api.example.com"]}} =
             asked(user, athanor, "mcp_servers.update")

    confirm!(view, user, athanor, "mcp_servers.update")
    assert open_confirmations(user, athanor) == []
    assert {:ok, row} = Arca.McpServerStorage.get(ctx(athanor), "fetch")
    assert Jason.decode!(row.hosts) == ["api.example.com"]

    view |> form("form#hosts-fetch", %{"hosts" => "*.example.com"}) |> render_submit()
    answered(view)
    assert flash(view, "error") =~ "config.hosts"

    assert {:ok, %{hosts: ~s(["api.example.com"])}} =
             Arca.McpServerStorage.get(ctx(athanor), "fetch")

    # Every public host reaches more: it is asked, and saved once confirmed.
    view |> form("form#hosts-fetch", %{"hosts" => ""}) |> render_submit()
    answered(view)

    assert {:ok, %{hosts: ~s(["api.example.com"])}} =
             Arca.McpServerStorage.get(ctx(athanor), "fetch")

    confirm!(view, user, athanor, "mcp_servers.update")
    assert {:ok, %{hosts: nil}} = Arca.McpServerStorage.get(ctx(athanor), "fetch")
    assert has_element?(view, ~s([data-test="program-hosts"]), "every public host")
  end

  test "the list says each row's transport and folder", %{conn: conn, athanor: athanor} do
    driven_row!(athanor)

    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "webby",
        url: "https://127.0.0.1:9/mcp",
        enabled: false
      })

    {view, _html} = mount_athanor(conn, "/programs", athanor)

    assert has_element?(
             view,
             ~s(tr[data-name="claude"] [data-test="transport"]),
             "driven program"
           )

    assert has_element?(view, ~s(tr[data-name="claude"] [data-test="home"]), "kept")
    assert has_element?(view, ~s(tr[data-name="webby"] [data-test="transport"]), "http")

    # The column a person reads names a folder, never a home.
    assert has_element?(view, "thead th", "Folder")
    refute has_element?(view, "thead th", "Home")
  end

  test "Edit replaces a program's whole definition at the epoch it was read at and keeps its folder",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    row = driven_row!(athanor)
    {view, _html} = mount_athanor(conn, "/programs", athanor)

    view |> element("tr[phx-value-name=claude]") |> render_click()
    view |> element(~s(button[data-test="edit"])) |> render_click()

    # The form holds the definition as stored, the name fixed.
    assert has_element?(view, ~s([data-test="editing"]), "Its folder is kept")
    assert has_element?(view, ~s(form#add-program input[name="name"][disabled]))

    assert has_element?(
             view,
             ~s(form#add-program input[name="command"][value="npx -y @anthropic-ai/claude"])
           )

    assert has_element?(
             view,
             ~s(form#add-program select[name="mark"] option[value="driven"][selected])
           )

    assert has_element?(
             view,
             ~s(form#add-program select[name="home"] option[value="kept"][selected])
           )

    view
    |> form("form#add-program", %{
      "command" => "npx -y @anthropic-ai/claude-code@2.1.400",
      "mark" => "driven",
      "home" => "kept"
    })
    |> render_submit()

    answered(view)

    # Another command reaches more: it is saved once confirmed.
    assert %{"details" => %{"command" => "npx -y @anthropic-ai/claude-code@2.1.400"}} =
             asked(user, athanor, "mcp_servers.update")

    confirm!(view, user, athanor, "mcp_servers.update")

    assert flash(view, "info") =~ "'claude' saved"
    refute has_element?(view, "form#add-program")

    assert {:ok, saved} = Arca.McpServerStorage.get(ctx(athanor), "claude")
    assert saved.id == row.id
    assert saved.epoch == row.epoch + 1
    assert {saved.transport, saved.mark, saved.home} == {"program", "driven", "kept"}

    assert Arca.McpServerStorage.config(saved) == %{
             "command" => "npx -y @anthropic-ai/claude-code@2.1.400",
             "env" => %{},
             "timeout_ms" => 30_000
           }

    # The folder is the row's, untouched: no reset or retire sent.
    refute_received {:control, "home", _home, _fields}
  end

  # Every change to a program's definition is confirmed, a narrower one
  # too, and its confirmation says which grants will ask again.
  test "an Edit that only narrows is confirmed, saying which grants ask again, and a stale " <>
         "epoch is refused in the form",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()

    {:ok, row} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "gh",
        transport: "program",
        mark: "mcp",
        url: nil,
        enabled: false,
        home: "kept",
        home_max_bytes: 2_147_483_648,
        config_json: Jason.encode!(%{"command" => "gh mcp", "env" => %{}})
      })

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("tr[phx-value-name=gh]") |> render_click()
    view |> element(~s(button[data-test="edit"])) |> render_click()

    view |> form("form#add-program", %{"disk_mib" => "1024"}) |> render_submit()
    answered(view)

    assert %{"details" => %{"home_max_bytes" => "1073741824", "grants_asking_again" => "none"}} =
             asked(user, athanor, "mcp_servers.update")

    assert has_element?(view, ~s([data-test="confirmation-consequence"]), "No grant uses it.")
    assert {:ok, ^row} = Arca.McpServerStorage.get(ctx(athanor), "gh")

    confirm!(view, user, athanor, "mcp_servers.update")
    assert open_confirmations(user, athanor) == []
    assert {:ok, saved} = Arca.McpServerStorage.get(ctx(athanor), "gh")
    assert {saved.id, saved.home, saved.home_max_bytes} == {row.id, "kept", 1_073_741_824}

    # An edit opened before another change is refused, and changes nothing.
    view |> element(~s(button[data-test="edit"])) |> render_click()
    {:ok, _} = Arca.McpServerStorage.update(ctx(athanor), "gh", %{enabled: false})

    view |> form("form#add-program", %{"disk_mib" => "512"}) |> render_submit()

    html = answered(view)
    assert html =~ "Failed to save:"
    assert html =~ "changed since epoch"
    assert {:ok, %{home_max_bytes: 1_073_741_824}} = Arca.McpServerStorage.get(ctx(athanor), "gh")
  end

  test "a disabled program's details read as stopped: no program running, no tools",
       %{conn: conn, athanor: athanor} do
    controller!()

    {:ok, row} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "github",
        transport: "program",
        mark: "mcp",
        url: nil,
        config_json: Jason.encode!(%{"command" => "npx -y github", "env" => %{}})
      })

    on_exit(fn -> Emissary.External.ServerSupervisor.stop("github", athanor.id) end)

    # Connected first, so the row opens on a program the service runs.
    internal = Sanctum.Context.internal(athanor_id: athanor.id, scope: :athanor)
    assert {:ok, [_tool]} = Emissary.External.Servers.ensure_started(row, internal)

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("tr[phx-value-name=github]") |> render_click()

    assert has_element?(view, ~s([data-test="program-status"]))
    assert render(view) =~ "Discovered Tools (1)"

    view |> element("button", "Disable") |> render_click()
    answered(view)

    refute has_element?(view, ~s([data-test="program-status"]))
    refute render(view) =~ "Discovered Tools"
    assert has_element?(view, ~s(tr[data-name="github"] [data-test="status"]), "disabled")
    refute has_element?(view, ~s(tr[data-name="github"] [data-test="status"]), "stopped")
    assert has_element?(view, "button", "Enable")
  end

  test "the list says a connected program starts when used while nothing of it holds memory",
       %{conn: conn, athanor: athanor} do
    controller!()

    {:ok, row} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "github",
        transport: "program",
        mark: "mcp",
        url: nil,
        config_json: Jason.encode!(%{"command" => "npx -y github", "env" => %{}})
      })

    on_exit(fn -> Emissary.External.ServerSupervisor.stop("github", athanor.id) end)

    internal = Sanctum.Context.internal(athanor_id: athanor.id, scope: :athanor)
    assert {:ok, [_tool]} = Emissary.External.Servers.ensure_started(row, internal)
    assert %{status: :ready} = Emissary.External.Server.status("github", athanor.id)

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    status = view |> element(~s(tr[data-name="github"] [data-test="status"])) |> render()

    assert status =~ "starts when used"
    refute status =~ "ready"
  end

  test "a disabled program a person runs reads as disabled and offers no Open; its terminal says why it ended",
       %{conn: conn, athanor: athanor, user: user} do
    {_fake, controller} = box!()
    row = driven_row!(athanor)

    {:ok, session} =
      Opus.Programs.start(person(user, athanor), row.id, %{rows: 24, cols: 80, args: []})

    {view, _html} = mount_athanor(conn, "/programs?terminal=#{session}", athanor)
    ready!(view, session)
    view |> element("tr[phx-value-name=claude]") |> render_click()

    assert has_element?(view, ~s([data-test="open-terminal"]))
    refute has_element?(view, ~s(tr[data-name="claude"] [data-test="status"]), "disabled")

    # A terminal of it is listed, so the row's Disable asks first, though
    # no read names the program yet.
    assert question(view, ~s([data-test="toggle-enabled"])) ==
             "Disable claude? Everything running in it ends now, and work in its terminals is lost."

    view |> element(~s([data-test="toggle-enabled"])) |> render_click()
    answered(view)

    assert has_element?(view, ~s(tr[data-name="claude"] [data-test="status"]), "disabled")
    refute has_element?(view, ~s([data-test="open-terminal"]))

    assert view |> element(~s([data-test="open-disabled"])) |> render() =~
             "This program is disabled. Enable it to open a terminal."

    # The controller's next check of its rows ends what the row ran.
    assert eventually(fn ->
             send(controller, :tick)

             has_element?(
               view,
               ~s([data-test="terminal-ended"]),
               "CYFR ended the program. The Programs page shows whether it can be opened again."
             )
           end)
  end

  # A kept mcp program carrying every field a definition holds, among them
  # what the program form does not show and a bound of no whole MiB.
  defp full_program!(user, athanor) do
    entry!(user, athanor, "gh", %{"hosts" => ["api.github.com"]}, true)

    {:ok, row} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "gh",
        transport: "program",
        mark: "mcp",
        url: nil,
        enabled: false,
        home: "kept",
        home_max_bytes: 16_777_217,
        hosts: Jason.encode!(["api.github.com", "github.com"]),
        config_json:
          Jason.encode!(%{
            "command" => "gh mcp",
            "env" => %{"GH_TOKEN" => "vault:gh", "NODE_ENV" => "production"},
            "timeout_ms" => 60_000,
            "tool_patterns" => ["search"],
            "console" => true
          })
      })

    row
  end

  test "an Edit saved with nothing changed writes nothing, for a definition carrying every field",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    before = full_program!(user, athanor)
    {:ok, before} = Arca.McpServerStorage.get(ctx(athanor), before.name)
    {view, _html} = mount_athanor(conn, "/programs", athanor)

    view |> element("tr[phx-value-name=gh]") |> render_click()
    view |> element(~s(button[data-test="edit"])) |> render_click()

    # The bound of no whole MiB is shown exactly.
    assert has_element?(
             view,
             ~s(form#add-program input[name="disk_mib"][value="16777217 bytes"])
           )

    view |> form("form#add-program", %{}) |> render_submit()

    assert flash(view, "info") == "Nothing changed in 'gh'."
    refute has_element?(view, "form#add-program")
    assert {:ok, ^before} = Arca.McpServerStorage.get(ctx(athanor), "gh")
  end

  test "an Edit keeps every field the form does not show, exactly",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    before = full_program!(user, athanor)
    {view, _html} = mount_athanor(conn, "/programs", athanor)

    view |> element("tr[phx-value-name=gh]") |> render_click()
    view |> element(~s(button[data-test="edit"])) |> render_click()
    view |> form("form#add-program", %{"command" => "gh mcp --read-only"}) |> render_submit()
    answered(view)
    confirm!(view, user, athanor, "mcp_servers.update")

    assert {:ok, saved} = Arca.McpServerStorage.get(ctx(athanor), "gh")
    assert saved.epoch == before.epoch + 1

    assert Map.take(saved, [
             :mark,
             :home,
             :home_max_bytes,
             :hosts
           ]) ==
             Map.take(before, [
               :mark,
               :home,
               :home_max_bytes,
               :hosts
             ])

    assert Arca.McpServerStorage.config(saved) == %{
             "command" => "gh mcp --read-only",
             "env" => %{"GH_TOKEN" => "vault:gh", "NODE_ENV" => "production"},
             "timeout_ms" => 60_000,
             "tool_patterns" => ["search"],
             "console" => true
           }
  end

  # A tool server elsewhere holding a literal header, a vault-bound one and
  # members the form does not show.
  defp tool_server!(user, athanor) do
    entry!(user, athanor, "local-key", %{"hosts" => ["127.0.0.1"], "port" => 9})

    {:ok, row} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "relay",
        url: "https://127.0.0.1:9/mcp",
        enabled: false,
        config_json:
          Jason.encode!(%{
            "headers" => %{"X-Hub" => "hub-literal-0123", "Authorization" => "vault:local-key"},
            "timeout_ms" => 45_000,
            "tool_patterns" => ["search"],
            "console" => true
          })
      })

    row
  end

  # A tool server elsewhere is deleted on the browser's question, which
  # names the grant of its tools that will ask again; the delete blocks it.
  test "Delete on a tool server names the grants of its tools, which ask again once it is gone",
       %{conn: conn, athanor: athanor, user: user} do
    tool_server!(user, athanor)
    source = "reagent:local.relay-user"
    granted = Sanctum.Context.internal(athanor_id: athanor.id, scope: :athanor)

    :ok =
      Sanctum.Test.ConsentFixtures.seed_head!(
        granted,
        %{
          id: "prof_relay_user",
          kind: :owner,
          source_ref: source,
          label: "default",
          status: :active
        },
        %{
          id: "cons_relay_user",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          resolved_policy:
            Jason.encode!(%{
              "canonical" => "jcs-1",
              "nodes" => %{
                source => %{
                  "limits" => Prima.Test.AuthorityFixtures.limits_map(),
                  "edges" => %{
                    "@ingress" => %{
                      "tool_servers" => [
                        %{
                          "server_digest" => "sha256:relay",
                          "server_name" => "relay",
                          "tool_patterns" => ["search"],
                          "record" => %{"address" => "https://127.0.0.1:9/mcp", "headers" => []}
                        }
                      ]
                    }
                  }
                }
              }
            }),
          activation: %{source => "sha256:act"}
        }
      )

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("tr[phx-value-name=relay]") |> render_click()

    assert has_element?(
             view,
             ~s([data-test="delete-server"][data-confirm="Delete this row? ) <>
               ~s(The one grant that uses it will ask again: #{source}."])
           )

    view |> element(~s([data-test="delete-server"])) |> render_click()
    answered(view)

    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx(athanor), "relay")
    assert open_confirmations(user, athanor) == []

    assert {:ok, %{status: "needs_consent"}} =
             Arca.ProfileStorage.get(ctx(athanor), "prof_relay_user")
  end

  defp edit_relay(view) do
    view |> element("tr[phx-value-name=relay]") |> render_click()
    view |> element(~s(button[data-test="edit"])) |> render_click()
  end

  test "Edit on a tool server shows its address and headers, a literal as [set] and never its value",
       %{conn: conn, athanor: athanor, user: user} do
    tool_server!(user, athanor)
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    html = edit_relay(view)

    assert has_element?(
             view,
             ~s(form#edit-server input[name="url"][value="https://127.0.0.1:9/mcp"])
           )

    assert view |> element("form#edit-server textarea[name=headers]") |> render() =~
             "Authorization: vault:local-key\nX-Hub: [set]"

    refute html =~ "hub-literal-0123"
    refute render(view) =~ "hub-literal-0123"
  end

  test "an Edit of a tool server keeps a [set] header's stored value and every unshown member",
       %{conn: conn, athanor: athanor, user: user} do
    before = tool_server!(user, athanor)
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    edit_relay(view)

    view |> form("form#edit-server", %{"url" => "https://127.0.0.1:9/mcp/v2"}) |> render_submit()
    answered(view)

    assert flash(view, "info") =~ "'relay' saved"
    assert {:ok, saved} = Arca.McpServerStorage.get(ctx(athanor), "relay")

    assert {saved.id, saved.url, saved.epoch} ==
             {before.id, "https://127.0.0.1:9/mcp/v2", before.epoch + 1}

    assert Arca.McpServerStorage.config(saved) == %{
             "headers" => %{"X-Hub" => "hub-literal-0123", "Authorization" => "vault:local-key"},
             "timeout_ms" => 45_000,
             "tool_patterns" => ["search"],
             "console" => true
           }
  end

  test "an Edit of a tool server takes a typed value in place of [set], and one saved as read writes nothing",
       %{conn: conn, athanor: athanor, user: user} do
    tool_server!(user, athanor)
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    edit_relay(view)

    view |> form("form#edit-server", %{}) |> render_submit()
    assert flash(view, "info") == "Nothing changed in 'relay'."
    {:ok, unchanged} = Arca.McpServerStorage.get(ctx(athanor), "relay")

    # The row stays open; Edit opens the form again.
    view |> element(~s(button[data-test="edit"])) |> render_click()

    view
    |> form("form#edit-server", %{
      "headers" => "Authorization: vault:local-key\nX-Hub: hub-literal-new"
    })
    |> render_submit()

    answered(view)

    assert {:ok, saved} = Arca.McpServerStorage.get(ctx(athanor), "relay")
    assert saved.epoch == unchanged.epoch + 1
    assert Arca.McpServerStorage.config(saved)["headers"]["X-Hub"] == "hub-literal-new"
  end

  test "a kept literal an upstream echoes after an Edit reaches neither the answer, the flash nor the log, eight bytes or more",
       %{conn: conn, athanor: athanor} do
    stub = HTTPStub.open()

    HTTPStub.stub(stub, "POST", "/v2", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [hub] = Plug.Conn.get_req_header(conn, "x-hub")
      [short] = Plug.Conn.get_req_header(conn, "x-short")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "error" => %{"code" => -32001, "message" => "rejected headers #{hub} #{short}"}
        })
      )
    end)

    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "relay",
        url: "http://127.0.0.1:#{stub.port}/mcp",
        enabled: false,
        config_json:
          Jason.encode!(%{"headers" => %{"X-Hub" => "hub-literal-0123", "X-Short" => "seven77"}})
      })

    {:ok, _} = Arca.McpServerStorage.update(ctx(athanor), "relay", %{enabled: true})
    on_exit(fn -> Emissary.External.ServerSupervisor.stop("relay", athanor.id) end)

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("tr[phx-value-name=relay]") |> render_click()
    view |> element(~s(button[data-test="edit"])) |> render_click()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        view
        |> form("form#edit-server", %{"url" => "http://127.0.0.1:#{stub.port}/v2"})
        |> render_submit()

        html = answered(view)
        refute html =~ "hub-literal-0123"
      end)

    # The masker's stated limit: a stored value under eight bytes is shown as
    # the upstream sent it (a secret belongs in a vault entry).
    assert flash(view, "error") == "'relay' saved — rejected headers [REDACTED] seven77"
    refute log =~ "hub-literal-0123"
    assert log =~ "[REDACTED] seven77"

    {:ok, saved} = Arca.McpServerStorage.get(ctx(athanor), "relay")

    assert Arca.McpServerStorage.config(saved)["headers"] == %{
             "X-Hub" => "hub-literal-0123",
             "X-Short" => "seven77"
           }
  end

  describe "memory in use now" do
    @mib 1_048_576
    @boot String.duplicate("e", 32)

    # A page of the record as the poller stores it, under the cell's
    # claim, for one endpoint.
    defp recorded!(counters, names \\ %{}, endpoint \\ "wrk_page") do
      {:ok, claim} =
        Arca.JobClaims.claim("memory", Arca.JobClaims.cell_key(), "boot_page", 60_000)

      report = %{
        boot: @boot,
        budget: 8_000 * @mib,
        work: 4_800 * @mib,
        floor: 164 * @mib,
        used: 1_000 * @mib,
        counters: counters,
        next: nil
      }

      {:ok, rows} = Arca.MemoryRecord.endpoints(Prima.Actor.system(), Prima.LocusPool.fresh_ms())

      after_rev =
        case Enum.find(rows, &(&1.endpoint == endpoint)) do
          %{after: after_rev} -> after_rev
          nil -> 0
        end

      {:ok, _stored} =
        Arca.MemoryRecord.store(claim, :none, endpoint, after_rev, report, names, 90)

      :ok
    end

    defp held(rev, athanor, kind, subject, mib) do
      %{
        rev: rev,
        day: Date.utc_today(),
        athanor: athanor.id,
        kind: kind,
        subject: subject,
        bytes: mib * @mib,
        mib_ms: 0,
        measured_ms: 0,
        peak_bytes: mib * @mib,
        cap: 0,
        machine: 0,
        either: 0
      }
    end

    # Another person with a program of their own, signed in apart.
    defp other_person! do
      other = test_user()
      _conn = log_in_user(build_conn(), other)
      athanor = seated_athanor()
      {athanor, driven_row!(athanor, "their-secret-tool")}
    end

    test "names the person's own holders with the controls they have, and everyone else's as one sum",
         %{conn: conn, athanor: athanor, user: user} do
      _fake = controller!()
      row = driven_row!(athanor)

      {:ok, session} =
        Opus.Programs.start(person(user, athanor), row.id, %{rows: 24, cols: 80, args: []})

      {theirs, their_row} = other_person!()

      recorded!(
        [
          held(1, athanor, "program", row.id, 300),
          held(2, athanor, "run", nil, 164),
          held(3, theirs, "program", their_row.id, 500)
        ],
        %{
          {athanor.id, row.id} => %{name: "claude", shown: "program"},
          {theirs.id, their_row.id} => %{name: "their-secret-tool", shown: "program"}
        }
      )

      {view, _html} = mount_athanor(conn, "/programs", athanor)
      panel = view |> element(~s([data-test="memory"])) |> render()

      assert panel =~ "Memory in use now"
      assert panel =~ "claude uses 300.0 MB"
      assert panel =~ "A run uses 164.0 MB"
      assert panel =~ "Others use 500.0 MB."
      assert panel =~ "Counted a few seconds ago."
      refute panel =~ "their-secret-tool"
      refute panel =~ "Machine "
      PrismWeb.Vocabulary.refute_vocabulary(panel)

      # The run has no control; the program has its row's Disable and its
      # session's Close.
      assert has_element?(view, ~s([data-test="memory-disable"][phx-value-name="claude"]))
      assert panel |> String.split(~s(data-test="memory-disable")) |> length() == 2
      assert panel |> String.split(~s(data-test="memory-close")) |> length() == 2

      view
      |> element(~s([data-test="memory-close"][phx-value-session="#{session}"]))
      |> render_click()

      assert_receive {:session, "close", _message, _fields}, 2_000
    end

    test "three terminals of one program are a line each, told apart by their start, with no size of their own",
         %{conn: conn, athanor: athanor, user: user} do
      _fake = controller!()
      row = driven_row!(athanor)
      me = person(user, athanor)

      for _n <- 1..3,
          do: {:ok, _session} = Opus.Programs.start(me, row.id, %{rows: 24, cols: 80, args: []})

      {:ok, [first, second, third] = running} = Opus.Programs.running(me)

      recorded!([held(1, athanor, "terminal", row.id, 213)], %{
        {athanor.id, row.id} => %{name: "claude", shown: "program"}
      })

      {view, _html} = mount_athanor(conn, "/programs", athanor)
      panel = view |> element(~s([data-test="memory"])) |> render()

      assert panel =~ "claude uses 213.0 MB"

      assert view |> element(~s([data-test="memory-terminals"])) |> render() =~
               "All of that is its terminals. CYFR does not measure each one."

      refute panel =~ "terminals use"
      refute panel =~ "The rest is"
      refute panel =~ "Running since"

      # A line each, oldest first, none with a size of its own.
      lines =
        panel
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-test="memory-session"]))
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

      assert lines ==
               for(
                 s <- running,
                 do:
                   "Terminal opened at #{Calendar.strftime(s.started_at, "%H:%M:%S UTC")} Show Close"
               )

      for s <- running do
        assert has_element?(
                 view,
                 ~s([data-test="memory-close"][phx-value-session="#{s.session}"])
               )
      end

      # Show brings one into the frame, and its line then says which it is.
      view
      |> element(~s([data-test="memory-show"][phx-value-session="#{second.session}"]))
      |> render_click()

      assert has_element?(view, ~s([data-test="terminal"]))

      shown =
        view
        |> element(~s([data-test="memory-session"]), "shown above")
        |> render()

      assert shown =~ ~s(phx-value-session="#{second.session}")

      refute has_element?(
               view,
               ~s([data-test="memory-show"][phx-value-session="#{second.session}"])
             )

      assert has_element?(
               view,
               ~s([data-test="memory-show"][phx-value-session="#{first.session}"])
             )

      assert has_element?(
               view,
               ~s([data-test="memory-show"][phx-value-session="#{third.session}"])
             )

      # Disable asks first, of the whole program, and counts nothing.
      assert question(view, ~s([data-test="memory-disable"])) ==
               "Disable claude? Everything running in it ends now, and work in its terminals is lost."
    end

    test "a tool with a terminal says which part its terminals are, and no session carries a size",
         %{conn: conn, athanor: athanor, user: user} do
      _fake = controller!()

      {:ok, row} =
        Arca.McpServerStorage.insert(ctx(athanor), %{
          cap: 0,
          name: "everything",
          transport: "program",
          mark: "mcp",
          url: nil,
          config_json: Jason.encode!(%{"command" => "npx -y everything", "env" => %{}})
        })

      {:ok, session} =
        Opus.Programs.start(person(user, athanor), row.id, %{rows: 24, cols: 80, args: []})

      {:ok, [%{started_at: started_at}]} = Opus.Programs.running(person(user, athanor))

      recorded!(
        [
          held(1, athanor, "program", row.id, 247),
          held(2, athanor, "terminal", row.id, 233)
        ],
        %{{athanor.id, row.id} => %{name: "everything", shown: "tool"}}
      )

      {view, _html} = mount_athanor(conn, "/programs", athanor)
      panel = view |> element(~s([data-test="memory"])) |> render()

      assert panel =~ "everything uses 480.0 MB"

      assert view |> element(~s([data-test="memory-terminals"])) |> render() =~
               "Its terminals use 233.0 MB of that. CYFR does not measure each one. " <>
                 "The rest is the mcp program itself, which Close does not end."

      # The terminals' size is the program's in the athanor, never this
      # session's: its line is its start and its controls.
      line =
        view
        |> element(~s([data-test="memory-session"]))
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.split()
        |> Enum.join(" ")

      assert line ==
               "Terminal opened at #{Calendar.strftime(started_at, "%H:%M:%S UTC")} Show Close"

      assert has_element?(view, ~s([data-test="memory-close"][phx-value-session="#{session}"]))
      refute panel =~ "only Disable"

      assert question(view, ~s([data-test="memory-disable"])) ==
               "Disable everything? Everything running in it ends now, and work in its terminals is lost."
    end

    test "Disable asks on both buttons whenever the read names the program, and nothing when nothing of it runs",
         %{conn: conn, athanor: athanor} do
      _fake = controller!()
      row = driven_row!(athanor)

      {view, _html} = mount_athanor(conn, "/programs", athanor)
      view |> element("tr[phx-value-name=claude]") |> render_click()

      # Nothing of it runs: no line in the panel, and the row's Disable asks nothing.
      refute has_element?(view, ~s([data-test="memory-disable"]))
      assert question(view, ~s([data-test="toggle-enabled"])) == nil

      # The read names it, with a terminal of someone else's in the athanor
      # and none of this person's listed: both buttons ask, of the whole
      # program, and the terminals' size stays at the program's level.
      recorded!(
        [
          held(1, athanor, "program", row.id, 300),
          held(2, athanor, "terminal", row.id, 50)
        ],
        %{{athanor.id, row.id} => %{name: "claude", shown: "program"}}
      )

      send(view.pid, :memory)

      assert view |> element(~s([data-test="memory"])) |> render() =~ "claude uses 350.0 MB"

      assert view |> element(~s([data-test="memory-terminals"])) |> render() =~
               "Its terminals use 50.0 MB of that. CYFR does not measure each one. " <>
                 "The rest is the program itself, which Close does not end."

      refute has_element?(view, ~s([data-test="memory-session"]))

      asked =
        "Disable claude? Everything running in it ends now, and work in its terminals is lost."

      assert question(view, ~s([data-test="memory-disable"])) == asked
      assert question(view, ~s([data-test="toggle-enabled"])) == asked
    end

    # A connected mcp program named github: CYFR is ready to call it.
    defp ready_tool!(athanor) do
      {:ok, row} =
        Arca.McpServerStorage.insert(ctx(athanor), %{
          cap: 0,
          name: "github",
          transport: "program",
          mark: "mcp",
          url: nil,
          config_json: Jason.encode!(%{"command" => "npx -y github", "env" => %{}})
        })

      on_exit(fn -> Emissary.External.ServerSupervisor.stop("github", athanor.id) end)

      internal = Sanctum.Context.internal(athanor_id: athanor.id, scope: :athanor)
      assert {:ok, [_tool]} = Emissary.External.Servers.ensure_started(row, internal)
      row
    end

    defp list_status(view),
      do:
        view
        |> element(~s(tr[data-name="github"] [data-test="status"]))
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.trim()

    test "the list says a program runs while the panel names it, and starts when used once it does not",
         %{conn: conn, athanor: athanor} do
      controller!()
      row = ready_tool!(athanor)
      names = %{{athanor.id, row.id} => %{name: "github", shown: "tool"}}

      recorded!([held(1, athanor, "program", row.id, 247)], names)

      {view, _html} = mount_athanor(conn, "/programs", athanor)

      assert view |> element(~s([data-test="memory"])) |> render() =~ "github uses 247.0 MB"
      assert list_status(view) == "running"

      # The program holds nothing any more: the next read names it no longer.
      recorded!([held(2, athanor, "program", row.id, 0)], names)
      send(view.pid, :memory)

      refute view |> element(~s([data-test="memory"])) |> render() =~ "github uses"
      assert list_status(view) == "starts when used"
    end

    test "the list says a program starts when used while the service that runs it has not answered",
         %{conn: conn, athanor: athanor} do
      controller!()
      row = ready_tool!(athanor)

      recorded!([held(1, athanor, "program", row.id, 247)], %{
        {athanor.id, row.id} => %{name: "github", shown: "tool"}
      })

      an_hour_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)
      Arca.Repo.update_all(Arca.Schemas.MemoryEndpoint, set: [heard_at: an_hour_ago])

      {view, _html} = mount_athanor(conn, "/programs", athanor)
      panel = view |> element(~s([data-test="memory"])) |> render()

      assert panel =~ "What uses memory cannot be counted right now."
      refute panel =~ "github uses"
      assert list_status(view) == "starts when used"
    end

    test "a person with nothing of theirs held reads only that, and the others' sum",
         %{conn: conn, athanor: athanor} do
      {theirs, their_row} = other_person!()

      recorded!([held(1, theirs, "program", their_row.id, 500)], %{
        {theirs.id, their_row.id} => %{name: "their-secret-tool", shown: "program"}
      })

      {view, _html} = mount_athanor(conn, "/programs", athanor)
      panel = view |> element(~s([data-test="memory"])) |> render()

      assert panel =~ "Nothing of yours uses memory now."
      assert panel =~ "Others use 500.0 MB."
      refute panel =~ "their-secret-tool"
    end

    test "a machine that has not answered within three polls says when it was counted, and holds nothing of theirs now",
         %{conn: conn, athanor: athanor} do
      recorded!([held(1, athanor, "build", nil, 600)])
      an_hour_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)
      Arca.Repo.update_all(Arca.Schemas.MemoryEndpoint, set: [heard_at: an_hour_ago])

      {view, _html} = mount_athanor(conn, "/programs", athanor)
      panel = view |> element(~s([data-test="memory"])) |> render()

      refute panel =~ "A build uses"
      refute panel =~ "Nothing of yours uses memory now."

      assert panel =~
               "What uses memory cannot be counted right now. " <>
                 "It was last counted at #{Calendar.strftime(an_hour_ago, "%H:%M UTC")}."

      refute panel =~ "a few seconds ago"
    end

    test "a service that has not answered beside one that has, on one boot, is no machine of its own",
         %{conn: conn, athanor: athanor} do
      recorded!([held(1, athanor, "build", nil, 600)])
      recorded!([], %{}, "local")
      an_hour_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)

      require Ecto.Query

      Arca.Repo.update_all(Ecto.Query.where(Arca.Schemas.MemoryEndpoint, endpoint: "local"),
        set: [heard_at: an_hour_ago]
      )

      {view, _html} = mount_athanor(conn, "/programs", athanor)
      panel = view |> element(~s([data-test="memory"])) |> render()

      refute panel =~ "Machine"
      assert panel =~ "A build uses 600.0 MB"
      assert panel =~ "Counted a few seconds ago."

      assert panel =~
               "Some of it cannot be counted right now; that part was last counted at " <>
                 "#{Calendar.strftime(an_hour_ago, "%H:%M UTC")}."
    end

    test "a line keeps its place when its size passes another's",
         %{conn: conn, athanor: athanor} do
      zed = driven_row!(athanor, "zed")
      abe = driven_row!(athanor, "abe")

      names = %{
        {athanor.id, zed.id} => %{name: "zed", shown: "program"},
        {athanor.id, abe.id} => %{name: "abe", shown: "program"}
      }

      recorded!(
        [
          held(1, athanor, "build", nil, 900),
          held(2, athanor, "program", zed.id, 600),
          held(3, athanor, "run", nil, 300),
          held(4, athanor, "program", abe.id, 100)
        ],
        names
      )

      {view, _html} = mount_athanor(conn, "/programs", athanor)

      lines = fn ->
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-test="memory-holder"] > span:first-child))
        |> Enum.map(&LazyHTML.text/1)
      end

      assert lines.() == [
               "abe uses 100.0 MB",
               "zed uses 600.0 MB",
               "A run uses 300.0 MB",
               "A build uses 900.0 MB"
             ]

      recorded!(
        [
          held(5, athanor, "build", nil, 100),
          held(6, athanor, "program", zed.id, 50),
          held(7, athanor, "run", nil, 1_000),
          held(8, athanor, "program", abe.id, 800)
        ],
        names
      )

      send(view.pid, :memory)

      assert lines.() == [
               "abe uses 800.0 MB",
               "zed uses 50.0 MB",
               "A run uses 1000.0 MB",
               "A build uses 100.0 MB"
             ]
    end

    test "before the first read it says nothing of theirs, and a read that fails says it cannot be read",
         %{conn: conn, athanor: athanor} do
      # The mount's own render is served before the first read's message.
      {:ok, view, html} = live(conn, PrismWeb.ConnCase.athanor_path("/programs", athanor))

      assert html =~ "Memory in use now"
      refute html =~ "Nothing of yours uses memory now."
      refute html =~ "cannot be read"

      assert view |> element(~s([data-test="memory"])) |> render() =~
               "Nothing of yours uses memory now."

      Arca.Repo.query!("ALTER TABLE memory_endpoints RENAME TO memory_endpoints_unavailable")

      try do
        ExUnit.CaptureLog.capture_log(fn ->
          send(view.pid, :memory)
          panel = view |> element(~s([data-test="memory"])) |> render()

          assert panel =~ "Memory in use cannot be read right now."
          refute panel =~ "Nothing of yours uses memory now."
        end)
      after
        Arca.Repo.query!("ALTER TABLE memory_endpoints_unavailable RENAME TO memory_endpoints")
      end
    end
  end
end
