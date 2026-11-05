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
      bypass = Bypass.open()
      echo_upstream(bypass, unquote(era))

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
          destination: %{"hosts" => ["127.0.0.1"], "scheme" => "http", "port" => bypass.port}
        })

      on_exit(fn -> Emissary.External.ServerSupervisor.stop("echo", athanor.id) end)

      {view, _html} = mount_athanor(conn, "/programs", athanor)
      view |> element("button", "Add server") |> render_click()

      config =
        Jason.encode!(%{
          "url" => "http://127.0.0.1:#{bypass.port}/mcp",
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
  defp echo_upstream(bypass, era) do
    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
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

    {:ok, _} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, "catalyst", "local", "harness", "1.0.0",
        manifest: manifest,
        wasm: Cyfr.Test.Guests.wasm(:catalyst)
      )

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
end
