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
  the refusal. A live frame's credential is renewed before its deadline
  and the new bearer handed over its port, and a frame shown again gets a
  new bearer the same way; a frozen frame is never renewed, and a store
  that cannot answer is tried again until the deadline. The frame's
  messages are shell verbs for a live frame this
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

  # A tincture version in the athanor's tree and its component row, with
  # `frame` as its `tincture.frame` block, granted at revision 1 as the
  # person would grant it (`owner_profile!/3`) unless `granted: false`.
  # Answers the row's release digest.
  defp tincture!(ctx, name, frame \\ %{}, opts \\ []) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "frame" => frame}
    }

    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", name, "1.0.0",
      manifest: manifest,
      files: [{"index.html", "<html><head></head><body>#{name}</body></html>"}]
    )

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

    acknowledged!(ctx)
    if Keyword.get(opts, :granted, true), do: owner_profile!(ctx, name, 1)
    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
    release_digest
  end

  # The rows these fixtures write are the registry's, as a commit would
  # have written them: the root's projection is told it holds them after a
  # row is written and after a unit is laid, so a read derives nothing
  # over them from the units the fixtures commit.
  defp acknowledged!(ctx) do
    actor = Sanctum.Context.actor(ctx)
    {:ok, token} = Arca.StorageProjectionChanges.snapshot(actor, "components")

    {:ok, :acknowledged} =
      Arca.StorageProjectionChanges.replace(actor, "components", token, fn -> :acknowledged end)

    :ok
  end

  defp owner_profile!(ctx, name, revision) do
    policy = ConsentFixtures.empty_policy("tincture:local.#{name}")

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
          shape_digest: :live,
          commit_digest: "sha256:commit",
          blob_digest: Prima.JCS.hash_binary(policy),
          resolved_policy: policy,
          activation: %{"tincture:local.#{name}" => "sha256:act"}
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

  # The renewal the view armed for `frame_id`: its timer and its token.
  defp renewal!(view, frame_id) do
    assert %{^frame_id => {timer, token}} = assigns(view).renewals
    {timer, token}
  end

  # Fire the renewal now, through its timer's own message.
  defp fire!(view, frame_id, deadline, timer, token) do
    Process.cancel_timer(timer)
    send(view.pid, {:frame_renewal, frame_id, deadline, token})
    render(view)
  end

  defp past?(deadline), do: DateTime.compare(deadline, DateTime.utc_now()) == :lt

  # The frame credential's lifetime, installed beside whatever the run
  # installed and restored after.
  defp deadline_setting!(seconds) do
    previous = Arca.PlatformSettings.installed()

    unless Process.get(:settings_restored) do
      Process.put(:settings_restored, true)

      on_exit(fn ->
        if previous,
          do: Arca.PlatformSettings.install_defaults!(previous),
          else: Arca.PlatformSettings.uninstall()
      end)
    end

    Arca.PlatformSettings.install_defaults!(
      Map.put(previous || %{}, "frame_credential_deadline_s", %{default: seconds, stale: :serve})
    )
  end

  # Every session of the person ends `seconds` from now.
  defp expire_sessions_in!(user, seconds) do
    at = DateTime.add(DateTime.utc_now(), seconds, :second)
    sessions = from(s in Arca.Schemas.Session, where: s.user_id == ^user.user_id)
    hashes = Arca.Repo.all(from(s in sessions, select: s.token_hash))
    assert hashes != []
    Arca.Repo.update_all(sessions, set: [expires_at: at])
    Enum.each(hashes, &Sanctum.Caller.invalidate_hash/1)
    at
  end

  # The frame credentials' table cannot be read while `fun` runs.
  defp store_down!(fun) do
    Arca.Repo.query!("ALTER TABLE frame_credentials RENAME TO frame_credentials_unavailable")

    try do
      fun.()
    after
      Arca.Repo.query!("ALTER TABLE frame_credentials_unavailable RENAME TO frame_credentials")
    end
  end

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

    test "a tincture with no grant opens nothing and is asked for its grant", %{
      conn: conn,
      ctx: ctx
    } do
      tincture!(ctx, "plain-dash", %{}, granted: false)
      view = shell!(conn)
      html = open!(view, "plain-dash")

      assert html =~ ~s(data-tincture-state="ungranted")
      refute html =~ "<iframe"
      assert rows() == []
      assert render(view) =~ "Grant tincture:local.plain-dash"
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

  describe "renewal" do
    setup do
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
    end

    test "a live frame's credential is renewed before its deadline and handed over its port",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "long-dash")
      view = shell!(conn)

      open!(view, "long-dash")
      id = frame_id(view, "long-dash")
      old = bearer!(view, id)
      %{deadline: deadline} = frame(view, "long-dash")

      # Armed five minutes before the deadline. Its remaining time is read
      # between two clock reads and each bound is held with the read on its
      # own side, so a stall between the reads widens the bracket and never
      # narrows it (a millisecond is allowed for the timer's rounding).
      {timer, token} = renewal!(view, id)
      before = DateTime.utc_now()
      left = Process.read_timer(timer)
      after_read = DateTime.utc_now()
      assert left <= DateTime.diff(deadline, before, :millisecond) - 300_000 + 1
      assert left >= DateTime.diff(deadline, after_read, :millisecond) - 300_000 - 5_000

      fire!(view, id, deadline, timer, token)

      assert_push_event(view, "frame_bearer", %{frame: ^id, credential: new})
      refute new == old
      assert {:ok, %{frame_id: ^id, deadline: renewed}} = verify(new)
      assert DateTime.compare(renewed, deadline) == :gt
      assert row(id).deadline == renewed
      assert %{state: :live, deadline: ^renewed, bearer: nil} = frame(view, "long-dash")

      # The new bearer is not kept, and only a replacement could carry it.
      refute inspect(assigns(view)) =~ new
      render_hook(view, "frame_handshake", %{"frame" => id})
      assert_reply(view, %{error: "no_credential"})

      # The next renewal is armed for the new deadline; the spent one is gone.
      {next, next_token} = renewal!(view, id)
      refute next_token == token
      assert is_integer(Process.read_timer(next))
    end

    test "a renewal capped by the session's end answers no later deadline and arms nothing more",
         %{conn: conn, ctx: ctx, user: user} do
      tincture!(ctx, "capped-dash")
      view = shell!(conn)

      open!(view, "capped-dash")
      id = frame_id(view, "capped-dash")
      bearer!(view, id)
      %{deadline: deadline} = frame(view, "capped-dash")
      {timer, token} = renewal!(view, id)

      ends = expire_sessions_in!(user, 120)
      fire!(view, id, deadline, timer, token)

      assert_push_event(view, "frame_bearer", %{frame: ^id, credential: new})
      assert {:ok, %{deadline: capped}} = verify(new)
      refute DateTime.compare(capped, ends) == :gt
      assert DateTime.compare(capped, deadline) == :lt
      assert %{state: :live, deadline: ^capped} = frame(view, "capped-dash")
      refute Map.has_key?(assigns(view).renewals, id)
    end

    test "a renewal before the handshake replaces the bearer the handshake hands",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "early-dash")
      view = shell!(conn)

      open!(view, "early-dash")
      id = frame_id(view, "early-dash")
      %{deadline: deadline, bearer: minted} = frame(view, "early-dash")
      {timer, token} = renewal!(view, id)

      fire!(view, id, deadline, timer, token)
      refute_push_event(view, "frame_bearer", %{frame: ^id})

      handed = bearer!(view, id)
      refute handed == minted
      assert {:ok, %{deadline: renewed}} = verify(handed)
      assert DateTime.compare(renewed, deadline) == :gt
    end

    test "a renewal that fires after its frame was frozen renews and resumes nothing",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "front-dash")
      tincture!(ctx, "other-dash")
      view = shell!(conn)

      open!(view, "front-dash")
      front = frame_id(view, "front-dash")
      bearer!(view, front)
      %{deadline: deadline} = frame(view, "front-dash")
      {timer, token} = renewal!(view, front)

      open!(view, "other-dash")
      assert frame(view, "front-dash").state == :frozen
      suspended = row(front)
      assert suspended.state == "suspended"

      # Freezing cancelled the renewal; one that fires all the same acts on
      # nothing.
      assert Process.read_timer(timer) == false
      refute Map.has_key?(assigns(view).renewals, front)
      send(view.pid, {:frame_renewal, front, deadline, token})
      render(view)

      assert row(front) == suspended
      assert frame(view, "front-dash").state == :frozen
      refute_push_event(view, "frame_bearer", %{frame: ^front})
    end

    test "a frame running hidden under a background grant keeps its renewal",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "radio-dash", %{"background" => true})
      tincture!(ctx, "other-dash")
      view = shell!(conn)

      open!(view, "radio-dash")
      radio = frame_id(view, "radio-dash")
      bearer!(view, radio)
      {timer, _token} = renewal!(view, radio)

      open!(view, "other-dash")
      assert %{state: :live, visible: false} = frame(view, "radio-dash")
      assert {^timer, _token} = renewal!(view, radio)
      assert is_integer(Process.read_timer(timer))
    end

    test "a frame shown again after its deadline passed is resumed under a new bearer",
         %{conn: conn, ctx: ctx} do
      deadline_setting!(2)
      tincture!(ctx, "late-dash")
      tincture!(ctx, "other-dash")
      view = shell!(conn)

      open!(view, "late-dash")
      late = frame_id(view, "late-dash")
      old = bearer!(view, late)
      open!(view, "other-dash")
      assert row(late).state == "suspended"

      Prima.Test.Wait.wait_until(
        fn -> past?(row(late).deadline) and verify(old) == {:error, :expired_credential} end,
        5_000,
        "the hidden frame's deadline to pass"
      )

      deadline_setting!(900)
      html = open!(view, "late-dash")

      assert_push_event(view, "frame_bearer", %{frame: ^late, credential: new})
      assert_push_event(view, "frame_state", %{frame: ^late, state: "live"})
      assert %{state: :live, id: ^late, deadline: deadline} = frame(view, "late-dash")
      assert attribute(iframe(html, "late-dash"), "data-frame-state") == "live"
      assert {:ok, %{frame_id: ^late, deadline: ^deadline}} = verify(new)
      assert {:error, :expired_credential} = verify(old)
      assert %{state: "active", deadline: ^deadline} = row(late)
      assert {_timer, _token} = renewal!(view, late)
    end

    test "a renewal the standing refuses revokes the frame and shows the refusal",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "gone-dash")
      view = shell!(conn)

      open!(view, "gone-dash")
      id = frame_id(view, "gone-dash")
      bearer = bearer!(view, id)
      %{deadline: deadline} = frame(view, "gone-dash")
      {timer, token} = renewal!(view, id)

      {:ok, _} = Arca.FrameCredentials.revoke(Sanctum.Context.actor(ctx), row(id).id)
      fire!(view, id, deadline, timer, token)

      assert %{state: :refused, refusal: :refused} = frame(view, "gone-dash")
      assert render(view) =~ ~s(data-tincture-state="refused")
      assert row(id).state == "revoked"
      assert {:error, :revoked} = verify(bearer)
      refute Map.has_key?(assigns(view).renewals, id)
    end

    test "a store that cannot answer is tried again until the deadline, then the row expires",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "far-dash")
      tincture!(ctx, "near-dash")
      view = shell!(conn)

      # Far from its deadline: tried again in thirty seconds.
      deadline_setting!(3_600)
      open!(view, "far-dash")
      far = frame_id(view, "far-dash")
      bearer!(view, far)
      %{deadline: far_deadline} = frame(view, "far-dash")
      far_row = row(far)
      {timer, token} = renewal!(view, far)

      store_down!(fn -> fire!(view, far, far_deadline, timer, token) end)

      assert row(far) == far_row
      assert %{state: :live, deadline: ^far_deadline} = frame(view, "far-dash")
      {retry, retry_token} = renewal!(view, far)
      refute retry_token == token
      assert Process.read_timer(retry) in 25_000..30_000

      # Within thirty seconds of its deadline: nothing more is armed, and
      # the credential expires at its deadline.
      render_click(view, "close_active_tincture", %{})
      deadline_setting!(2)
      open!(view, "near-dash")
      near = frame_id(view, "near-dash")
      near_bearer = bearer!(view, near)
      %{deadline: near_deadline} = frame(view, "near-dash")
      near_row = row(near)
      {timer, token} = renewal!(view, near)

      store_down!(fn -> fire!(view, near, near_deadline, timer, token) end)

      refute Map.has_key?(assigns(view).renewals, near)
      assert %{state: :live, deadline: ^near_deadline} = frame(view, "near-dash")

      Prima.Test.Wait.wait_until(
        fn -> verify(near_bearer) == {:error, :expired_credential} end,
        5_000,
        "the near frame's credential to expire at its deadline"
      )

      assert row(near) == near_row
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

    test "no verb raises a frame: a hidden frame's focus is dropped", %{conn: conn, ctx: ctx} do
      tincture!(ctx, "radio-dash", %{"background" => true})
      tincture!(ctx, "front-dash")
      view = shell!(conn)
      open!(view, "radio-dash")
      radio = frame_id(view, "radio-dash")
      open!(view, "front-dash")

      verb!(view, radio, %{"v" => 1, "verb" => "focus", "frame" => radio, "args" => %{}})

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
