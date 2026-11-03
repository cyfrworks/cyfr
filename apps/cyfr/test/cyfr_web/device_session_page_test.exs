# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.DeviceSessionPageTest do
  @moduledoc """
  A page mounted under a protected device's session ends at that
  session's deadline unasked, with no action and no announcement
  (`CyfrWeb.ContextGuard`), and one whose device's channel slid the
  session stays. Its Lock posts to the shell's loopback `/lock` from a
  page whose referrer policy keeps the Origin header the shell requires.
  """

  use PrismWeb.ConnCase, async: false

  import Cyfr.Test.ProtectedDevice
  import Ecto.Query

  @token String.duplicate("2d", 32)

  setup do
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()

    on_exit(fn ->
      Prima.Test.RateLimiter.reset!()
    end)

    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()
    Arca.Repo.delete_all(Arca.Schemas.User)
    device = enrolled!(@token)
    ctx = connected!(device)
    answer = unlocked!(ctx, device.key)
    {:ok, %{token: token}} = Sanctum.DeviceUnlock.redeem(answer.ticket)
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(ctx.athanor_id)
    %{ctx: ctx, session_id: answer.session_id, token: token, athanor: athanor}
  end

  defp ends_in!(session_id, ms) do
    at = DateTime.add(DateTime.utc_now(), ms, :millisecond)

    Arca.Repo.update_all(from(s in Arca.Schemas.Session, where: s.id == ^session_id),
      set: [expires_at: at]
    )
  end

  test "a mounted page ends at its device session's deadline, unasked", %{
    conn: conn,
    session_id: session_id,
    token: token,
    athanor: athanor
  } do
    ends_in!(session_id, 1_500)
    expires_at = Arca.Repo.get!(Arca.Schemas.Session, session_id).expires_at
    conn = Plug.Test.init_test_session(conn, %{session_key() => token})
    {:ok, view, _html} = live(conn, athanor_path("/settings", athanor))

    # The page holds a recheck armed for its session's own deadline, which
    # no event or announcement need reach.
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    assert {^expires_at, timer} = assigns[:context_deadline]
    assert Process.read_timer(timer) <= 1_600

    assert_redirect(view, "/login", 4_000)
  end

  test "the Lock posts to the shell from a page that keeps its Origin", %{
    conn: conn,
    token: token,
    athanor: athanor
  } do
    conn = Plug.Test.init_test_session(conn, %{session_key() => token})
    page = get(conn, athanor_path("/settings", athanor))
    [policy] = get_resp_header(page, "referrer-policy")
    refute policy in ["no-referrer", "same-origin"]

    html = html_response(page, 200)
    lock = PrismWeb.DeviceUnlockController.lock_url()
    assert [form] = Regex.run(~r/<form[^>]*data-test="device-lock"[^>]*>/, html)
    assert form =~ ~s(method="post")
    assert form =~ ~s(action="#{lock}")
    refute form =~ "rel="
    refute form =~ "referrerpolicy"
  end

  test "a page whose device's channel slid its session stays", %{
    conn: conn,
    ctx: ctx,
    session_id: session_id,
    token: token,
    athanor: athanor
  } do
    # Room for the mount and the slide on a loaded host; what is held is
    # that the page outlives the deadline it was mounted under.
    ends_in!(session_id, 3_000)
    deadline = Arca.Repo.get!(Arca.Schemas.Session, session_id).expires_at
    conn = Plug.Test.init_test_session(conn, %{session_key() => token})
    {:ok, view, _html} = live(conn, athanor_path("/settings", athanor))
    {:ok, [^session_id]} = Sanctum.DeviceUnlock.slide(ctx, [session_id])

    past = DateTime.diff(deadline, DateTime.utc_now(), :millisecond) + 500
    if past > 0, do: Process.sleep(past)
    assert render(view) =~ "Settings"
  end
end
