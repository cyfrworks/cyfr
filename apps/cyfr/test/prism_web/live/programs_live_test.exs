# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ProgramsLiveTest do
  @moduledoc """
  The Programs page adds a stdio server through its form, sends its env
  lines as the backend's env, says why a server was not added, says why
  a server it added or tested could not connect, shows the warnings a
  server it added carries in the flash and on its row, and offers Restart
  for a stdio server only. It prefills the program form from a
  component's login need, and its sign-in terminal shows a program's lines
  as text, bounded.
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

  @root :crypto.strong_rand_bytes(32)

  test "a stdio server whose command expands a vault-bound name is added with its warning",
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
    view |> element("button", "Add stdio server") |> render_click()

    view
    |> form("form[phx-submit=add_stdio]", %{
      "name" => "github",
      "backend" => "github",
      "command" => "npx -y @modelcontextprotocol/server-github --token $GITHUB_TOKEN",
      "env" => "GITHUB_TOKEN=vault:gh"
    })
    |> render_submit()

    warning =
      "Backend 'github' expands GITHUB_TOKEN, a vault-bound env name, in its command: the " <>
        "value is placed on the command line, where every process on the backends service, " <>
        "other athanors' backends included, can read it; the safe route is to let the " <>
        "program read it from its environment."

    assert flash(view, "info") == "'github' added (ready)."
    assert flash(view, "warning") == warning
    assert_received {:control, "sync", _sync, _fields}

    html = view |> element("tr[phx-value-name=github]") |> render_click()
    assert html =~ "expands GITHUB_TOKEN, a vault-bound env name, in its command"
  end

  test "the stdio form refuses a malformed env line, and a server the catalog refuses",
       %{conn: conn, athanor: athanor, user: user} do
    # The entry the env names, disclosed: an environment hands it on.
    entry!(user, athanor, "gh", %{"hosts" => ["api.github.com"]}, true)

    {view, html} = mount_athanor(conn, "/programs", athanor)
    assert html =~ "Add stdio server"

    view |> element("button", "Add stdio server") |> render_click()

    html =
      view
      |> form("form[phx-submit=add_stdio]", %{
        "name" => "github",
        "backend" => "github",
        "command" => "npx -y @modelcontextprotocol/server-github",
        "env" => "GITHUB_TOKEN vault:gh"
      })
      |> render_submit()

    assert html =~ "Each env line is NAME=value"

    html =
      view
      |> form("form[phx-submit=add_stdio]", %{
        "name" => "github",
        "backend" => "github",
        "command" => "npx -y @modelcontextprotocol/server-github",
        "env" => "GITHUB_TOKEN=vault:gh\n\nNODE_ENV=production"
      })
      |> render_submit()

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

    assert {:ok, _} = Arca.McpServerStorage.get(ctx(athanor), "local")
    assert flash(view, "error") =~ "'local' added — "

    # The edited row's Test says why, in the refusal's own words.
    view |> element("tr[phx-value-name=edited]") |> render_click()
    view |> element(~s(button[phx-click="test"][phx-value-name="edited"])) |> render_click()

    assert flash(view, "error") ==
             "Test edited: " <> Sanctum.Refusals.render(:destination_mismatch)

    refute flash(view, "error") =~ "openai-key"
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

      added =
        view
        |> form("form[phx-submit=add_server]", %{"name" => "echo", "config" => config})
        |> render_submit()

      assert flash(view, "error") == "'echo' added — rejected credential [REDACTED]"
      refute added =~ @echoed

      view |> element("tr[phx-value-name=echo]") |> render_click()

      tested =
        view
        |> element(~s(button[phx-click="test"][phx-value-name="echo"]))
        |> render_click()

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

  test "an expanded stdio server offers Restart and an http server does not",
       %{conn: conn, athanor: athanor} do
    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "piped",
        transport: "stdio",
        url: nil,
        enabled: false,
        config_json:
          Jason.encode!(%{
            "backends" => [%{"name" => "fs", "command" => "npx -y fs", "env" => %{}}]
          })
      })

    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "webby",
        url: "https://127.0.0.1:9/mcp",
        enabled: false
      })

    {view, html} = mount_athanor(conn, "/programs", athanor)
    assert html =~ "stdio (backends service)"

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
          "install" => %{
            "command" => "npx -y @anthropic-ai/claude-code@2.1.316",
            "login_command" => "claude auth login"
          }
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

    assert has_element?(view, ~s(form#add-pipe input[name="name"][value="claude"]))

    assert has_element?(
             view,
             ~s(form#add-pipe input[name="command"][value="npx -y @anthropic-ai/claude-code@2.1.316"])
           )

    assert has_element?(
             view,
             ~s(form#add-pipe input[name="login_command"][value="claude auth login"])
           )

    assert html =~ "Install"
  end

  test "an install naming no login need of the component says so", %{conn: conn, athanor: athanor} do
    ref = harness!(athanor)
    query = URI.encode_query(%{"install" => ref, "need" => "codex"})
    {view, _html} = mount_athanor(conn, "/programs?" <> query, athanor)
    render(view)

    assert flash(view, "error") == "#{ref} declares no login need named 'codex' to install from."
    refute has_element?(view, "form#add-pipe")
  end

  test "the terminal shows a program's lines as text, without its control sequences" do
    alias PrismWeb.SignInTerminalComponent, as: Terminal

    assert Terminal.text("\e[1;32mOpen this URL:\e[0m https://x.example/a\r") ==
             "Open this URL: https://x.example/a"

    assert Terminal.text("\e]0;title\aPaste code: ") == "Paste code: "
    assert Terminal.text("\e[?25lplain\e(B") == "plain"
    assert Terminal.max_lines() == 500
  end

  # What `gh auth login` wrote on the pty in the S1 hand check: a terminal
  # query (OSC 11, ended by ST), then its first prompt between cursor saves.
  test "the terminal strips OSC sequences as well as CSI, on gh's query and prompt" do
    alias PrismWeb.SignInTerminalComponent, as: Terminal

    assert Terminal.text("\e]11;?\e\\") == ""
    assert Terminal.text("\e]11;?\a") == ""

    assert Terminal.text(
             "\e7\e8\e[0;1;92m?\e[0m \e[0;1;39mWhere do you use GitHub?\e[0m  " <>
               "\e[0;36m[Use arrows to move, type to filter]\e[0m\r"
           ) == "? Where do you use GitHub?  [Use arrows to move, type to filter]"
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

  defp pipe_row!(athanor, name \\ "claude") do
    {:ok, row} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: name,
        transport: "pipe",
        url: nil,
        home: "kept",
        login_command: "#{name} auth login",
        config_json:
          Jason.encode!(%{
            "backends" => [
              %{"name" => name, "command" => "npx -y @anthropic-ai/#{name}", "env" => %{}}
            ]
          })
      })

    row
  end

  defp login!(user, athanor, name, program) do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(person(user, athanor), %{
        name: name,
        kind: "login",
        program: program
      })

    entry.id
  end

  # Until `fun` holds, or a bound passes.
  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  test "a kept program signs in through the terminal: its lines in, the person's out, its end said",
       %{conn: conn, athanor: athanor, user: user} do
    fake = controller!()
    row = pipe_row!(athanor)
    entry = login!(user, athanor, "claude-login", "claude")

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("tr[phx-value-name=claude]") |> render_click()
    assert has_element?(view, ~s([data-test="program-settings"]), "claude auth login")

    view
    |> form(~s([data-test="home-actions"] form[phx-submit="sign_in"]), %{"entry" => entry})
    |> render_submit()

    assert_receive {:session, "open", %{"mode" => "sign_in", "home_id" => ^entry}, _}, 2_000
    assert has_element?(view, ~s([data-test="sign-in-terminal"]))

    # The program's line, with the colour a terminal draws it in, shows as text.
    Scripted.write(fake, row.id, "\e[1mPaste code here:\e[0m")

    assert eventually(fn ->
             has_element?(view, ~s([data-test="terminal-lines"]), "Paste code here:")
           end)

    refute render(view) =~ "\e[1m"

    view
    |> form(~s([data-test="terminal-input"]), %{"sign_in_line" => "code-1234"})
    |> render_submit()

    assert_receive {:session, "send", %{"lines" => ["code-1234"]}, _fields}, 2_000

    Scripted.end_sessions(fake, row.id, 0)

    assert eventually(fn ->
             has_element?(view, ~s([data-test="terminal-ended"]), "Signed in.")
           end)

    refute has_element?(view, ~s([data-test="terminal-input"]))
  end

  # One terminal, one session: selecting another target closes the session
  # running, the new terminal sends to its own, and its heading names it.
  test "selecting another program's sign-in closes the one running and sends to the new one",
       %{conn: conn, athanor: athanor, user: user} do
    fake = controller!()
    claude = pipe_row!(athanor)
    codex = pipe_row!(athanor, "codex")
    a = login!(user, athanor, "claude-login", "claude")
    b = login!(user, athanor, "codex-login", "codex")

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    sign_in(view, "claude", a)
    assert_receive {:session, "open", %{"home_id" => ^a}, _fields}, 2_000
    Scripted.write(fake, claude.id, "first")
    assert eventually(fn -> has_element?(view, ~s([data-test="terminal-lines"]), "first") end)
    assert_receive {:session, "recv", %{"session" => session_a}, _fields}, 2_000

    sign_in(view, "codex", b)
    assert_receive {:session, "close", %{"session" => ^session_a}, _fields}, 2_000
    assert_receive {:session, "open", %{"home_id" => ^b}, _fields}, 2_000
    assert eventually(fn -> has_element?(view, ~s([data-test="terminal-input"])) end)

    assert length(Regex.scan(~r/data-test="sign-in-terminal"/, render(view))) == 1
    assert has_element?(view, ~s([data-test="sign-in-terminal"]), "codex")
    refute has_element?(view, ~s([data-test="terminal-lines"]), "first")

    view
    |> form(~s([data-test="terminal-input"]), %{"sign_in_line" => "code-b"})
    |> render_submit()

    assert_receive {:session, "send", %{"session" => session_b, "lines" => ["code-b"]}, _}, 2_000
    assert session_b != session_a

    # After its session ended, selecting the same sign-in again starts afresh.
    Scripted.end_sessions(fake, codex.id, 0)
    assert eventually(fn -> has_element?(view, ~s([data-test="terminal-ended"])) end)
    sign_in(view, "codex", b)
    assert_receive {:session, "open", %{"home_id" => ^b}, _fields}, 2_000
    assert eventually(fn -> has_element?(view, ~s([data-test="terminal-input"])) end)
    refute has_element?(view, ~s([data-test="terminal-ended"]))
  end

  # A program's terminal text may be a credential: the page shows it, and
  # its state, printed by a crash report or LiveView's termination log,
  # carries only how many lines there are.
  test "the terminal's text is in no crash report of the page, only its count",
       %{conn: conn, athanor: athanor, user: user} do
    fake = controller!()
    row = pipe_row!(athanor)
    entry = login!(user, athanor, "claude-login", "claude")
    canary = "sk-canary-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    sign_in(view, "claude", entry)
    assert_receive {:session, "open", %{"home_id" => ^entry}, _fields}, 2_000
    Scripted.write(fake, row.id, canary)
    assert eventually(fn -> has_element?(view, ~s([data-test="terminal-lines"]), canary) end)

    # What LiveView's termination formatter hands a crash report: the
    # page's whole state, components included, before a logger cuts it.
    terminated =
      Phoenix.LiveView.Channel.format_status(:terminate, [%{}, :sys.get_state(view.pid)])

    state = inspect(terminated, limit: :infinity, printable_limit: :infinity)
    refute state =~ canary
    assert state =~ "#PrismWeb.SignInTerminalComponent.Lines<1 lines>"

    # A call the page does not take (it defines no handle_call) crashes it;
    # its termination report prints its state.
    # The test's own process is linked to the page through its client.
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

  # Two sign-ins chosen before the first one's start was heard: the first
  # session, whose terminal is gone, is closed when its start arrives, and
  # the second is the one Send reaches.
  test "a sign-in started for a terminal no longer open is closed",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    pipe_row!(athanor)
    pipe_row!(athanor, "codex")
    a = login!(user, athanor, "claude-login", "claude")
    b = login!(user, athanor, "codex-login", "codex")

    {view, _html} = mount_athanor(conn, "/programs", athanor)

    # Both choices queue before the page handles either, as two quick clicks
    # do: A's start, sent from its terminal's first update, lands after B's.
    :sys.suspend(view.pid)

    first =
      Task.async(fn -> render_submit(view, "sign_in", %{"name" => "claude", "entry" => a}) end)

    Process.sleep(100)

    second =
      Task.async(fn -> render_submit(view, "sign_in", %{"name" => "codex", "entry" => b}) end)

    Process.sleep(100)
    :sys.resume(view.pid)
    Task.await(first)
    Task.await(second)

    assert_receive {:session, "open", %{"home_id" => ^a}, _fields}, 2_000
    assert_receive {:session, "open", %{"home_id" => ^b}, _fields}, 2_000
    assert_receive {:session, "recv", %{"session" => _}, _fields}, 2_000

    session_a =
      receive do
        {:session, "close", %{"session" => session}, _fields} -> session
      after
        2_000 -> flunk("the first sign-in's session was never closed")
      end

    assert eventually(fn -> has_element?(view, ~s([data-test="terminal-input"])) end)
    assert has_element?(view, ~s([data-test="sign-in-terminal"]), "codex")

    view
    |> form(~s([data-test="terminal-input"]), %{"sign_in_line" => "code-b"})
    |> render_submit()

    assert_receive {:session, "send", %{"session" => session_b, "lines" => ["code-b"]}, _}, 2_000
    assert session_b != session_a
  end

  # Signs `name` in with `entry`, its row expanded first unless it is.
  defp sign_in(view, name, entry) do
    unless has_element?(view, ~s([data-test="home-actions"] input[name="name"][value="#{name}"])),
      do: view |> element("tr[phx-value-name=#{name}]") |> render_click()

    view
    |> form(~s([data-test="home-actions"] form[phx-submit="sign_in"]), %{"entry" => entry})
    |> render_submit()
  end

  test "Reset folder empties the chosen login entry's folder", %{
    conn: conn,
    athanor: athanor,
    user: user
  } do
    controller!()
    pipe_row!(athanor)
    entry = login!(user, athanor, "claude-login", "claude")

    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("tr[phx-value-name=claude]") |> render_click()

    view
    |> form(~s([data-test="home-actions"] form[phx-submit="reset_home"]), %{"entry" => entry})
    |> render_submit()

    assert_receive {:control, "home", %{"op" => "reset", "home_id" => ^entry}, _fields}, 2_000
    assert flash(view, "info") == "The folder is empty again."
    assert render(view) =~ "Reset folder"
    refute render(view) =~ "Reset home"
  end

  test "the program form defines a kept pipe row with its bounds, and makes its login entry once confirmed",
       %{conn: conn, athanor: athanor, user: user} do
    controller!()
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("button", "Add program") |> render_click()

    view
    |> form("form#add-pipe", %{
      "name" => "claude",
      "command" => "npx -y @anthropic-ai/claude-code",
      "login_command" => "claude auth login",
      "home" => "kept",
      "memory_mib" => "1024",
      "disk_mib" => "2048"
    })
    |> render_submit()

    assert {:ok, row} = Arca.McpServerStorage.get(ctx(athanor), "claude")
    assert row.transport == "pipe"
    assert row.home == "kept"
    assert row.memory_bytes == 1024 * 1_048_576
    assert row.home_max_bytes == 2048 * 1_048_576
    assert row.login_command == "claude auth login"

    # The login entry is a sensitive change: it is made once the person
    # confirms it, and the sign-in opens on it.
    assert {:ok, []} = Sanctum.Mount.login_entries(athanor.id)
    refute has_element?(view, ~s([data-test="sign-in-terminal"]))
    person = person(user, athanor)

    assert {:ok, [%{ref: ref, operation: "vault.create"}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(person), user.user_id)

    Sanctum.TestContext.prove!(person, ref)
    assert eventually(fn -> has_element?(view, ~s([data-test="sign-in-terminal"])) end)

    assert {:ok, [entry]} = Sanctum.Mount.login_entries(athanor.id)
    assert {:ok, %{name: "claude-login"}} = Arca.VaultStorage.get(ctx(athanor), entry)

    assert_receive {:session, "open", %{"mode" => "sign_in"}, _fields}, 2_000
  end

  test "a kept stdio server names its login entry", %{conn: conn, athanor: athanor, user: user} do
    controller!()
    entry = login!(user, athanor, "gh-login", "gh")
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("button", "Add stdio server") |> render_click()

    view
    |> form("form#add-stdio", %{
      "name" => "gh",
      "backend" => "github",
      "command" => "gh mcp",
      "login_command" => "gh auth login",
      "home" => "kept",
      "login_entry" => entry
    })
    |> render_submit()

    assert {:ok, row} = Arca.McpServerStorage.get(ctx(athanor), "gh")
    assert row.transport == "stdio"
    assert row.home == "kept"
    assert row.login_entry_id == entry
  end

  test "a program's hosts are set in its form, shown on its row and changed there",
       %{conn: conn, athanor: athanor} do
    controller!()
    {view, _html} = mount_athanor(conn, "/programs", athanor)
    view |> element("button", "Add stdio server") |> render_click()

    # The form says what the list admits, a shared address among it.
    assert has_element?(view, ~s([data-test="hosts-help"]), "shares an address with another")

    view
    |> form("form#add-stdio", %{
      "name" => "fetch",
      "backend" => "fetch",
      "command" => "npx -y @modelcontextprotocol/server-fetch",
      "home" => "scratch",
      "hosts" => "api.example.com, registry.npmjs.org"
    })
    |> render_submit()

    assert {:ok, row} = Arca.McpServerStorage.get(ctx(athanor), "fetch")
    assert Jason.decode!(row.hosts) == ["api.example.com", "registry.npmjs.org"]

    view |> element("tr[phx-value-name=fetch]") |> render_click()

    assert has_element?(
             view,
             ~s([data-test="program-hosts"]),
             "api.example.com, registry.npmjs.org"
           )

    view |> form("form#hosts-fetch", %{"hosts" => "api.example.com"}) |> render_submit()
    assert {:ok, row} = Arca.McpServerStorage.get(ctx(athanor), "fetch")
    assert Jason.decode!(row.hosts) == ["api.example.com"]

    view |> form("form#hosts-fetch", %{"hosts" => "*.example.com"}) |> render_submit()
    assert flash(view, "error") =~ "config.hosts"

    assert {:ok, %{hosts: ~s(["api.example.com"])}} =
             Arca.McpServerStorage.get(ctx(athanor), "fetch")

    view |> form("form#hosts-fetch", %{"hosts" => ""}) |> render_submit()
    assert {:ok, %{hosts: nil}} = Arca.McpServerStorage.get(ctx(athanor), "fetch")
    assert has_element?(view, ~s([data-test="program-hosts"]), "every public host")
  end

  test "the list says each row's transport and folder", %{conn: conn, athanor: athanor} do
    pipe_row!(athanor)

    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        cap: 0,
        name: "webby",
        url: "https://127.0.0.1:9/mcp",
        enabled: false
      })

    {view, _html} = mount_athanor(conn, "/programs", athanor)

    assert has_element?(view, ~s(tr[data-name="claude"] [data-test="transport"]), "pipe")
    assert has_element?(view, ~s(tr[data-name="claude"] [data-test="home"]), "kept")
    assert has_element?(view, ~s(tr[data-name="webby"] [data-test="transport"]), "http")

    # The column a person reads names a folder, never a home.
    assert has_element?(view, "thead th", "Folder")
    refute has_element?(view, "thead th", "Home")
  end
end
