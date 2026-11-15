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
  from a component's login need and opens the program's terminal in the
  row's folder once the install is confirmed. A program opens on a
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
        "the command line, where every process on the backends service, other athanors' " <>
        "programs included, can read it; the safe route is to let the program read it from " <>
        "its environment."

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
  # Authorization header it was sent: at `tools/list` for a current peer,
  # and at `initialize` for one that answers the current probe as a legacy
  # peer does.
  defp echo_upstream(stub, era) do
    HTTPStub.stub(stub, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [auth] = Plug.Conn.get_req_header(conn, "authorization")

      case {era, request["method"]} do
        {:legacy, "tools/list"} ->
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

  # A catalyst that runs a program with the person's own sign-in.
  defp harness!(athanor) do
    ctx = Sanctum.Context.internal(user_id: "_test", athanor_id: athanor.id, scope: :athanor)

    manifest = %{
      "name" => "harness",
      "type" => "catalyst",
      "version" => "1.0.0",
      "publisher" => "local",
      "needs" => %{
        "claude" => %{
          "type" => "login",
          "program" => "claude",
          "reason" => "to run Claude Code on your own plan",
          "install" => %{"command" => "npx -y @anthropic-ai/claude-code@2.1.316"}
        }
      }
    }

    # Laid in this athanor alone, never in the run's shared seed tree, so
    # no other test's athanor reads it through.
    unit =
      Arca.Test.UnitFixtures.tenant_component!(ctx, "catalyst", "local", "harness", "1.0.0",
        manifest: manifest,
        wasm: Cyfr.Test.Guests.wasm(:catalyst)
      )

    {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)
    "catalyst:local.harness:1.0.0"
  end

  test "an install opens the program form prefilled from the component's login need",
       %{conn: conn, athanor: athanor} do
    ref = harness!(athanor)
    query = URI.encode_query(%{"install" => ref, "need" => "claude"})
    {view, _html} = mount_athanor(conn, "/programs?" <> query, athanor)
    html = render(view)

    assert has_element?(
             view,
             ~s([data-test="install-from"]),
             "to run Claude Code on your own plan"
           )

    assert has_element?(view, ~s(form#add-program input[name="name"][value="claude"]))

    assert has_element?(
             view,
             ~s(form#add-program input[name="command"][value="npx -y @anthropic-ai/claude-code@2.1.316"])
           )

    refute has_element?(view, ~s(form#add-program input[name="login_command"]))

    assert html =~ "Install"
  end

  test "an install naming no login need of the component says so", %{conn: conn, athanor: athanor} do
    ref = harness!(athanor)
    query = URI.encode_query(%{"install" => ref, "need" => "codex"})
    {view, _html} = mount_athanor(conn, "/programs?" <> query, athanor)
    render(view)

    assert flash(view, "error") == "#{ref} declares no login need named 'codex' to install from."
    refute has_element?(view, "form#add-program")
  end

  alias Cyfr.Test.ScriptedBackends, as: Scripted

  # The programs controller on a scripted backends service, put back
  # however the test ends.
  defp controller! do
    on_exit(fn ->
      :persistent_term.erase({Arca.ControlPlane, :generation})
      Arca.ControlPlane.record(:unclaimed)
    end)

    fake = Scripted.start(self(), @root)
    Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "reconcile", _reconcile, _fields}, 2_000
    fake
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
    view |> form("form#open-#{name}", %{"args" => args}) |> render_submit()
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

  defp output!(view, session) do
    assert_push_event(view, "terminal_output", %{session: ^session, data: data}, 2_000)
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

    assert_receive {:session, "open",
                    %{
                      "mode" => "terminal",
                      "key" => ^session,
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
    assert has_element?(view, ~s([data-test="terminal-ended"]), "The program was closed.")
    assert {:ok, []} = Opus.Programs.running(person(user, athanor))
  end

  defp terminal_pid(session) do
    [{pid, _person}] = Registry.lookup(Opus.Programs.Registry, {:terminal, session})
    pid
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
  end

  test "opened from Aqua's card, the terminal offers the way back to Aqua",
       %{conn: conn, athanor: athanor} do
    controller!()
    row = driven_row!(athanor)
    home = row.id

    {view, _html} = mount_athanor(conn, "/programs?open=claude&from=aqua", athanor)
    answered(view)
    path = assert_patch(view, @answered_ms)
    assert %{"terminal" => _session, "from" => "aqua"} = URI.decode_query(URI.parse(path).query)
    assert_receive {:session, "open", %{"home_id" => ^home, "argv" => []}, _fields}, 2_000

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
    message = {Opus.Programs, session, {:bytes, Opus.Programs.Output.new(canary)}}
    refute inspect(message, limit: :infinity, printable_limit: :infinity) =~ canary

    # A call the page does not take (it defines no handle_call) crashes it;
    # its termination report prints its state.
    Process.flag(:trap_exit, true)
    ref = Process.monitor(view.pid)

    log =
      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        catch_exit(GenServer.call(view.pid, :crash_the_page, 5_000))
        assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
        Process.sleep(200)
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

    view
    |> form("form#add-program", %{
      "name" => "claude",
      "command" => "npx -y @anthropic-ai/claude-code",
      "mark" => "driven",
      "home" => "kept",
      "memory_mib" => "1024",
      "disk_mib" => "2048"
    })
    |> render_submit()

    answered(view)

    # Nothing is made before the person confirms the whole definition.
    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx(athanor), "claude")

    assert %{
             "operation" => "mcp_servers.create",
             "resource" => "claude",
             "details" => %{
               "command" => "npx -y @anthropic-ai/claude-code",
               "mark" => "driven",
               "folder" => "new",
               "hosts" => "every public host",
               "memory_bytes" => "1073741824",
               "home_max_bytes" => "2147483648",
               "environment" => "none"
             }
           } = asked(user, athanor, "mcp_servers.create")

    assert has_element?(view, ~s([data-test="confirmation"]))
    confirm!(view, user, athanor, "mcp_servers.create")

    assert {:ok, row} = Arca.McpServerStorage.get(ctx(athanor), "claude")
    assert {row.transport, row.mark} == {"program", "driven"}
    assert row.home == "kept"
    assert row.memory_bytes == 1024 * 1_048_576
    assert row.home_max_bytes == 2048 * 1_048_576
    assert {:ok, []} = Arca.VaultStorage.list(ctx(athanor))

    # It was asked once; added from the form, it opens nothing by itself.
    assert open_confirmations(user, athanor) == []
    refute_received {:session, "open", _message, _fields}
    refute has_element?(view, ~s([data-test="terminal"]))
  end

  test "an install from a component's need asks once, then opens its terminal in the row's folder",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    ref = harness!(athanor)
    query = URI.encode_query(%{"install" => ref, "need" => "claude"})
    {view, _html} = mount_athanor(conn, "/programs?" <> query, athanor)
    render(view)

    assert has_element?(view, ~s([data-test="install-from"]), "asks you to confirm the program")
    view |> form("form#add-program", %{}) |> render_submit()
    answered(view)

    assert %{"details" => %{"command" => "npx -y @anthropic-ai/claude-code@2.1.316"}} =
             asked(user, athanor, "mcp_servers.create")

    confirm!(view, user, athanor, "mcp_servers.create")

    assert {:ok, %{id: home, mark: "driven", home: "kept"}} =
             Arca.McpServerStorage.get(ctx(athanor), "claude")

    assert_receive {:session, "open", %{"mode" => "terminal", "home_id" => ^home}, _fields},
                   2_000

    opened_session(view)
    assert has_element?(view, ~s([data-test="terminal-name"]), "claude")
    assert open_confirmations(user, athanor) == []
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
      "home" => "kept",
      "memory_mib" => "1024"
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
    assert saved.memory_bytes == 1024 * 1_048_576

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
        memory_bytes: 2_147_483_648,
        config_json: Jason.encode!(%{"command" => "gh mcp", "env" => %{}})
      })

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("tr[phx-value-name=gh]") |> render_click()
    view |> element(~s(button[data-test="edit"])) |> render_click()

    view |> form("form#add-program", %{"memory_mib" => "1024"}) |> render_submit()
    answered(view)

    assert %{"details" => %{"memory_bytes" => "1073741824", "grants_asking_again" => "none"}} =
             asked(user, athanor, "mcp_servers.update")

    assert has_element?(view, ~s([data-test="confirmation-consequence"]), "No grant uses it.")
    assert {:ok, ^row} = Arca.McpServerStorage.get(ctx(athanor), "gh")

    confirm!(view, user, athanor, "mcp_servers.update")
    assert open_confirmations(user, athanor) == []
    assert {:ok, saved} = Arca.McpServerStorage.get(ctx(athanor), "gh")
    assert {saved.id, saved.home, saved.memory_bytes} == {row.id, "kept", 1_073_741_824}

    # An edit opened before another change is refused, and changes nothing.
    view |> element(~s(button[data-test="edit"])) |> render_click()
    {:ok, _} = Arca.McpServerStorage.update(ctx(athanor), "gh", %{enabled: false})

    view |> form("form#add-program", %{"memory_mib" => "512"}) |> render_submit()

    html = answered(view)
    assert html =~ "Failed to save:"
    assert html =~ "changed since epoch"
    assert {:ok, %{memory_bytes: 1_073_741_824}} = Arca.McpServerStorage.get(ctx(athanor), "gh")
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
    assert has_element?(view, ~s(tr[data-name="github"] span), "stopped")
    assert has_element?(view, "button", "Enable")
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
        memory_bytes: 16_777_217,
        home_max_bytes: 2_147_483_648,
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
             ~s(form#add-program input[name="memory_mib"][value="16777217 bytes"])
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
             :memory_bytes,
             :home_max_bytes,
             :hosts
           ]) ==
             Map.take(before, [
               :mark,
               :home,
               :memory_bytes,
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
end
