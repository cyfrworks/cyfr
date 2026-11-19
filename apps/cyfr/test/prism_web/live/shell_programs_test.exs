# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellProgramsTest do
  @moduledoc """
  The shelf lists the person's own running programs (`Opus.Programs`):
  what `running/1` answers when the desktop mounts, then each
  `Cyfr.Bus.Program` on the person's topic. A program whose tab was
  closed still stands there; its chip opens its terminal on the Programs
  page, and its Close ends it, each answer of `close/2` in the terminal's
  own words.
  """

  use PrismWeb.ConnCase, async: false

  alias Cyfr.Test.ScriptedBackends, as: Scripted

  @root :crypto.strong_rand_bytes(32)
  @answered_ms 5_000
  @shelf "#canvas-shelf #canvas-shelf-programs"

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "shell_programs_#{System.unique_integer([:positive])}")
    Prima.Test.Env.put_app_env(:arca, :base_path, base)

    on_exit(fn ->
      File.rm_rf(base)
      reload_registry(athanor.id)
    end)

    fake = controller!()
    canvas!(ctx, user)
    row = driven_row!(athanor)

    {:ok, conn: conn, user: user, athanor: athanor, fake: fake, row: row}
  end

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

  # A desktop shown with no apps open on it, so the shelf stands.
  defp canvas!(ctx, user) do
    manifest = %{
      "name" => "markets",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "desktop" => %{}}
    }

    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", "markets", "1.0.0",
      manifest: manifest,
      files: [{"index.html", "<html><head></head><body>markets</body></html>"}]
    )

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, "markets"), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_markets_#{System.unique_integer([:positive])}",
        name: "markets",
        version: "1.0.0",
        component_type: "tincture",
        description: "markets",
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|#{ctx.namespace}",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    Sanctum.Test.ConsentFixtures.grant_tincture!(ctx, "tincture:local.markets")
    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)

    {:ok, _} =
      Arca.CanvasVersions.publish(
        Sanctum.Context.actor(ctx),
        "markets",
        %{Arca.CanvasVersions.empty() | working: "1.0.0"},
        0
      )

    canvases = [
      %{
        "id" => "main",
        "tincture" => "tincture:local.markets",
        "postures" => %{"desk" => %{"apps" => []}}
      }
    ]

    {:ok, layout} = Prima.Layout.validate(%{"version" => 3, "canvases" => canvases})
    {:ok, _revision} = Arca.Layouts.publish(Sanctum.Context.actor(ctx), user.user_id, layout, 0)
    :ok
  end

  defp driven_row!(athanor, name \\ "claude") do
    ctx = Sanctum.Context.actor(Sanctum.Context.internal(athanor_id: athanor.id, scope: :athanor))

    {:ok, row} =
      Arca.McpServerStorage.insert(ctx, %{
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

  # A session of `row` the person starts, as their Programs page does.
  defp start!(user, athanor, row) do
    assert {:ok, session} =
             Opus.Programs.start(person(user, athanor), row.id, %{
               rows: 24,
               cols: 80,
               args: []
             })

    assert_receive {:session, "open", %{"key" => ^session}, _fields}, 2_000
    session
  end

  defp chip(session), do: ~s(#{@shelf} [data-canvas-shelf-program="#{session}"])

  defp flash(view, kind), do: :sys.get_state(view.pid).socket.assigns.flash[kind]

  # Until `fun` holds, or a bound passes.
  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      # sleep-ok: poll interval of eventually's bounded wait (50 tries)
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  test "a program opened, then its tab closed, still shows on the shelf, and Close ends it",
       %{conn: conn, user: user, athanor: athanor} do
    # Opened on the Programs page, whose tab then closes.
    {page, _html} = mount_athanor(conn, "/programs", athanor)
    page |> element("tr[phx-value-name=claude]") |> render_click()
    page |> form("form#open-claude", %{"terminal_args" => ""}) |> render_submit()
    render_async(page, @answered_ms)
    path = assert_patch(page, @answered_ms)
    assert %{"terminal" => session} = URI.decode_query(URI.parse(path).query || "")
    assert_receive {:session, "open", %{"key" => ^session}, _fields}, 2_000

    GenServer.stop(page.pid, :normal)

    {desktop, _html} = mount_desktop(conn)

    assert has_element?(desktop, chip(session) <> " .canvas-shelf-app-name", "claude")

    # No screen shows it now.
    assert has_element?(
             desktop,
             ~s(#{@shelf} [data-canvas-shelf-program="#{session}"][data-canvas-watched="false"] a[title$=", not open on any screen"])
           )

    assert {:ok, [%{session: ^session}]} = Opus.Programs.running(person(user, athanor))

    desktop |> element(chip(session) <> " button.canvas-shelf-program-close") |> render_click()
    assert_receive {:session, "close", _message, _fields}, 2_000

    assert {:ok, []} = Opus.Programs.running(person(user, athanor))
    refute has_element?(desktop, chip(session))
    assert flash(desktop, "error") == nil
  end

  test "the shelf follows the person's topic: a start shows, a change is shown, an end leaves",
       %{conn: conn, user: user, athanor: athanor, row: row} do
    {desktop, _html} = mount_desktop(conn)
    refute has_element?(desktop, @shelf)

    session = start!(user, athanor, row)
    assert eventually(fn -> has_element?(desktop, chip(session)) end)
    refute has_element?(desktop, chip(session) <> ~s( a[title*=", kept"]))

    :ok = Opus.Programs.keep(person(user, athanor), session, true)
    assert eventually(fn -> has_element?(desktop, chip(session) <> ~s( a[title*=", kept"])) end)

    assert {:ok, :closed} = Opus.Programs.close(person(user, athanor), session)
    assert eventually(fn -> not has_element?(desktop, chip(session)) end)
    refute has_element?(desktop, @shelf)
  end

  test "a chip opens its program's terminal on the Programs page",
       %{conn: conn, user: user, athanor: athanor, row: row} do
    session = start!(user, athanor, row)
    {desktop, _html} = mount_desktop(conn)
    to = athanor_path("/programs?terminal=" <> URI.encode_www_form(session))

    assert {:error, {:live_redirect, %{to: ^to}}} =
             desktop |> element(chip(session) <> " a.canvas-shelf-app") |> render_click()
  end

  test "a program Aqua started stands on the shelf as Aqua's: its chip opens the Programs page, and Close ends it",
       %{conn: conn, user: user, athanor: athanor, row: row} do
    require Ecto.Query
    me = person(user, athanor)
    actor = Sanctum.Context.actor(me)
    {:ok, thread} = Arca.Test.Days.thread(actor)

    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: user.user_id, sent_by: "person", content: "run claude"},
        turn: %{agent: "aqua", requested_by: user.user_id, origin: :interactive}
      })

    root = "exe_shelf_turn_#{System.unique_integer([:positive])}"

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

    {desktop, _html} = mount_desktop(conn)
    assert has_element?(desktop, chip(session) <> ~s( a[title*=", started by Aqua"]))

    to = athanor_path("/programs")

    assert {:error, {:live_redirect, %{to: ^to}}} =
             desktop |> element(chip(session) <> " a.canvas-shelf-app") |> render_click()

    {desktop, _html} = mount_desktop(conn)
    desktop |> element(chip(session) <> " button.canvas-shelf-program-close") |> render_click()
    assert_receive {:session, "close", _message, _fields}, 2_000
    assert {:ok, []} = Opus.Programs.running(me)
  end

  test "Close's answers read in the terminal's own words, and the shelf lists what is running after",
       %{conn: conn, user: user, athanor: athanor, row: row, fake: fake} do
    {desktop, _html} = mount_desktop(conn)

    # Already gone: the chip of a session that ended meanwhile.
    render_click(desktop, "close_program", %{"session" => "trm_never"})
    assert flash(desktop, "info") == "This program is not running any more."

    # Unanswered: the service does not confirm, and CYFR ends it.
    session = start!(user, athanor, row)
    assert eventually(fn -> has_element?(desktop, chip(session)) end)
    Scripted.refuse_once(fake, "close", "internal")
    desktop |> element(chip(session) <> " button.canvas-shelf-program-close") |> render_click()

    assert flash(desktop, "error") ==
             "The close was not confirmed yet; CYFR ends the program."

    assert eventually(fn -> not has_element?(desktop, chip(session)) end)
    assert {:ok, []} = Opus.Programs.running(person(user, athanor))
  end

  # The shell's context, swapped for one the session owner refuses, so
  # each read of `running/1` fails until it is put back. A validated
  # context stands as it is for the caller bound, set long here, so
  # neither the guard nor the owner reads the session again meanwhile.
  defp reads_fail(view) do
    Prima.Test.Env.put_app_env(:sanctum, :caller_memo_ttl_ms, 600_000)

    :sys.replace_state(view.pid, fn channel ->
      update_in(channel.socket, fn socket ->
        Phoenix.Component.assign(socket, :context, %{
          socket.assigns.context
          | authenticated: false,
            validated_at: DateTime.utc_now()
        })
      end)
    end)
  end

  defp reads_work(view, ctx) do
    :sys.replace_state(view.pid, fn channel ->
      update_in(
        channel.socket,
        &Phoenix.Component.assign(&1, :context, %{ctx | validated_at: DateTime.utc_now()})
      )
    end)
  end

  defp shell_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  test "a read that fails keeps what is shown, tries again once at a time, and the next read is the truth",
       %{conn: conn, user: user, athanor: athanor, row: row} do
    [first, second, third] = for _n <- 1..3, do: start!(user, athanor, row)
    {desktop, _html} = mount_desktop(conn)
    for session <- [first, second, third], do: assert(has_element?(desktop, chip(session)))
    ctx = shell_assigns(desktop).context

    reads_fail(desktop)
    assert {:ok, :closed} = Opus.Programs.close(person(user, athanor), first)

    # The end's read failed: the other two still stand, and one retry waits.
    assert eventually(fn -> is_reference(shell_assigns(desktop).programs_retry) end)
    retry = shell_assigns(desktop).programs_retry
    assert has_element?(desktop, chip(second))
    assert has_element?(desktop, chip(third))

    # Another message while it waits sets no second retry.
    :ok = Opus.Programs.keep(person(user, athanor), second, true)
    render(desktop)
    assert shell_assigns(desktop).programs_retry == retry

    # The retry reads again and lists what is running.
    reads_work(desktop, ctx)
    assert eventually(fn -> not has_element?(desktop, chip(first)) end, 160)
    assert has_element?(desktop, chip(second) <> ~s( a[title*=", kept"]))
    assert has_element?(desktop, chip(third))
    assert shell_assigns(desktop).programs_retry == nil
  end

  test "a message is only a reason to read again: what it names is never listed by itself",
       %{conn: conn, user: user, athanor: athanor, row: row} do
    {desktop, _html} = mount_desktop(conn)
    actor = Sanctum.Context.actor(person(user, athanor))

    # A session running/1 does not answer, named on the topic, is not drawn.
    Cyfr.Bus.broadcast(
      actor,
      Cyfr.Bus.programs(actor, user.user_id),
      Cyfr.Bus.Program.new(actor, :started,
        session: "trm_ghost",
        row_id: row.id,
        name: "ghost",
        started_at: DateTime.utc_now(),
        kept: false,
        attached: false
      )
    )

    render(desktop)
    refute has_element?(desktop, chip("trm_ghost"))

    # An end, then a late change of the same session, does not bring it back.
    session = start!(user, athanor, row)
    assert eventually(fn -> has_element?(desktop, chip(session)) end)
    assert {:ok, :closed} = Opus.Programs.close(person(user, athanor), session)
    assert eventually(fn -> not has_element?(desktop, chip(session)) end)

    send(
      desktop.pid,
      Cyfr.Bus.Program.new(actor, :changed,
        session: session,
        row_id: row.id,
        name: "claude",
        started_at: DateTime.utc_now(),
        kept: true,
        attached: true
      )
    )

    render(desktop)
    refute has_element?(desktop, chip(session))
  end

  test "the open apps and the programs scroll sideways as one row the shelf bounds, each chip and its Close whole",
       %{conn: conn, user: user, athanor: athanor, row: row} do
    session = start!(user, athanor, row)
    {desktop, _html} = mount_desktop(conn)

    assert has_element?(desktop, "#canvas-shelf .canvas-shelf-scroll > #canvas-shelf-apps")

    assert has_element?(
             desktop,
             ~s(#canvas-shelf .canvas-shelf-scroll > #canvas-shelf-programs [data-canvas-shelf-program="#{session}"])
           )

    css = File.read!(Path.expand("../../../assets/css/canvas_chrome.css", __DIR__))
    [_, row_rule] = Regex.run(~r/\.canvas-shelf-scroll \{([^}]*)\}/, css)
    assert row_rule =~ "min-width: 0;"
    assert row_rule =~ "overflow-x: auto;"

    assert css =~
             ".canvas-shelf-scroll > #canvas-shelf-apps,\n.canvas-shelf-scroll > #canvas-shelf-programs { flex-shrink: 0; }"

    [_, chip] = Regex.run(~r/\.canvas-shelf-program \{([^}]*)\}/, css)
    assert chip =~ "flex-shrink: 0;"
  end

  test "another person's running programs never reach this person's shelf",
       %{conn: conn, user: user, athanor: athanor, row: row} do
    mine = start!(user, athanor, row)

    other = test_user()
    _other_conn = log_in_user(build_conn(), other)
    other_athanor = seated_athanor()
    theirs = start!(other, other_athanor, driven_row!(other_athanor))

    # Back to this person's own athanor for the desktop.
    Process.put(:prism_test_athanor_id, athanor.id)
    {desktop, _html} = mount_desktop(conn)

    assert has_element?(desktop, chip(mine))
    refute has_element?(desktop, chip(theirs))

    # Nor does the other person's later change arrive.
    :ok = Opus.Programs.keep(person(other, other_athanor), theirs, true)
    render(desktop)
    refute has_element?(desktop, chip(theirs))
  end
end
