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
  resumed when shown, a discarded one is revoked, and the view's end
  revokes every credential it minted. The frame's messages are shell verbs
  for that frame only; anything else is dropped and counted.
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

  defp frame_id(view_or_html, name) do
    %{frames: frames} = assigns(view_or_html)
    frames["iframe_#{name}"].id
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
               PrismWeb.ShellLive.frame_attributes(declaration, ["pointer_lock", "fullscreen"])

      assert {:ok, %{sandbox: "allow-scripts allow-pointer-lock", allow: ""}} =
               PrismWeb.ShellLive.frame_attributes(declaration, ["pointer_lock"])
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
    test "a hidden frame without a background grant is suspended, and resumed when shown",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "front-dash")
      tincture!(ctx, "other-dash")
      view = shell!(conn)

      open!(view, "front-dash")
      front = frame_id(view, "front-dash")

      open!(view, "other-dash")
      assert row(front).state == "suspended"
      assert row(frame_id(view, "other-dash")).state == "active"

      open!(view, "front-dash")
      assert frame_id(view, "front-dash") == front
      assert row(front).state == "active"
      assert row(frame_id(view, "other-dash")).state == "suspended"
    end

    test "a frame with a background grant keeps running hidden", %{conn: conn, ctx: ctx} do
      tincture!(ctx, "radio-dash", %{"background" => true})
      tincture!(ctx, "other-dash")
      view = shell!(conn)

      open!(view, "radio-dash")
      open!(view, "other-dash")

      assert row(frame_id(view, "radio-dash")).state == "active"
    end

    test "a frame whose credential cannot resume is opened again, with a new credential",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "lost-dash")
      tincture!(ctx, "other-dash")
      view = shell!(conn)

      open!(view, "lost-dash")
      lost = frame_id(view, "lost-dash")
      open!(view, "other-dash")

      # A standing transition revoked it while it was hidden.
      {:ok, _} = Arca.FrameCredentials.revoke(Sanctum.Context.actor(ctx), row(lost).id)

      open!(view, "lost-dash")
      fresh = frame_id(view, "lost-dash")
      refute fresh == lost
      assert row(fresh).state == "active"
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
      verb!(view, frame, Prima.TinctureWire.shell_message(:close, frame))

      assert assigns(view).opened_tinctures == []
      assert row(frame).state == "revoked"
      assert assigns(view).dropped_messages == 0
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

      assert assigns(view).dropped_messages == 5
      assert assigns(view).opened_tinctures == ["iframe_verb-dash"]
      assert row(frame).state == "active"
    end
  end

  test "the shell builds no ?_t= URL" do
    source = File.read!(Path.join(:code.priv_dir(:cyfr), "../lib/prism_web/live/shell_live.ex"))

    refute source =~ "_t="
    refute source =~ "issue_access_token"
    refute source =~ ~s(sandbox="allow-scripts")
    refute source =~ "cyfr:request"
  end
end
