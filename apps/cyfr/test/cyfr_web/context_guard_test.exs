# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.ContextGuardTest do
  @moduledoc """
  A console context is held to its standing on every action, not only at
  mount (`CyfrWeb.ContextGuard`).

  Most cases here revoke by writing the rows directly — no announcement,
  no memo drop — which is the delivery a peer can miss. With the freshness
  bound at zero every action revalidates, so what the case then attempts
  is refused on the store's word alone.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query

  alias CyfrWeb.ContextGuard
  alias Phoenix.LiveView.Socket
  alias Sanctum.{Caller, Context}
  alias Sanctum.Tenancy.{Athanors, Members}

  @sanctum_keys [:caller_memo_ttl_ms, :platform_admin_emails]

  setup do
    prev = Map.new(@sanctum_keys, &{&1, Application.get_env(:sanctum, &1)})

    on_exit(fn ->
      Arca.Cache.delete_match({:established, :_, :_, :_})

      for {key, value} <- prev do
        if is_nil(value),
          do: Application.delete_env(:sanctum, key),
          else: Application.put_env(:sanctum, key, value)
      end
    end)

    :ok
  end

  # The caller bound: the establish memo's TTL and the freshness bound
  # alike. The suite runs at 0, where every action revalidates.
  defp bound!(ms), do: Application.put_env(:sanctum, :caller_memo_ttl_ms, ms)

  defp signed_in(conn, user, opts \\ []) do
    conn = log_in_user(conn, user, opts)
    token = Plug.Conn.get_session(conn, session_key())
    {conn, token, Sanctum.Session.token_hash(token)}
  end

  defp delete_session!(hash),
    do: Arca.Repo.delete_all(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash))

  defp expire_session!(hash) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    Arca.Repo.update_all(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash),
      set: [expires_at: past]
    )
  end

  defp drop_seats!(user_id, scope) do
    Arca.Repo.delete_all(
      from(m in Arca.Schemas.Membership, where: m.user_id == ^user_id and m.scope == ^scope)
    )
  end

  defp drop_seat!(user_id, athanor_id) do
    Arca.Repo.delete_all(
      from(m in Arca.Schemas.Membership,
        where: m.user_id == ^user_id and m.athanor_id == ^athanor_id
      )
    )
  end

  defp archive_row!(athanor_id),
    do:
      Arca.Repo.update_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor_id),
        set: [status: "archived"]
      )

  defp group!(user, name) do
    {:ok, group} = Athanors.create_group(user.user_id, "#{name} #{user.namespace}")
    {:ok, _} = Members.ensure(user.user_id, scope: "athanor", athanor_id: group.id)
    group
  end

  defp door_has?(value), do: Enum.any?(Sanctum.Door.Store.list(), &(&1.value == value))

  defp operator!(conn) do
    ops = test_user()
    Application.put_env(:sanctum, :platform_admin_emails, [ops.email])
    {:ok, _} = Members.ensure_platform(ops.user_id)
    {conn, token, hash} = signed_in(conn, ops)
    {ops, conn, token, hash}
  end

  describe "the operator's door, after a revocation nobody heard (§14.7)" do
    test "a captured context and a mounted /settings are both refused, and nothing is written",
         %{conn: conn} do
      {_ops, conn, token, hash} = operator!(conn)
      {:ok, captured} = Caller.establish(token)
      assert captured.platform_admin

      {view, html} = mount_athanor(conn, "/settings")
      assert html =~ "Server allowlist"

      # The grant and the session go with no announcement, and the memo's
      # bound has passed.
      drop_seats!(captured.user_id, "platform")
      delete_session!(hash)
      bound!(0)

      email = "never-#{System.unique_integer([:positive])}@example.com"

      assert {:error, _refused} =
               PrismWeb.Ops.call_tool(captured, "door/allow", %{"value" => email})

      assert {:error, {:redirect, %{to: "/login"}}} =
               render_click(view, "door_allow", %{"value" => email})

      refute door_has?(email)
    end

    test "the grant alone withdrawn: the refreshed context carries no capability to act on",
         %{conn: conn} do
      {_ops, conn, _token, _hash} = operator!(conn)
      {view, _html} = mount_athanor(conn, "/settings")
      ctx = :sys.get_state(view.pid).socket.assigns.context

      drop_seats!(ctx.user_id, "platform")
      bound!(0)

      email = "not-now-#{System.unique_integer([:positive])}@example.com"
      render_click(view, "door_allow", %{"value" => email})

      refute door_has?(email)
      refute :sys.get_state(view.pid).socket.assigns.context.platform_admin
      refute render(view) =~ "Server allowlist"
    end
  end

  describe "a connected mount" do
    test "subscribes before it revalidates: a revocation after authentication and before subscription is read",
         %{conn: conn} do
      # The establish memo holds this session: mount authentication will
      # be answered from it, as if the revocation came after it.
      bound!(60_000)
      {conn, token, hash} = signed_in(conn, test_user())
      {:ok, _} = Caller.establish(token)

      delete_session!(hash)

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, athanor_path("/settings"))
    end

    test "a session inserted while another revocation was being collected is refused when it is announced",
         %{conn: conn} do
      user = test_user()
      {_conn, _token, _hash} = signed_in(conn, user)

      # The revocation collects the hashes it will announce…
      collected = Arca.SessionStorage.hashes_by_user(user.user_id)

      # …a new session lands and mounts a page…
      {late_conn, _token, late_hash} = signed_in(build_conn(), user)
      refute late_hash in collected
      {view, _html} = mount_athanor(late_conn, "/settings")

      # …and the delete takes every row while the announcement names only
      # the hashes it collected.
      {:ok, _} = Arca.SessionStorage.delete_by_user(user.user_id)
      :ok = Sanctum.Session.announce_revoked(user.user_id, collected)

      assert_redirect(view, "/login", 2_000)
    end
  end

  describe "a mounted page" do
    test "a session that expired is refused on its next read", %{conn: conn} do
      {conn, _token, hash} = signed_in(conn, test_user())
      {view, _html} = mount_athanor(conn, "/settings")

      expire_session!(hash)
      bound!(0)

      send(view.pid, :load)
      assert_redirect(view, "/login", 2_000)
    end

    test "a lost seat nobody announced ends the focus, and the page is not moved to another estate",
         %{conn: conn} do
      user = test_user()
      {conn, _token, _hash} = signed_in(conn, user)
      group = group!(user, "Seat")

      {view, _html} = mount_athanor(conn, "/members", group)
      drop_seat!(user.user_id, group.id)
      bound!(0)

      assert {:error, {:redirect, %{to: "/"}}} = render_click(view, "load_members", %{})
    end

    test "an archive nobody announced ends the focus", %{conn: conn} do
      user = test_user()
      {conn, _token, _hash} = signed_in(conn, user)
      group = group!(user, "Archive")

      {view, _html} = mount_athanor(conn, "/settings", group)
      archive_row!(group.id)
      bound!(0)

      send(view.pid, :load)
      assert_redirect(view, "/", 2_000)
    end

    test "a store that cannot answer halts the action with try again, and writes nothing",
         %{conn: conn} do
      user = test_user()
      {conn, _token, _hash} = signed_in(conn, user)
      {view, _html} = mount_athanor(conn, "/settings")
      bound!(0)

      Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")

      html = view |> element("button[phx-click=set_mode][phx-value-mode=lite]") |> render_click()
      assert html =~ "Try again shortly"

      {:ok, row} = Sanctum.Tenancy.Users.get(user.user_id)
      refute Sanctum.Tenancy.Users.prefs(row)["mode"] == "lite"
    end

    test "a component's action is refused, and the page lets go", %{conn: conn} do
      {conn, _token, hash} = signed_in(conn, test_user())
      {view, _html} = mount_athanor(conn, "/settings")

      delete_session!(hash)
      bound!(0)

      view |> with_target("#command-palette") |> render_click("toggle", %{})
      assert_redirect(view, "/login", 2_000)
    end

    test "a nested view's action is refused on its own", %{conn: conn} do
      user = test_user()
      {conn, _token, hash} = signed_in(conn, user)
      {view, _html} = mount_athanor(conn, "/settings")
      bar = find_live_child(view, "topbar")

      delete_session!(hash)
      bound!(0)

      name = "Never #{System.unique_integer([:positive])}"

      assert {:error, {:redirect, %{to: "/login"}}} =
               render_submit(bar, "create_group", %{"name" => name})

      refute Enum.any?(Athanors.list_for_user(user.user_id), &(&1.name == name))
    end

    test "within the bound a context is acted on; the bound runs from its validation, not its reuse",
         %{conn: conn} do
      bound!(1_000)
      {conn, _token, hash} = signed_in(conn, test_user())
      {view, _html} = mount_athanor(conn, "/settings")
      validated_at = :sys.get_state(view.pid).socket.assigns.context.validated_at

      delete_session!(hash)

      # Busy inside the bound: every read goes on with the context as it was.
      for _ <- 1..3 do
        Process.sleep(150)
        send(view.pid, :load)
        assert render(view) =~ "Settings"
        assert :sys.get_state(view.pid).socket.assigns.context.validated_at == validated_at
      end

      # Past the bound from the validation, however recently it was used.
      Process.sleep(700)
      send(view.pid, :load)
      assert_redirect(view, "/login", 2_000)
    end
  end

  test "no socket, nested or not, holds the raw session token", %{conn: conn} do
    user = test_user()
    {conn, token, _hash} = signed_in(conn, user)
    {view, _html} = mount_athanor(conn, "/settings")

    pids =
      [view.pid, find_live_child(view, "topbar").pid, find_live_child(view, "aqua-panel").pid]

    for pid <- pids do
      state = :sys.get_state(pid)
      refute token in Map.values(state.socket.assigns)
      refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ token
    end
  end

  describe "deferred results" do
    defp socket_with(ctx),
      do: %Socket{assigns: %{__changed__: %{}, context: ctx, flash: %{}}}

    test "a result captured under one focus is dropped under another" do
      ctx = Sanctum.TestContext.local()
      tag = ContextGuard.capture(ctx)

      here = socket_with(ctx)
      assert {:delivered, ^here} = ContextGuard.deliver(here, tag, &{:delivered, &1})

      moved = socket_with(%{ctx | athanor_id: "ath_elsewhere"})
      assert {:noreply, ^moved} = ContextGuard.deliver(moved, tag, &{:delivered, &1})

      rebased =
        socket_with(%{
          ctx
          | credential_binding: %{
              source_kind: :session,
              source_id: "x",
              focus_basis: "mem_other",
              user_generation: 1,
              athanor_generation: 1
            }
        })

      assert {:noreply, ^rebased} = ContextGuard.deliver(rebased, tag, &{:delivered, &1})
    end

    test "a page drops a task's answer computed for another focus", %{conn: conn} do
      {conn, _token, _hash} = signed_in(conn, test_user())
      {view, _html} = mount_athanor(conn, "/components")

      pulled = fn -> :sys.get_state(view.pid).socket.assigns.pull_results end

      elsewhere = {"ath_elsewhere", "mem_elsewhere", DateTime.utc_now()}
      send(view.pid, {:deliver, elsewhere, {:pull_complete, "reagent:local.a:1.0.0", {:ok, %{}}}})
      _ = render(view)
      refute Map.has_key?(pulled.(), "reagent:local.a:1.0.0")

      here = ContextGuard.capture(:sys.get_state(view.pid).socket)
      send(view.pid, {:deliver, here, {:pull_complete, "reagent:local.b:1.0.0", {:ok, %{}}}})
      _ = render(view)
      assert Map.has_key?(pulled.(), "reagent:local.b:1.0.0")
    end
  end

  describe "a stream's watch" do
    test "leaves no recheck behind once it ends, whether it stood or was refused", %{conn: conn} do
      {_conn, token, hash} = signed_in(conn, test_user())
      {:ok, ctx} = Caller.establish(token)
      recheck = ContextGuard.recheck_message()

      # Standing: the recheck revalidates and arms the next one; the watch
      # the stream holds last is what it unwatches, and nothing follows.
      watch = ContextGuard.watch(ctx, every: 40)
      assert_receive ^recheck, 1_000
      assert {:ok, watch} = ContextGuard.standing(recheck, watch)
      :ok = ContextGuard.unwatch(watch)
      refute_receive ^recheck, 200

      # Refused at its recheck: no next recheck is armed, and the stream
      # unwatches the watch it held.
      watch = ContextGuard.watch(ctx, every: 40)
      assert_receive ^recheck, 1_000
      delete_session!(hash)
      assert {:refused, :unauthenticated} = ContextGuard.standing(recheck, watch)
      :ok = ContextGuard.unwatch(watch)
      refute_receive ^recheck, 200

      # Ended before its recheck: the armed one is cancelled.
      watch = ContextGuard.watch(ctx, every: 40)
      :ok = ContextGuard.unwatch(watch)
      refute_receive ^recheck, 200
    end
  end

  describe "a bare context (check/1)" do
    test "fresh is used as it is; stale is revalidated; retired is refused", %{conn: conn} do
      bound!(2_000)
      {_conn, token, hash} = signed_in(conn, test_user())
      {:ok, ctx} = Caller.establish(token)

      assert {:ok, ^ctx} = ContextGuard.check(ctx)

      bound!(0)
      assert {:ok, %Context{} = fresh} = ContextGuard.check(ctx)
      assert DateTime.compare(fresh.validated_at, ctx.validated_at) in [:gt, :eq]

      delete_session!(hash)
      assert {:error, :unauthenticated} = ContextGuard.check(ctx)
    end
  end
end
