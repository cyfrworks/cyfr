# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellDesktopTest do
  @moduledoc """
  The desktop in the shell, safe mode, the credential verb and the grant
  prompt.

  The shell opens the desktop the person's layout names as a frame placed
  `:desktop`, draws the picker only when no desktop runs, and reads the
  layout again when one of the person's own sessions publishes it. A
  desktop that never sends `ready`, one refused at open and the person's
  own ask enter safe mode, which discards every frame with its credential;
  choosing leaves it and opens only the desktop. A frame's `credential`
  verb is honoured only for a live, visible frame whose version declares
  `vault.create`, and the frame learns only whether an entry was saved.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "shell_desktop_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      reload_registry()
    end)

    {:ok, conn: conn, user: user, athanor: athanor, ctx: ctx}
  end

  defp reload_registry do
    registry = Process.whereis(Prism.TinctureRegistry)

    case Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo) do
      :ok ->
        try do
          Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), registry)
          :ok = Prism.TinctureRegistry.reload()
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Arca.Repo)
        end

      {:already, _} ->
        Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), registry)
        :ok = Prism.TinctureRegistry.reload()
    end
  end

  # A tincture version in the athanor's tree and its component row, with
  # `tincture` merged into its `tincture` block.
  defp tincture!(ctx, name, tincture \\ %{}) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => Map.merge(%{"entry" => "index.html"}, tincture)
    }

    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.Context.actor(ctx),
        ["components", "tinctures", "local", name, "1.0.0"]
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "index.html"), "<html><head></head><body>#{name}</body></html>")

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
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

    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
    release_digest
  end

  defp desktop!(ctx, name \\ "desktop"),
    do: tincture!(ctx, name, %{"frame" => %{"placement" => "desktop"}})

  # The person's own context, as another of their sessions holds it.
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

  defp publish!(ctx, desktop) do
    {:ok, %{revision: revision}} = Compendium.Providers.Layout.read(ctx)

    document = %{
      "version" => 1,
      "postures" => %{
        "desk" => %{"desktop" => desktop, "slots" => [], "floating" => []},
        "hand" => %{"desktop" => desktop, "slots" => [], "floating" => []}
      }
    }

    {:ok, _} =
      Compendium.Providers.Layout.handle("layout", ctx, %{
        "action" => "edit",
        "document" => document,
        "revision" => revision
      })
  end

  defp shell!(conn) do
    {view, _html} = mount_athanor(conn, "/tinctures")
    Process.put(:view, view)
    # The canvas's read and the shell's placing are messages to the view.
    settle!(view, fn -> assigns(view).desktop != :pending end)
    view
  end

  # The canvas reads the layout again through messages the view handles
  # in turn: render until `check` holds, a bounded number of times.
  defp settle!(view, check) do
    Enum.reduce_while(1..200, false, fn _, _ ->
      _ = render(view)

      if check.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  defp assigns(%Phoenix.LiveViewTest.View{pid: pid}), do: :sys.get_state(pid).socket.assigns
  defp frames(view), do: assigns(view).frames
  defp desktop(view), do: Prism.Frames.desktop(frames(view))
  defp opened(view), do: Prism.Frames.list(frames(view))
  defp dropped(view), do: Prism.Frames.dropped(frames(view))

  defp row(frame_id) do
    Arca.Repo.one(from(f in Arca.Schemas.FrameCredential, where: f.frame_id == ^frame_id))
  end

  defp rows, do: Arca.Repo.all(Arca.Schemas.FrameCredential)

  defp open!(view, name),
    do: render_click(view, "select_tincture", %{"tincture" => "iframe_#{name}"})

  defp handshake!(view, frame_id) do
    render_hook(view, "frame_handshake", %{"frame" => frame_id})
    assert_reply(view, %{credential: _bearer})
  end

  defp verb!(view, frame_id, verb, args \\ %{}),
    do:
      render_hook(view, "frame_verb", %{
        "frame" => frame_id,
        "message" => Prima.TinctureWire.shell_message(verb, frame_id, args)
      })

  describe "the desktop" do
    test "is the layout's desktop tincture, opened as a desktop frame, and the picker is not drawn",
         %{conn: conn, ctx: ctx} do
      desktop!(ctx)
      tincture!(ctx, "app-dash")
      view = shell!(conn)

      assert %{placement: :desktop, state: :live, visible: true, tincture_id: "iframe_desktop"} =
               desktop(view)

      html = render(view)
      assert html =~ ~s(data-canvas-place="desktop")
      refute html =~ ~s(id="shell-picker")
      assert row(desktop(view).id).state == "active"
    end

    test "without a desktop tincture installed the picker is drawn", %{conn: conn, ctx: ctx} do
      tincture!(ctx, "app-dash")
      view = shell!(conn)

      assert desktop(view) == nil
      assert render(view) =~ ~s(id="shell-picker")
    end

    test "is frozen while a full frame covers it and live again once it closes",
         %{conn: conn, ctx: ctx} do
      desktop!(ctx)
      tincture!(ctx, "app-dash")
      view = shell!(conn)
      id = desktop(view).id

      open!(view, "app-dash")
      assert %{state: :frozen, visible: false} = desktop(view)
      assert row(id).state == "suspended"
      assert_push_event(view, "frame_state", %{frame: ^id, state: "frozen"})

      render_click(view, "close_active_tincture", %{})
      assert %{id: ^id, state: :live, visible: true} = desktop(view)
      assert row(id).state == "active"
    end

    test "a shown full frame takes everything it covers out of reach, and only that",
         %{conn: conn, ctx: ctx} do
      desktop!(ctx)
      tincture!(ctx, "app-dash")
      view = shell!(conn)

      for covered <- ~w(#chrome-top #chrome-side [data-canvas-place="desktop"]) do
        refute has_element?(view, "#{covered}[inert]"), covered
      end

      open!(view, "app-dash")

      # The chrome and every canvas layer under the full frame.
      for covered <- ~w(#chrome-top #chrome-side [data-canvas-place="desktop"]) do
        assert has_element?(view, "#{covered}[inert]"), covered
      end

      assert has_element?(view, "#chrome-top[inert] #topbar")

      # The full frame and its capsule, the shell's own Safe mode control,
      # the system layer and the assistant's panel stay reachable.
      refute has_element?(view, ~s([data-canvas-place="full"][inert]))
      refute has_element?(view, ~s([inert] button[phx-click="close_active_tincture"]))

      for reachable <- ~w(#shell-safe-mode #system-layer #aqua-panel) do
        assert has_element?(view, reachable), reachable
        refute has_element?(view, "[inert] #{reachable}"), reachable
        refute has_element?(view, "#{reachable}[inert]"), reachable
      end

      render_click(view, "close_active_tincture", %{})

      for covered <- ~w(#chrome-top #chrome-side [data-canvas-place="desktop"]) do
        refute has_element?(view, "#{covered}[inert]"), covered
      end
    end

    test "a layout published by another session of the same person is read again here; another person's is not",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      desktop!(ctx)
      desktop!(ctx, "desktop-two")
      view = shell!(conn)
      assert %{tincture_id: "iframe_desktop"} = desktop(view)

      # Another member of the same athanor arranges their own layout.
      other = test_user()

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(other.user_id, scope: "athanor", athanor_id: athanor.id)

      publish!(person(other, athanor), "tincture:local.desktop-two")
      _ = render(view)
      assert %{tincture_id: "iframe_desktop"} = desktop(view)

      # A payload naming someone else never moves this shell, however it arrives.
      send(view.pid, Cyfr.Bus.LayoutPublished.new(Sanctum.Context.actor(ctx), other.user_id, 9))
      _ = render(view)
      assert %{tincture_id: "iframe_desktop"} = desktop(view)

      # The same person, from another session.
      old = desktop(view).id
      publish!(person(user, athanor), "tincture:local.desktop-two")
      settle!(view, fn -> match?(%{tincture_id: "iframe_desktop-two"}, desktop(view)) end)

      assert %{tincture_id: "iframe_desktop-two", state: :live} = desktop(view)
      assert row(old).state == "revoked"
    end
  end

  describe "safe mode" do
    test "asked for, it revokes every credential the shell minted, draws the picker and the prompt",
         %{conn: conn, ctx: ctx} do
      desktop!(ctx)
      tincture!(ctx, "app-dash")
      view = shell!(conn)
      open!(view, "app-dash")
      minted = Enum.map(opened(view), & &1.id)
      assert length(minted) == 2

      render_click(view, "safe_mode", %{})

      assert opened(view) == []
      for id <- minted, do: assert(row(id).state == "revoked")

      html = render(view)
      assert html =~ ~s(id="shell-picker")
      assert html =~ ~s(data-kind="safe_mode")
      assert html =~ "You turned safe mode on."

      # Nothing launches while it is on, and a second ask is the same safe mode.
      open!(view, "app-dash")
      render_click(view, "safe_mode", %{})
      assert opened(view) == []
    end

    test "choosing leaves it and opens only the desktop", %{conn: conn, ctx: ctx} do
      desktop!(ctx)
      tincture!(ctx, "app-dash")
      view = shell!(conn)
      open!(view, "app-dash")
      render_click(view, "safe_mode", %{})

      view |> element(~s(#system-layer-dialog button[phx-value-offer="retry"])) |> render_click()
      settle!(view, fn -> desktop(view) != nil end)

      assert [%{placement: :desktop, state: :live, tincture_id: "iframe_desktop"}] = opened(view)
      assert assigns(view).safe_mode == nil
      refute render(view) =~ ~s(id="shell-picker")
    end

    test "a desktop that sends ready before its deadline is not safe mode; one that never does is",
         %{conn: conn, ctx: ctx} do
      desktop!(ctx)
      view = shell!(conn)
      id = desktop(view).id
      handshake!(view, id)

      # Ready at nine seconds: before the deadline message.
      verb!(view, id, :ready)
      send(view.pid, {:desktop_deadline, id})
      _ = render(view)
      assert assigns(view).safe_mode == nil
      assert %{id: ^id, state: :live} = desktop(view)

      # A desktop opened again that never says it is ready.
      render_click(view, "safe_mode", %{})
      view |> element(~s(#system-layer-dialog button[phx-value-offer="retry"])) |> render_click()
      settle!(view, fn -> desktop(view) != nil end)
      again = desktop(view).id
      refute again == id
      handshake!(view, again)

      send(view.pid, {:desktop_deadline, again})
      _ = render(view)
      assert %{reason: :not_ready} = assigns(view).safe_mode
      assert opened(view) == []
      assert row(again).state == "revoked"
      assert render(view) =~ "Your desktop did not start."
    end

    test "a stale deadline, for a desktop no longer held, changes nothing", %{
      conn: conn,
      ctx: ctx
    } do
      desktop!(ctx)
      view = shell!(conn)
      send(view.pid, {:desktop_deadline, "frm_not_this_desktop"})
      _ = render(view)
      assert assigns(view).safe_mode == nil
    end

    test "a desktop refused at open is safe mode", %{conn: conn, ctx: ctx} do
      # Named as the layout's desktop, but not declared as one.
      tincture!(ctx, "desktop")
      view = shell!(conn)

      assert %{reason: :not_ready} = assigns(view).safe_mode
      assert opened(view) == []
      assert rows() == []
      assert render(view) =~ ~s(id="shell-picker")
    end
  end

  describe "the credential verb" do
    setup %{ctx: ctx} do
      tincture!(ctx, "keeper-dash", %{"actions" => ["vault.create", "vault.list"]})
      tincture!(ctx, "plain-dash", %{"actions" => ["vault.list"]})
      :ok
    end

    defp full(view, name), do: Prism.Frames.get(frames(view), {:full, "iframe_#{name}"})

    test "from a frame that does not declare vault.create, a hidden frame or a frame this shell did not create, is dropped",
         %{conn: conn} do
      view = shell!(conn)
      open!(view, "plain-dash")
      plain = full(view, "plain-dash").id
      verb!(view, plain, :credential, %{"name" => "api"})
      assert dropped(view) == 1

      open!(view, "keeper-dash")
      keeper = full(view, "keeper-dash").id
      open!(view, "plain-dash")
      # keeper-dash is hidden now: a frozen frame attributes nothing.
      verb!(view, keeper, :credential, %{"name" => "api"})
      assert dropped(view) == 2

      verb!(view, "frm_not_this_shells", :credential, %{"name" => "api"})
      assert dropped(view) == 3

      assert assigns(view).credential_prompts == %{}
      refute render(view) =~ ~s(data-kind="credential_entry")
    end

    test "a hidden frame with a background grant is not asked for either", %{conn: conn, ctx: ctx} do
      tincture!(ctx, "radio-dash", %{
        "actions" => ["vault.create"],
        "frame" => %{"background" => true}
      })

      view = shell!(conn)
      open!(view, "radio-dash")
      radio = full(view, "radio-dash").id
      open!(view, "plain-dash")
      assert %{state: :live, visible: false} = full(view, "radio-dash")

      verb!(view, radio, :credential, %{"name" => "api"})
      assert dropped(view) == 1
      assert assigns(view).credential_prompts == %{}
    end

    test "dismissed, the frame is told only that nothing was saved", %{conn: conn} do
      view = shell!(conn)
      open!(view, "keeper-dash")
      keeper = full(view, "keeper-dash").id

      verb!(view, keeper, :credential, %{"name" => "weather-api"})
      html = render(view)
      assert html =~ ~s(data-kind="credential_entry")
      assert html =~ "weather-api"

      # One prompt per frame at a time.
      verb!(view, keeper, :credential, %{"name" => "another"})
      assert dropped(view) == 1

      view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()
      _ = render(view)

      assert_push_event(view, "frame_credential", payload)
      assert payload == %{frame: keeper, saved: false}
      assert assigns(view).credential_prompts == %{}
    end

    test "refused, the prompt stays open; closed, the frame is told saved: false and nothing else",
         %{conn: conn, user: user, athanor: athanor} do
      {:ok, _} =
        Sanctum.TestContext.create_vault(person(user, athanor), %{
          name: "taken",
          kind: "api_key",
          fields: %{"API_KEY" => "first"}
        })

      view = shell!(conn)
      open!(view, "keeper-dash")
      keeper = full(view, "keeper-dash").id
      verb!(view, keeper, :credential, %{"name" => "taken"})
      [{prompt_id, ^keeper}] = Map.to_list(assigns(view).credential_prompts)

      view
      |> form("#system-layer-credential", %{"prompt_id" => prompt_id, "secret" => "s3c0nd-v4lue"})
      |> render_submit()

      html = render(view)
      assert html =~ "Not done:"
      refute html =~ "s3c0nd-v4lue"
      refute_push_event(view, "frame_credential", _payload, 50)

      view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()
      assert_push_event(view, "frame_credential", %{frame: ^keeper, saved: false} = payload)
      assert Map.keys(payload) |> Enum.sort() == [:frame, :saved]
    end

    # Entering a credential is a sensitive change: from a session with no
    # proof the entry meets the `confirmation_required` signal, the prompt
    # stays open showing it, and the frame hears nothing of a save.
    test "confirmed, the entry meets the confirmation signal: nothing saved, the frame told nothing, never the value",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      open!(view, "keeper-dash")
      keeper = full(view, "keeper-dash").id
      verb!(view, keeper, :credential, %{"name" => "fresh-entry"})
      [{prompt_id, ^keeper}] = Map.to_list(assigns(view).credential_prompts)

      view
      |> form("#system-layer-credential", %{"prompt_id" => prompt_id, "secret" => "v4lue-typed"})
      |> render_submit()

      ctx = person(user, athanor)

      assert {:ok, [%{ref: "cnr_" <> _, operation: "vault.create"}]} =
               Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

      html = render(view)
      assert html =~ "Confirmation required"
      refute html =~ "cnf_"
      refute html =~ "v4lue-typed"
      refute_push_event(view, "frame_credential", _payload, 50)

      assert {:ok, entries} = Sanctum.Vault.list(ctx)
      refute Enum.any?(entries, &(&1.name == "fresh-entry"))
    end
  end

  describe "the grant prompt" do
    # The tincture's one owner profile waits for the person to consent again.
    defp blocked!(ctx) do
      :ok =
        Sanctum.Test.ConsentFixtures.seed_head!(
          ctx,
          %{
            id: "prof_blocked_dash",
            kind: :owner,
            source_ref: "tincture:local.blocked-dash",
            label: "owner",
            status: :needs_consent
          },
          %{
            id: "cons_blocked_dash",
            revision: 1,
            scope: :versionless,
            pinned_version: "",
            invoke_mode: :open_inert,
            shape_digest: "sha256:shape",
            commit_digest: "sha256:commit",
            blob_digest: Prima.JCS.hash_binary("{}"),
            resolved_policy: "{}",
            activation: %{}
          }
        )
    end

    test "a frame refused for want of a grant is offered the grant prompt, and opens once it is confirmed",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "blocked-dash")
      blocked!(ctx)

      view = shell!(conn)
      html = open!(view, "blocked-dash")

      assert %{state: :refused, refusal: :ungranted} =
               Prism.Frames.get(frames(view), {:full, "iframe_blocked-dash"})

      assert html =~ ~s(data-tincture-state="ungranted")
      assert rows() == []

      html = render(view)
      assert html =~ ~s(data-kind="grant")
      assert html =~ "Grant tincture:local.blocked-dash"

      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
      _ = render(view)

      assert %{state: :live} = Prism.Frames.get(frames(view), {:full, "iframe_blocked-dash"})
      assert assigns(view).grant_prompts == %{}
    end

    test "dismissed, the frame keeps showing its refusal", %{conn: conn, ctx: ctx} do
      tincture!(ctx, "blocked-dash")
      blocked!(ctx)

      view = shell!(conn)
      open!(view, "blocked-dash")
      view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()

      assert %{state: :refused, refusal: :ungranted} =
               Prism.Frames.get(frames(view), {:full, "iframe_blocked-dash"})

      assert render(view) =~ "asks for what you have not granted it yet"
      assert rows() == []
    end
  end
end
