# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellDesktopTest do
  @moduledoc """
  What the shell does for a desktop beyond showing it: its handshake hands
  it the person's preferences, the screen's appearance and the person's
  name; one input of the person's carries one verb; a declared control
  runs through the gate as the person, its pick checked against the
  stream's current state, and its outcome is told to the desktop; a write
  of its preferences goes over the revision the frame holds, a stale one
  answered with the current document; the visible desktop's chrome is
  worn and taken off; `ask` opens AQUA's panel with Prism's sentence;
  `settings` opens one of Prism's pages; and `open` carries a subject the
  app declares.
  """

  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias Prism.Frames

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "shell_desktop_#{System.unique_integer([:positive])}")
    # The restore is registered before the change, so a test killed at its
    # timeout leaves the setting as it found it.
    Prima.Test.Env.put_app_env(:arca, :base_path, base)

    on_exit(fn ->
      File.rm_rf(base)
      Prism.TinctureRegistry.reload_athanor(athanor.id)
    end)

    {:ok, conn: conn, user: user, athanor: athanor, ctx: ctx}
  end

  # ---- what the athanor holds -----------------------------------------------

  defp lay!(ctx, name, version, tincture, files) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => version,
      "publisher" => "local",
      "tincture" => tincture
    }

    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", name, version,
      manifest: manifest,
      files: files
    )

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name <> version), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: version,
        component_type: "tincture",
        description: name,
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

    actor = Sanctum.Context.actor(ctx)
    {:ok, token} = Arca.StorageProjectionChanges.snapshot(actor, "components")

    {:ok, :acknowledged} =
      Arca.StorageProjectionChanges.replace(actor, "components", token, fn -> :acknowledged end)

    Sanctum.Test.ConsentFixtures.grant_tincture!(ctx, "tincture:local.#{name}")
    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
    release_digest
  end

  defp desktop!(ctx, name, desktop, files \\ []) do
    lay!(
      ctx,
      name,
      "1.0.0",
      %{"entry" => "index.html", "desktop" => desktop},
      [{"index.html", "<html><head></head><body>#{name}</body></html>"} | files]
    )

    versions!(ctx, name, %{working: "1.0.0"})
  end

  defp app!(ctx, name, tincture \\ %{}) do
    lay!(ctx, name, "1.0.0", Map.merge(%{"entry" => "index.html"}, tincture), [
      {"index.html", "<html><head></head><body>#{name}</body></html>"}
    ])
  end

  defp versions!(ctx, name, fields) do
    actor = Sanctum.Context.actor(ctx)

    revision =
      case Arca.CanvasVersions.get(actor, name) do
        {:ok, %{revision: revision}} -> revision
        {:error, :not_found} -> 0
      end

    {:ok, _} =
      Arca.CanvasVersions.publish(
        actor,
        name,
        Map.merge(Arca.CanvasVersions.empty(), fields),
        revision
      )
  end

  defp entry(id, tincture), do: %{"id" => id, "tincture" => tincture, "postures" => %{}}

  defp layout!(user, athanor, canvases) do
    ctx = person(user, athanor)
    {:ok, %{revision: revision}} = Compendium.Providers.Layout.read(ctx)

    {:ok, _} =
      Compendium.Providers.Layout.handle("layout", ctx, %{
        "action" => "edit",
        "document" => %{"version" => 3, "canvases" => canvases},
        "revision" => revision
      })
  end

  defp person(user, athanor) do
    Sanctum.Context.build(
      user_id: user.user_id,
      athanor_id: athanor.id,
      permissions: Sanctum.Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  defp schedule!(ctx, user, name) do
    {:ok, schedule} =
      Arca.CronSchedule.create(Sanctum.Context.actor(ctx), %{
        user_id: user.user_id,
        athanor_id: ctx.athanor_id,
        name: name,
        cron_expression: "0 3 * * *",
        reference: "reagent:local.#{name}",
        resolved_reference: "reagent:local.#{name}:1.0.0",
        profile_id: "prof-#{name}",
        next_run_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
        cap: 0
      })

    schedule
  end

  defp status(ctx, id) do
    {:ok, row} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), id)
    row.status
  end

  # ---- the shell ------------------------------------------------------------

  defp shell!(conn) do
    {view, _html} = mount_athanor(conn, "/canvas")

    wait_until(
      fn ->
        render(view)
        assigns = assigns(view)
        assigns.showing != :pending or assigns.fallbacks != %{}
      end,
      2_000,
      "the shell to settle"
    )

    view
  end

  defp assigns(%Phoenix.LiveViewTest.View{pid: pid}), do: :sys.get_state(pid).socket.assigns
  defp frames(view), do: assigns(view).frames
  defp canvas(view, id \\ "home"), do: Frames.get(frames(view), {:canvas, id})
  defp dropped(view), do: Frames.dropped(frames(view))

  defp handshake!(view, frame_id) do
    render_hook(view, "frame_handshake", %{"frame" => frame_id})
    assert_reply(view, %{"credential" => _} = reply)
    reply
  end

  # A verb of the canvas's as its bridge forwards it: a person's verb with
  # the ordinal of a fresh input, unless `input` names one.
  defp verb!(view, frame_id, verb, args, input \\ :fresh) do
    input = if input == :fresh, do: System.unique_integer([:positive, :monotonic]), else: input

    payload =
      %{"frame" => frame_id, "message" => Prima.TinctureWire.shell_message(verb, frame_id, args)}

    render_hook(
      view,
      "frame_verb",
      if(input, do: Map.put(payload, "input", input), else: payload)
    )
  end

  defp answer!(view, frame_id, verb) do
    assert_push_event(view, "canvas_answer", %{frame: ^frame_id, verb: ^verb, args: args})
    args
  end

  defp stored(ctx, user, canvas_id) do
    case Arca.CanvasPrefs.get(Sanctum.Context.actor(ctx), user.user_id, canvas_id) do
      {:ok, %{document: document, revision: revision}} -> {document, revision}
      {:error, :not_found} -> {:none, 0}
    end
  end

  @prefs %{
    "widgets" => %{"runs" => %{"fields" => %{"compact" => %{"type" => "boolean"}}}, "apps" => %{}}
  }

  # ---- the handshake ----------------------------------------------------------

  describe "the handshake" do
    setup %{ctx: ctx, user: user, athanor: athanor} do
      desktop!(ctx, "markets", %{"data" => ["runs.changes"], "prefs" => @prefs})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      :ok
    end

    test "hands the desktop its preferences as the version's schema reads them, the appearance and the person's name alone",
         %{conn: conn, ctx: ctx, user: user} do
      actor = Sanctum.Context.actor(ctx)

      schema = %{
        widgets: %{"runs" => %{"compact" => %{"type" => "boolean"}}, "apps" => %{}},
        desktop: %{}
      }

      {:ok, %{revision: 1}} =
        Arca.CanvasPrefs.write(
          actor,
          user.user_id,
          "home",
          %{"widgets" => %{"runs" => %{"on" => false, "compact" => true}}},
          schema,
          0
        )

      view = shell!(conn)
      %{"canvas" => block} = handshake!(view, canvas(view).id)

      assert block["prefs"] == %{
               "document" => %{
                 "widgets" => %{"runs" => %{"on" => false, "compact" => true}},
                 "desktop" => %{}
               },
               "revision" => 1
             }

      assert block["appearance"] == Prism.Appearance.block(%{})
      assert Map.keys(block["person"]) == ["name"]

      # Never the person's email or id.
      encoded = Jason.encode!(block)
      refute encoded =~ user.user_id
      if is_binary(user.email), do: refute(encoded =~ user.email)
    end
  end

  # ---- one input, one verb -------------------------------------------------------

  describe "one input of the person's" do
    setup %{ctx: ctx, user: user, athanor: athanor} do
      desktop!(ctx, "markets", %{"data" => ["runs.changes"], "prefs" => @prefs})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      :ok
    end

    test "carries one verb: a second with the same input, or one with none, is dropped and told it did not run",
         %{conn: conn, ctx: ctx, user: user} do
      view = shell!(conn)
      home = canvas(view).id
      handshake!(view, home)
      write = %{"document" => %{"widgets" => %{"apps" => %{"on" => false}}}}

      verb!(view, home, :prefs, write, 41)
      assert %{"outcome" => "saved", "revision" => 1} = answer!(view, home, "prefs")

      # The same input again, and an earlier one.
      verb!(view, home, :prefs, write, 41)
      assert %{"outcome" => "cancelled", "revision" => 1} = answer!(view, home, "prefs")
      verb!(view, home, :prefs, write, 40)
      assert %{"outcome" => "cancelled"} = answer!(view, home, "prefs")

      # No input at all.
      verb!(view, home, :prefs, write, nil)
      assert %{"outcome" => "cancelled"} = answer!(view, home, "prefs")

      assert dropped(view) == 3
      assert {_document, 1} = stored(ctx, user, "home")

      # A new input carries the next.
      verb!(view, home, :prefs, write, 42)
      assert %{"outcome" => "saved", "revision" => 2} = answer!(view, home, "prefs")
    end

    test "ready and failed need none", %{conn: conn} do
      view = shell!(conn)
      home = canvas(view).id

      verb!(view, home, :ready, %{}, nil)
      assert MapSet.member?(assigns(view).canvas_ready, home)
      assert dropped(view) == 0
    end
  end

  # ---- preferences --------------------------------------------------------------

  describe "the preferences" do
    setup %{ctx: ctx, user: user, athanor: athanor} do
      desktop!(ctx, "markets", %{"data" => ["runs.changes"], "prefs" => @prefs})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      :ok
    end

    test "a write goes over the revision the frame holds; a stale one is answered with the current document and merges nothing",
         %{conn: conn, ctx: ctx, user: user} do
      view = shell!(conn)
      home = canvas(view).id
      %{"canvas" => %{"prefs" => %{"revision" => 0}}} = handshake!(view, home)

      verb!(view, home, :prefs, %{"document" => %{"widgets" => %{"runs" => %{"on" => false}}}})

      assert %{"outcome" => "saved", "revision" => 1, "document" => saved} =
               answer!(view, home, "prefs")

      assert saved["widgets"] == %{"runs" => %{"on" => false}}

      # Another screen of the person's writes meanwhile.
      schema = %{
        widgets: %{"runs" => %{"compact" => %{"type" => "boolean"}}, "apps" => %{}},
        desktop: %{}
      }

      {:ok, %{revision: 2}} =
        Arca.CanvasPrefs.write(
          Sanctum.Context.actor(ctx),
          user.user_id,
          "home",
          %{"widgets" => %{"apps" => %{"on" => false}}},
          schema,
          1
        )

      verb!(view, home, :prefs, %{"document" => %{"widgets" => %{"runs" => %{"on" => true}}}})

      assert %{"outcome" => "stale", "revision" => 2, "document" => current} =
               answer!(view, home, "prefs")

      assert current["widgets"] == %{"runs" => %{"on" => false}, "apps" => %{"on" => false}}
      assert {^current, 2} = stored(ctx, user, "home")

      # Written again over the current one, it lands, the other widget kept.
      verb!(view, home, :prefs, %{"document" => %{"widgets" => %{"runs" => %{"on" => true}}}})

      assert %{"outcome" => "saved", "revision" => 3, "document" => document} =
               answer!(view, home, "prefs")

      assert document["widgets"] == %{"runs" => %{"on" => true}, "apps" => %{"on" => false}}
    end

    test "a document the schema refuses is refused and leaves the stored one untouched",
         %{conn: conn, ctx: ctx, user: user} do
      view = shell!(conn)
      home = canvas(view).id
      handshake!(view, home)

      for document <- [
            %{"widgets" => %{"weather" => %{"on" => true}}},
            %{"widgets" => %{"runs" => %{"compact" => "yes"}}},
            %{"widgets" => %{"runs" => %{"rect" => %{"x" => 0, "y" => 0, "w" => 0, "h" => 10}}}},
            %{"theme" => "dark"}
          ] do
        verb!(view, home, :prefs, %{"document" => document})

        assert %{"outcome" => "refused", "reason" => "invalid_argument", "revision" => 0} =
                 answer!(view, home, "prefs")
      end

      assert {:none, 0} = stored(ctx, user, "home")
    end

    test "survives the shell's end: the next view hands the frame what was written",
         %{conn: conn} do
      view = shell!(conn)
      home = canvas(view).id
      handshake!(view, home)
      verb!(view, home, :prefs, %{"document" => %{"widgets" => %{"apps" => %{"on" => false}}}})
      assert %{"outcome" => "saved"} = answer!(view, home, "prefs")

      GenServer.stop(view.pid)
      view = shell!(conn)

      assert %{"canvas" => %{"prefs" => %{"revision" => 1, "document" => document}}} =
               handshake!(view, canvas(view).id)

      assert document["widgets"] == %{"apps" => %{"on" => false}}
    end
  end

  # ---- controls ----------------------------------------------------------------

  describe "a declared control" do
    setup %{ctx: ctx, user: user, athanor: athanor} do
      pick = %{"stream" => "schedules.changes", "field" => "/schedule_id", "arg" => "schedule_id"}

      desktop!(ctx, "markets", %{
        "data" => ["schedules.changes"],
        "controls" => [
          %{
            "id" => "pause-schedule",
            "label" => "Pause",
            "operation" => "schedule.pause",
            "pick" => pick
          },
          %{
            "id" => "pause-missing",
            "label" => "Pause",
            "operation" => "schedule.pause",
            "args" => %{"schedule_id" => "sch_nowhere"}
          },
          # Publish refuses a person's own act; this version was laid
          # without publish, so only the shell's own check stands.
          %{
            "id" => "make-schedule",
            "label" => "Make",
            "operation" => "schedule.create",
            "args" => %{"name" => "x"}
          }
        ]
      })

      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      {:ok, digest: schedule!(ctx, user, "digest"), other: schedule!(ctx, user, "other")}
    end

    test "runs through the gate as the person with a value the stream publishes now",
         %{conn: conn, ctx: ctx, digest: digest, other: other} do
      view = shell!(conn)
      home = canvas(view).id

      verb!(view, home, :press, %{"control" => "pause-schedule", "value" => digest.id})

      assert answer!(view, home, "pressed") == %{
               "control" => "pause-schedule",
               "outcome" => "accepted"
             }

      assert status(ctx, digest.id) == "paused"
      assert status(ctx, other.id) == "active"
    end

    test "refuses a value the stream does not publish, a pick without one, an undeclared or indirect control, and says why",
         %{conn: conn, ctx: ctx, digest: digest} do
      view = shell!(conn)
      home = canvas(view).id

      for args <- [
            %{"control" => "pause-schedule", "value" => "sch_not_this_athanors"},
            %{"control" => "pause-schedule"},
            %{"control" => "unknown-control"},
            %{"control" => "make-schedule"},
            %{"control" => "pause-missing", "value" => digest.id}
          ] do
        verb!(view, home, :press, args)

        assert %{"outcome" => "refused", "reason" => "invalid_argument"} =
                 answer!(view, home, "pressed"),
               inspect(args)
      end

      assert status(ctx, digest.id) == "active"
      # Nothing was made either.
      assert {:ok, [_, _]} = Arca.CronSchedule.list(Sanctum.Context.actor(ctx), kind: "schedule")
    end

    test "the gate decides what it reaches: a fixed argument naming nothing of the athanor's is refused by the gate",
         %{conn: conn} do
      view = shell!(conn)
      home = canvas(view).id

      verb!(view, home, :press, %{"control" => "pause-missing"})

      # The schedule tool's own refusal, classified as the gate classifies it.
      {:error, refused} =
        PrismWeb.Ops.call_tool(assigns(view).context, "schedule/pause", %{
          "schedule_id" => "sch_nowhere"
        })

      reason = Atom.to_string(Prima.Refusal.classify(refused).class)
      assert %{"outcome" => "refused", "reason" => ^reason} = answer!(view, home, "pressed")
    end

    test "pressed with no input of the person's it does not run, and is told so",
         %{conn: conn, ctx: ctx, digest: digest} do
      view = shell!(conn)
      home = canvas(view).id

      verb!(view, home, :press, %{"control" => "pause-schedule", "value" => digest.id}, nil)
      assert %{"outcome" => "cancelled"} = answer!(view, home, "pressed")
      assert status(ctx, digest.id) == "active"
    end
  end

  # ---- the chrome -----------------------------------------------------------------

  describe "the chrome" do
    @chrome """
    :root {
      --chrome-ground: #f4f1ea;
      --chrome-surface: #ffffff;
      --chrome-ink: #1d1b16;
      --chrome-accent: #8a3b12;
      --chrome-radius: 4px;
      --chrome-controls: left;
    }
    """

    setup %{ctx: ctx, user: user, athanor: athanor} do
      desktop!(ctx, "styled", %{"chrome" => "chrome.css"}, [{"chrome.css", @chrome}])
      desktop!(ctx, "plain", %{"data" => ["runs.changes"]})

      layout!(user, athanor, [
        entry("home", "tincture:local.styled"),
        entry("work", "tincture:local.plain")
      ])

      :ok
    end

    test "the visible desktop's tokens are worn while it is shown, and Prism's default otherwise",
         %{conn: conn} do
      view = shell!(conn)

      assert_push_event(view, "chrome", %{chrome: chrome})

      assert chrome == %{
               "colours" => %{
                 "ground" => "#f4f1ea",
                 "surface" => "#ffffff",
                 "ink" => "#1d1b16",
                 "accent" => "#8a3b12"
               },
               "lengths" => %{"radius" => 4},
               "keywords" => %{"controls" => "left"}
             }

      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert_push_event(view, "chrome", %{chrome: nil})

      render_hook(view, "switch_canvas", %{"canvas" => "home"})
      assert_push_event(view, "chrome", %{chrome: ^chrome})
    end

    test "a full app over the desktop, the picker's launch among them, takes the chrome off until it closes",
         %{conn: conn, ctx: ctx} do
      app!(ctx, "notes")
      view = shell!(conn)
      assert_push_event(view, "chrome", %{chrome: %{}})

      render_hook(view, "app_open", %{"ref" => "tincture:local.notes"})
      app = Frames.get(frames(view), {:app, "home", "tincture:local.notes"})
      render_hook(view, "frame_full", %{"frame" => app.id})
      assert_push_event(view, "chrome", %{chrome: nil})

      render_hook(view, "frame_close", %{"frame" => app.id})
      assert_push_event(view, "chrome", %{chrome: %{"lengths" => %{"radius" => 4}}})
    end

    test "a desktop that falls back wears Prism's default", %{conn: conn} do
      view = shell!(conn)
      home = canvas(view).id
      assert_push_event(view, "chrome", %{chrome: %{}})

      verb!(view, home, :failed, %{"stage" => "load"}, nil)
      assert_push_event(view, "chrome", %{chrome: nil})
      assert Map.has_key?(assigns(view).fallbacks, "home")
    end
  end

  # ---- ask, settings, open ---------------------------------------------------------

  describe "ask, settings and open" do
    setup %{ctx: ctx, user: user, athanor: athanor} do
      desktop!(ctx, "markets", %{"data" => ["runs.changes"], "prefs" => @prefs})
      app!(ctx, "run-view", %{"subjects" => ["run"]})
      app!(ctx, "plain-view")
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      :ok
    end

    test "ask opens AQUA with Prism's sentence naming a declared widget and the desktop, and nothing else",
         %{conn: conn} do
      view = shell!(conn)
      home = canvas(view).id
      :ok = Cyfr.Bus.subscribe_page(assigns(view).aqua_ask)

      verb!(view, home, :ask, %{"widget" => "runs"})

      assert_receive %Cyfr.Bus.AquaAsk{sentence: sentence}
      assert sentence == "About the runs widget on my home desktop (markets): "

      # A widget the desktop does not declare asks nothing.
      verb!(view, home, :ask, %{"widget" => "weather"})
      refute_receive %Cyfr.Bus.AquaAsk{}, 100
      assert dropped(view) == 1
    end

    test "settings opens a page from Prism's own list, and nothing else", %{conn: conn} do
      view = shell!(conn)
      home = canvas(view).id

      verb!(view, home, :settings, %{"page" => "no_such_page"})
      assert dropped(view) == 1

      verb!(view, home, :settings, %{"page" => "schedules"})
      {path, _flash} = assert_redirect(view)
      assert path =~ "/schedules"
    end

    test "open carries a subject of a kind the app declares to its handshake, and refuses any other",
         %{conn: conn} do
      view = shell!(conn)
      home = canvas(view).id
      subject = %{"kind" => "run", "id" => "exec_0190f3a2"}

      verb!(view, home, :open, %{"ref" => "tincture:local.plain-view", "subject" => subject})
      assert dropped(view) == 1
      refute Frames.get(frames(view), {:app, "home", "tincture:local.plain-view"})

      verb!(view, home, :open, %{"ref" => "tincture:local.run-view", "subject" => subject})
      app = Frames.get(frames(view), {:app, "home", "tincture:local.run-view"})
      assert app.subject == subject
      assert handshake!(view, app.id)["subject"] == subject
    end
  end

  # The person's preferences are written by the shell's `prefs` verb
  # alone: the store's one writer is the component domain's, whose one
  # caller is the shell.
  test "the preferences are written only through the shell's prefs verb" do
    root = Path.expand("../../../../..", __DIR__)

    callers = fn pattern ->
      for path <- Path.wildcard(Path.join(root, "apps/*/lib/**/*.ex")),
          File.read!(path) =~ pattern,
          do: Path.relative_to(path, root)
    end

    assert callers.(~r/CanvasPrefs\.write\b/) == ["apps/cyfr/lib/compendium/desktop.ex"]

    assert callers.(~r/\bput_desktop_prefs\b/) |> Enum.sort() ==
             ["apps/cyfr/lib/compendium.ex", "apps/cyfr/lib/prism_web/live/shell_live.ex"]

    # The positive control: the scan reads the tree.
    assert "apps/cyfr/lib/prism_web/live/shell_live.ex" in callers.(
             ~r/defmodule PrismWeb\.ShellLive/
           )
  end
end
