# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellFrameTest do
  @moduledoc """
  The shell creates every tincture frame. Its `sandbox` and `allow` are the
  rules' derivation for the capabilities the version declares — never
  `allow-same-origin`, never a token written by hand — and a frame asking
  for a capability it does not declare is not created. Each open mints a
  frame credential bound to the frame id, handed to the frame's bridge
  once; a hidden frame without a background grant is suspended and
  resumed when shown, a discarded one is revoked, and every path that ends
  the view revokes every credential it minted. A suspension that fails
  discards the frame; a resume that fails revokes the credential and shows
  the refusal. The frame's messages are shell verbs for a live frame this
  view holds; anything else — another frame's, a frozen frame's, one that
  would place or raise the frame — is dropped and counted.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Sanctum.Test.ConsentFixtures

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "shell_frame_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      reload_registry()
    end)

    {:ok, conn: conn, user: user, athanor: athanor, ctx: ctx}
  end

  # The registry is one server-wide process; after the test's own checkout
  # is gone its reload runs on a checkout lent to it alone.
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
  # `frame` as its `tincture.frame` block. Answers the row's release digest.
  defp tincture!(ctx, name, frame \\ %{}) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "frame" => frame}
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

  defp owner_profile!(ctx, name, revision) do
    policy = "{}"

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{
          id: "prof_frame_#{name}",
          kind: :owner,
          source_ref: "tincture:local.#{name}",
          label: "owner",
          status: :active
        },
        %{
          id: "cons_frame_#{name}",
          revision: revision,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          blob_digest: Prima.JCS.hash_binary(policy),
          resolved_policy: policy,
          activation: %{}
        }
      )
  end

  defp open!(view, name),
    do: render_click(view, "select_tincture", %{"tincture" => "iframe_#{name}"})

  # The iframe of the frame the shell opened for `name`, as rendered.
  defp iframe(html, name) do
    frame_id = frame_id(html, name)
    [tag] = Regex.run(~r/<iframe[^>]*id="#{frame_id}"[^>]*>/, html)
    tag
  end

  defp attribute(tag, name) do
    case Regex.run(~r/\s#{name}="([^"]*)"/, tag) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp frame_id(view_or_html, name), do: frame(view_or_html, name).id

  defp frame(view_or_html, name) do
    %{frames: frames} = assigns(view_or_html)
    Prism.Frames.get(frames, {:full, "iframe_#{name}"})
  end

  defp opened(view), do: view |> assigns() |> Map.fetch!(:frames) |> Prism.Frames.list()
  defp dropped(view), do: view |> assigns() |> Map.fetch!(:frames) |> Prism.Frames.dropped()

  defp active(view),
    do: view |> assigns() |> Map.fetch!(:frames) |> Prism.Frames.active_tincture()

  # The bearer the bridge is handed for `frame_id`.
  defp bearer!(view, frame_id) do
    render_hook(view, "frame_handshake", %{"frame" => frame_id})
    assert_reply(view, %{credential: bearer})
    bearer
  end

  defp verify(bearer), do: Sanctum.TinctureAuth.verify_frame_credential(bearer)

  defp ended!(view) do
    ref = Process.monitor(view.pid)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
  end

  defp assigns(%Phoenix.LiveViewTest.View{pid: pid}), do: :sys.get_state(pid).socket.assigns
  defp assigns(_html), do: assigns(Process.get(:view))

  defp row(frame_id) do
    Arca.Repo.one(from(f in Arca.Schemas.FrameCredential, where: f.frame_id == ^frame_id))
  end

  defp rows, do: Arca.Repo.all(Arca.Schemas.FrameCredential)

  defp shell!(conn) do
    {view, _html} = mount_athanor(conn, "/tinctures")
    Process.put(:view, view)
    view
  end

  describe "the frame's attributes" do
    test "sandbox and allow are exactly the rules' derivation for the declared capabilities",
         %{conn: conn, ctx: ctx} do
      declared = ["pointer_lock", "fullscreen", "gamepad", "audio_autoplay"]
      tincture!(ctx, "caps-dash", %{"capabilities" => declared})
      tincture!(ctx, "bare-dash")
      view = shell!(conn)

      html = open!(view, "caps-dash")
      tag = iframe(html, "caps-dash")

      {:ok, tokens} = Compendium.tincture_sandbox_tokens(declared)
      {:ok, allow} = Compendium.tincture_allow_attribute(declared)

      assert attribute(tag, "sandbox") |> String.split() |> Enum.sort() ==
               Enum.sort(["allow-scripts", "allow-pointer-lock"])

      assert attribute(tag, "sandbox") == Enum.join(tokens, " ")
      assert attribute(tag, "allow") == allow
      assert allow |> String.split("; ") |> Enum.sort() == ["autoplay", "fullscreen", "gamepad"]

      bare = iframe(open!(view, "bare-dash"), "bare-dash")
      assert attribute(bare, "sandbox") == "allow-scripts"
      assert attribute(bare, "allow") == nil

      for tag <- [tag, bare], token <- Compendium.Tincture.Rules.forbidden_sandbox_tokens() do
        refute attribute(tag, "sandbox") =~ token
      end

      refute render(view) =~ "allow-same-origin"
    end

    test "a capability the declaration does not list is refused" do
      {:ok, declaration} =
        Compendium.tincture_declaration(%{
          "tincture" => %{"frame" => %{"capabilities" => ["pointer_lock"]}}
        })

      assert {:error, {:undeclared_capability, ["fullscreen"]}} =
               Prism.Frames.frame_attributes(declaration, ["pointer_lock", "fullscreen"])

      assert {:ok, %{sandbox: "allow-scripts allow-pointer-lock", allow: ""}} =
               Prism.Frames.frame_attributes(declaration, ["pointer_lock"])
    end

    test "a frame asking for a capability no frame has is not created and mints nothing",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "camera-dash", %{"capabilities" => ["camera"]})
      view = shell!(conn)

      html = open!(view, "camera-dash")

      assert html =~ ~s(data-tincture-state="undeclared")
      refute html =~ "<iframe"
      assert rows() == []
    end
  end

  describe "the frame credential" do
    test "is minted per open with the frame id, handed to the bridge once, and revoked at the end",
         %{conn: conn, ctx: ctx, user: user} do
      release_digest = tincture!(ctx, "cred-dash")
      owner_profile!(ctx, "cred-dash", 3)
      view = shell!(conn)

      html = open!(view, "cred-dash")
      frame_id = frame_id(view, "cred-dash")
      assert Prima.TinctureWire.frame_id?(frame_id)
      assert attribute(iframe(html, "cred-dash"), "data-frame-id") == frame_id

      row = row(frame_id)
      assert row.state == "active"
      assert row.user_id == user.user_id
      assert row.version_digest == release_digest
      assert {row.publisher, row.name, row.version} == {"local", "cred-dash", "1.0.0"}
      assert row.grant_revision == 3

      # The bearer is in no URL and nowhere in the page.
      render_hook(view, "frame_handshake", %{"frame" => frame_id})
      assert_reply(view, %{credential: bearer})
      refute render(view) =~ bearer

      assert {:ok, %{frame_id: ^frame_id, id: id}} =
               Sanctum.TinctureAuth.verify_frame_credential(bearer)

      assert id == row.id

      # A second ask — a reload, another script — gets nothing.
      render_hook(view, "frame_handshake", %{"frame" => frame_id})
      assert_reply(view, %{error: "no_credential"})

      render_hook(view, "frame_handshake", %{"frame" => "frm_not_this_views"})
      assert_reply(view, %{error: "no_credential"})

      # The view ends: every credential it minted is revoked.
      GenServer.stop(view.pid, :normal)
      assert row(frame_id).state == "revoked"
      assert {:error, :revoked} = Sanctum.TinctureAuth.verify_frame_credential(bearer)
    end

    test "the archived-athanor notice ends the view and revokes every credential it minted",
         %{conn: conn, ctx: ctx, athanor: athanor} do
      tincture!(ctx, "arch-dash")
      tincture!(ctx, "arch-other")
      view = shell!(conn)
      open!(view, "arch-dash")
      open!(view, "arch-other")
      ids = [frame_id(view, "arch-dash"), frame_id(view, "arch-other")]
      bearer = bearer!(view, frame_id(view, "arch-other"))

      # The status alone moves, so what revokes is the view, not the
      # transition that archives an athanor.
      {1, _} =
        Arca.Repo.update_all(
          from(a in Arca.Schemas.Athanor, where: a.id == ^athanor.id),
          set: [status: "archived"]
        )

      send(view.pid, %Cyfr.Bus.Notify{athanor_id: athanor.id, kind: :athanor_changed})
      ended!(view)

      for id <- ids, do: assert(row(id).state == "revoked")
      assert {:error, _refused} = verify(bearer)
    end

    test "navigating away ends the view and revokes every credential it minted",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "nav-dash")
      view = shell!(conn)
      open!(view, "nav-dash")
      id = frame_id(view, "nav-dash")
      bearer = bearer!(view, id)
      assert {:ok, _} = verify(bearer)

      old = view.pid
      ref = Process.monitor(old)
      # The client leaves the shell's channel for the next page's; what
      # that page answers is its own.
      _navigated = live_redirect(view, to: athanor_path("/files"))
      assert_receive {:DOWN, ^ref, :process, ^old, _reason}, 5_000

      assert row(id).state == "revoked"
      assert {:error, :revoked} = verify(bearer)
    end

    test "a tincture without an owner consent binds grant revision 0", %{conn: conn, ctx: ctx} do
      tincture!(ctx, "plain-dash")
      view = shell!(conn)
      open!(view, "plain-dash")

      assert row(frame_id(view, "plain-dash")).grant_revision == 0
    end

    test "closing a frame revokes it, and reopening mints a new frame and credential",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "again-dash")
      view = shell!(conn)

      open!(view, "again-dash")
      first = frame_id(view, "again-dash")
      render_click(view, "close_active_tincture", %{})
      assert row(first).state == "revoked"

      open!(view, "again-dash")
      second = frame_id(view, "again-dash")
      refute second == first
      assert row(second).state == "active"
    end
  end

  describe "hidden and shown" do
    setup do
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
    end

    test "a hidden frame without a background grant is suspended, and resumed when shown",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "front-dash")
      tincture!(ctx, "other-dash")
      view = shell!(conn)

      open!(view, "front-dash")
      front = frame_id(view, "front-dash")
      bearer = bearer!(view, front)
      assert {:ok, _} = verify(bearer)

      html = open!(view, "other-dash")
      assert row(front).state == "suspended"
      assert {:error, :suspended} = verify(bearer)
      assert row(frame_id(view, "other-dash")).state == "active"
      assert frame(view, "front-dash").state == :frozen
      assert attribute(iframe(html, "front-dash"), "data-frame-state") == "frozen"
      assert iframe(html, "front-dash") =~ ~r/\sinert[\s>=\/]/
      refute iframe(html, "other-dash") =~ ~r/\sinert[\s>=\/]/
      assert_push_event(view, "frame_state", %{frame: ^front, state: "frozen"})

      open!(view, "front-dash")
      assert frame_id(view, "front-dash") == front
      assert row(front).state == "active"
      assert {:ok, _} = verify(bearer)
      assert frame(view, "front-dash").state == :live
      assert_push_event(view, "frame_state", %{frame: ^front, state: "live"})
      assert row(frame_id(view, "other-dash")).state == "suspended"
    end

    test "a frame with a background grant keeps running hidden", %{conn: conn, ctx: ctx} do
      tincture!(ctx, "radio-dash", %{"background" => true})
      tincture!(ctx, "other-dash")
      view = shell!(conn)

      open!(view, "radio-dash")
      radio = frame_id(view, "radio-dash")
      bearer = bearer!(view, radio)
      open!(view, "other-dash")

      assert row(radio).state == "active"
      assert {:ok, _} = verify(bearer)
      assert %{state: :live, visible: false} = frame(view, "radio-dash")
    end

    test "a frame whose suspension cannot be recorded is discarded, not left running",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "stuck-dash")
      tincture!(ctx, "other-dash")
      view = shell!(conn)

      open!(view, "stuck-dash")
      stuck = frame_id(view, "stuck-dash")

      # A standing transition revoked it while it was shown: the suspension
      # that hiding it asks for is refused.
      {:ok, _} = Arca.FrameCredentials.revoke(Sanctum.Context.actor(ctx), row(stuck).id)

      html = open!(view, "other-dash")
      assert frame(view, "stuck-dash") == nil
      refute html =~ ~s(id="#{stuck}")
      assert Enum.map(opened(view), & &1.tincture_id) == ["iframe_other-dash"]
    end

    test "a frame whose credential was revoked while hidden shows its refusal when shown",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "lost-dash")
      tincture!(ctx, "other-dash")
      view = shell!(conn)

      open!(view, "lost-dash")
      lost = frame_id(view, "lost-dash")
      open!(view, "other-dash")

      {:ok, _} = Arca.FrameCredentials.revoke(Sanctum.Context.actor(ctx), row(lost).id)

      html = open!(view, "lost-dash")
      assert %{id: ^lost, state: :refused, refusal: :refused} = frame(view, "lost-dash")
      assert html =~ ~s(data-tincture-state="refused")
      refute html =~ ~s(<iframe id="#{lost}")
      assert row(lost).state == "revoked"
      assert Enum.count(rows()) == 2
    end

    test "a resume the member cannot make revokes the credential and shows unavailable",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "slotless-dash")
      tincture!(ctx, "other-dash")
      view = shell!(conn)

      open!(view, "slotless-dash")
      id = frame_id(view, "slotless-dash")
      bearer = bearer!(view, id)
      open!(view, "other-dash")
      assert row(id).state == "suspended"

      Arca.ControlPlane.record(:lost)
      html = open!(view, "slotless-dash")

      assert %{state: :refused, refusal: :unavailable} = frame(view, "slotless-dash")
      assert html =~ ~s(data-tincture-state="unavailable")
      assert row(id).state == "revoked"
      assert {:error, :revoked} = verify(bearer)
    end
  end

  describe "shell verbs" do
    setup %{conn: conn, ctx: ctx} do
      tincture!(ctx, "verb-dash")
      view = shell!(conn)
      open!(view, "verb-dash")
      {:ok, view: view, frame: frame_id(view, "verb-dash")}
    end

    defp verb!(view, frame, message),
      do: render_hook(view, "frame_verb", %{"frame" => frame, "message" => message})

    test "title and close act on the frame that sent them", %{view: view, frame: frame} do
      verb!(view, frame, Prima.TinctureWire.shell_message(:title, frame, %{"title" => "Lisbon"}))
      assert Enum.find(assigns(view).tinctures, &(&1.id == "iframe_verb-dash")).title == "Lisbon"

      verb!(view, frame, Prima.TinctureWire.shell_message(:ready, frame))
      verb!(view, frame, Prima.TinctureWire.shell_message(:focus, frame))
      verb!(view, frame, Prima.TinctureWire.shell_message(:close, frame))

      assert opened(view) == []
      assert row(frame).state == "revoked"
      assert dropped(view) == 0
    end

    test "a verb carrying data, another frame's message and an old data request are dropped",
         %{view: view, frame: frame} do
      verb!(view, frame, %{
        "v" => 1,
        "verb" => "ready",
        "frame" => frame,
        "args" => %{"input" => 1}
      })

      verb!(
        view,
        frame,
        Prima.TinctureWire.shell_message(:close, "frm_another_frame_id")
      )

      verb!(
        view,
        "frm_another_frame_id",
        Prima.TinctureWire.shell_message(:close, "frm_another_frame_id")
      )

      verb!(view, frame, %{
        "type" => "cyfr:request",
        "action" => "invoke",
        "id" => "req_1",
        "payload" => %{"reference" => "c:local.x", "input" => %{}}
      })

      render_hook(view, "frame_verb", %{"message" => %{}})

      assert dropped(view) == 5
      assert Enum.map(opened(view), & &1.tincture_id) == ["iframe_verb-dash"]
      assert row(frame).state == "active"
    end

    test "a message that tries to place, size or raise the frame is dropped",
         %{view: view, frame: frame} do
      for message <- [
            %{"v" => 1, "verb" => "place", "frame" => frame, "args" => %{"x" => 0, "y" => 0}},
            %{"v" => 1, "verb" => "resize", "frame" => frame, "args" => %{"width" => 9}},
            %{"v" => 1, "verb" => "focus", "frame" => frame, "args" => %{"x" => 10, "y" => 10}},
            %{"v" => 1, "verb" => "float", "frame" => frame, "args" => %{}}
          ] do
        verb!(view, frame, message)
      end

      assert dropped(view) == 4
      assert %{placement: :full} = frame(view, "verb-dash")
    end

    test "a hidden frame's focus does not raise it", %{conn: conn, ctx: ctx} do
      tincture!(ctx, "radio-dash", %{"background" => true})
      tincture!(ctx, "front-dash")
      view = shell!(conn)
      open!(view, "radio-dash")
      radio = frame_id(view, "radio-dash")
      open!(view, "front-dash")

      verb!(view, radio, Prima.TinctureWire.shell_message(:focus, radio))

      assert active(view) == "iframe_front-dash"
      assert dropped(view) == 1
    end

    test "a frozen frame's verbs act on nothing", %{view: view, frame: frame, ctx: ctx} do
      tincture!(ctx, "cover-dash")
      send(view.pid, :tinctures_refreshed)
      open!(view, "cover-dash")
      assert frame(view, "verb-dash").state == :frozen

      verb!(view, frame, Prima.TinctureWire.shell_message(:close, frame))

      assert frame(view, "verb-dash").state == :frozen
      assert row(frame).state == "suspended"
      assert dropped(view) == 1
    end
  end

  test "the shell builds no ?_t= URL" do
    for file <- ~w(prism_web/live/shell_live.ex prism_web/live/canvas_live.ex prism/frames.ex) do
      source = File.read!(Path.join(:code.priv_dir(:cyfr), "../lib/" <> file))

      refute source =~ "_t="
      refute source =~ "issue_access_token"
      refute source =~ ~s(sandbox="allow-scripts")
      refute source =~ "cyfr:request"
    end
  end
end
