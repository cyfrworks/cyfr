# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.TopbarLiveTest do
  @moduledoc """
  The topbar: the AQUA link to the person's own athanor, standing alone;
  the operator's door chip; the live indicators; and the count of files
  offered to the person, from their own topic.
  """
  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  # The topbar is a nested LiveView; find it inside the page.
  defp topbar(view), do: find_live_child(view, "topbar")

  # The indicators the bar has been told to reload but has not reloaded yet.
  defp pending(bar), do: :sys.get_state(bar.pid).socket.assigns.refresh_pending

  # The indicators marked once the bar has handled `events`, read before
  # anything else reaches it. The bar is held while the events and the read
  # queue behind one another, so the refresh timer the first event arms
  # cannot fire between them however slowly this process is scheduled.
  defp pending_after(bar, events) do
    ref = make_ref()
    true = :erlang.suspend_process(bar.pid)
    for event <- events, do: send(bar.pid, event)
    # What `:sys.get_state/1` sends, queued here behind the events.
    send(bar.pid, {:system, {self(), ref}, :get_state})
    true = :erlang.resume_process(bar.pid)
    assert_receive {^ref, {:ok, state}}, 30_000
    state.socket.assigns.refresh_pending
  end

  test "the AQUA link stands alone: it opens the person's own AQUA, and no athanor list opens",
       %{conn: conn} do
    conn = log_in_user(conn, test_user())
    {view, _html} = mount_athanor(conn, "")
    bar = topbar(view)

    assert has_element?(bar, ~s(#aqua-link[href="/a/@#{seated_athanor().slug}/aqua"]), "AQUA")
    refute has_element?(bar, ~s([phx-value-name="athanors"]))
  end

  test "the bar names the person as people are named, never by their id", %{conn: conn} do
    # No name, no email and no name at cyfr.run yet.
    unnamed = test_user(email: nil)
    {view, _html} = conn |> log_in_user(unnamed, claim: false) |> mount_athanor("")
    bar = topbar(view)

    assert has_element?(bar, ~s(button[phx-value-name="user"]), "someone")
    refute render(bar) =~ unnamed.user_id

    named = test_user(name: "Mira Ito")
    {view, _html} = build_conn() |> log_in_user(named) |> mount_athanor("")

    assert has_element?(topbar(view), ~s(button[phx-value-name="user"]), "Mira Ito")
  end

  test "an operator sees how many wait at the door; the chip follows the door", %{conn: conn} do
    ops = test_user()
    conn = log_in_user(conn, ops)
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)

    {view, _html} = mount_athanor(conn, "")
    bar = topbar(view)
    refute has_element?(bar, "#door-requests")

    identifier = "per_" <> Prima.Digest.sha256_hex("carol-#{ops.namespace}")
    {:ok, :created, _} = Sanctum.Door.Store.request("identifier", identifier, ops.user_id)
    Sanctum.Notify.allowlist_request(identifier)
    :sys.get_state(bar.pid)
    assert render(bar) =~ "1 request"

    [%{id: id}] = Sanctum.Door.Store.requests()

    ctx =
      Sanctum.Context.build(
        user_id: ops.user_id,
        athanor_id: seated_athanor().id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true,
        platform_admin: true
      )

    assert {:ok, _} =
             Sanctum.Gate.call_external("door", ctx, %{
               "action" => "resolve",
               "id" => id,
               "decision" => "reject"
             })

    :sys.get_state(bar.pid)
    refute has_element?(bar, "#door-requests")
  end

  test "a burst of telemetry costs one round of reads, not one per event", %{conn: conn} do
    conn = log_in_user(conn, test_user())
    {view, _html} = mount_athanor(conn, "")
    bar = topbar(view)

    # Whatever the mount set off has drained, so no refresh is already due
    # when the burst lands.
    wait_until(fn -> Enum.empty?(pending(bar)) end, 2_000, "the mount's refresh to drain")

    # Coalesce bursts of telemetry into one reload.
    actor = Prima.Actor.in_athanor(seated_athanor().id)
    burst = for _ <- 1..10, do: Cyfr.Bus.Request.new(actor, :logged)

    # All ten have been seen and none has been served — that is the whole
    # claim. The two indicators a request invalidates are marked once.
    assert pending_after(bar, burst) == MapSet.new([:requests, :log_stats])

    # One timer drains the set, and only `:do_refresh` empties it.
    wait_until(fn -> Enum.empty?(pending(bar)) end, 2_000, "the coalesced refresh to drain")

    # And the window re-arms: a burst after a drain is coalesced too, rather
    # than the bar going unthrottled or silent for the rest of the session.
    burst = for _ <- 1..5, do: Cyfr.Bus.Execution.new(actor, :started)
    assert pending_after(bar, burst) == MapSet.new([:executions])

    wait_until(fn -> Enum.empty?(pending(bar)) end, 2_000, "the second burst to drain")
  end

  for {who, kind} <- [{"feed", "feed"}, {"schedule", "schedule"}] do
    test "a #{who}'s fire shows its request in flight", %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)

      # The live indicators are dev's; a person lands in lite unless they
      # chose dev.
      {:ok, row} = Sanctum.Tenancy.Users.get(user.user_id)
      {:ok, _} = Sanctum.Tenancy.Users.put_prefs(row, %{"mode" => "dev"})
      {view, _html} = mount_athanor(conn, "")
      bar = topbar(view)
      wait_until(fn -> Enum.empty?(pending(bar)) end, 2_000, "the mount's refresh to drain")
      render_click(bar, "toggle_popover", %{"name" => "activity"})
      assert render(bar) =~ "In-flight requests (0)"

      athanor_id = seated_athanor().id

      ctx = %{
        Sanctum.TestContext.local(:prism)
        | athanor_id: athanor_id,
          request_id: Prima.UUID7.request_id()
      }

      fire =
        Prima.Decision.new(
          call_id: Prima.UUID7.generate_id("call"),
          request_id: ctx.request_id,
          user_id: ctx.user_id,
          athanor_id: athanor_id,
          plane: :external,
          tool: "schedule",
          action: "fire",
          inserted_at: DateTime.utc_now(),
          admission: :admitted
        )

      :ok = Sanctum.Decisions.open(ctx, fire, %{method: "cron/fire", input: %{}})
      assert render(bar) =~ "In-flight requests (0)"

      :telemetry.execute([:cyfr, :schedules, :fired], %{}, %{
        athanor_id: athanor_id,
        schedule_id: "sch_or_feed_1",
        kind: unquote(kind),
        occurrence_id: "occ_1",
        execution_id: "exec_1"
      })

      wait_until(
        fn -> render(bar) =~ "In-flight requests (1)" end,
        5_000,
        "the fire's request to show in flight"
      )
    end
  end

  test "a badge counts the offers waiting for the person, on each of their browsers, as they " <>
         "come and go",
       %{conn: conn} do
    rita = test_user(name: "Rita")
    conn = log_in_user(conn, rita)
    home = seated_athanor()
    # A second browser of the same person: a session of its own.
    other = log_in_user(Phoenix.ConnTest.build_conn(), rita)

    sam = test_user(name: "Sam")
    sams = Sanctum.Test.People.athanor!(sam.user_id)
    together!(sam, rita)

    sam_ctx = session(sam.user_id, sams.id)
    :ok = Arca.ensure_roots(Sanctum.Context.actor(sam_ctx))

    for name <- ~w(a.txt b.txt c.txt),
        do: :ok = Arca.put(Sanctum.Context.actor(sam_ctx), ["data", name], name)

    offer = fn paths ->
      {:ok, %{offer_id: offer_id}} =
        Sanctum.Gate.call_external("file", sam_ctx, %{
          "action" => "offer",
          "paths" => paths,
          "to" => rita.user_id
        })

      offer_id
    end

    bars =
      for browser <- [conn, other] do
        {view, _html} = mount_athanor(browser, "/settings", home)
        topbar(view)
      end

    for bar <- bars, do: refute(has_element?(bar, "#file-offers"))

    # One offer of two files is one offer, heard by every browser.
    first = offer.(["data/a.txt", "data/b.txt"])

    for bar <- bars do
      :sys.get_state(bar.pid)
      assert has_element?(bar, "#file-offers", "1 offer")
    end

    _second = offer.(["data/c.txt"])

    for bar <- bars do
      :sys.get_state(bar.pid)
      assert has_element?(bar, "#file-offers", "2 offers")
    end

    # Declined, it waits no longer; the other still does.
    assert {:ok, %{status: "declined"}} =
             Sanctum.Gate.call_external("file", session(rita.user_id, home.id), %{
               "action" => "decline",
               "offer_id" => first
             })

    for bar <- bars do
      :sys.get_state(bar.pid)
      assert has_element?(bar, "#file-offers", "1 offer")
      refute has_element?(bar, "#file-offers", "2 offers")
    end
  end

  test "an offer past its expiry counts for nothing before the sweep removes it", %{conn: conn} do
    rita = test_user(name: "Rita")
    conn = log_in_user(conn, rita)
    home = seated_athanor()

    sam = test_user(name: "Sam")
    sams = Sanctum.Test.People.athanor!(sam.user_id)
    together!(sam, rita)

    sam_ctx = session(sam.user_id, sams.id)
    :ok = Arca.ensure_roots(Sanctum.Context.actor(sam_ctx))

    for name <- ~w(a.txt b.txt),
        do: :ok = Arca.put(Sanctum.Context.actor(sam_ctx), ["data", name], name)

    offer = fn path ->
      {:ok, %{offer_id: offer_id}} =
        Sanctum.Gate.call_external("file", sam_ctx, %{
          "action" => "offer",
          "paths" => [path],
          "to" => rita.user_id
        })

      offer_id
    end

    # Still `offered`, its expiry passed, and no sweep has run.
    expired = offer.("data/a.txt")

    {1, _} =
      Arca.Repo.update_all(
        from(o in Arca.Schemas.FileOffer, where: o.offer_id == ^expired),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

    {view, _html} = mount_athanor(conn, "/settings", home)
    bar = topbar(view)
    :sys.get_state(bar.pid)
    refute has_element?(bar, "#file-offers")

    # A live offer beside it is counted alone.
    _live = offer.("data/b.txt")
    :sys.get_state(bar.pid)
    assert has_element?(bar, "#file-offers", "1 offer")
    refute has_element?(bar, "#file-offers", "2 offers")
  end

  # A shared thread seating `from` and `to`, where an offer between them
  # may be made.
  defp together!(from, to) do
    {:ok, thread} = Sanctum.SharedThreads.create(from.user_id, "Plans #{from.namespace}")
    {:ok, :added} = Sanctum.SharedThreads.add(from.user_id, thread.id, user_id: to.user_id)
    thread
  end

  defp session(user_id, athanor_id) do
    Sanctum.Context.build(
      user_id: user_id,
      athanor_id: athanor_id,
      permissions: Sanctum.Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end
end
