# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CarryLiveTest do
  @moduledoc """
  `/carry` at the person's own home: a destination named in the fragment
  only fills the form, and only the person's Begin starts a carry; the
  destination's challenge is asserted at once only for an action this tab
  began, and only after a fresh confirmation through the system layer; any
  other challenge waits for Continue and attaches nothing first; a link
  naming no action of the person's signs nothing; the destination's return
  is recorded once and the person goes on to the destination this home's
  row names; the pending carries are listed for Resume or Cancel, and
  nothing a carry signs or carries is shown.
  """
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias Arca.Schemas.{CarryAction, PersonIdentity}
  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry}
  alias Sanctum.{Cipher, CipherAAD}

  @hub "https://hub.example"
  @directory "https://dir.example"

  setup do
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)
    :ok
  end

  # A person signed in at this home, their own home, and enrolled here:
  # their genesis signed by their operational key and accepted.
  defp enrolled!(conn) do
    user = test_user()
    conn = log_in_user(conn, user)
    keys = Arca.Repo.get_by!(PersonIdentity, user_id: user.user_id)

    {:ok, operational} =
      Cipher.decrypt(
        keys.operational_key_sealed,
        CipherAAD.person_key(user.user_id, :operational)
      )

    {recovery, _} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Entry.genesis(
        live_key: keys.live_public_key,
        operational_key: keys.operational_public_key,
        recovery_keys: [recovery],
        directory: @directory
      )

    genesis = Identity.sign(genesis, operational)
    as = %Prima.Actor{user_id: user.user_id}

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as, %{
        kind: "enrollment",
        request_id: "req_#{System.unique_integer([:positive])}",
        user_id: user.user_id,
        identifier: Identity.identifier(genesis),
        directory_url: @directory,
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")
    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "submitted", "accepted")

    ctx = %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user.user_id}
    %{conn: conn, user: user, ctx: ctx}
  end

  defp head(user), do: Arca.Repo.get_by!(PersonIdentity, user_id: user.user_id).head_hash

  defp actions(user) do
    {:ok, rows} = Arca.CarryActions.pending(%Prima.Actor{user_id: user.user_id}, user.user_id)
    rows
  end

  # The person begins a carry to the hub on the page, as their click does.
  defp begin!(view, destination \\ @hub) do
    view |> element("#carry-begin") |> render_submit(%{"destination" => destination})
    assert_push_event(view, "carry:begun", begun)
    begun
  end

  # The hub's challenge for an action, as its `/auth/cyfr` hop writes it.
  defp challenge_fragment(action_id, audience \\ @hub, challenge \\ nil) do
    challenge = challenge || :crypto.strong_rand_bytes(32)

    fragment =
      %{
        "protocol" => Prima.Carry.protocol(),
        "action_id" => action_id,
        "audience" => audience,
        "challenge" => Encoding.b64(challenge)
      }
      |> Encoding.jcs!()
      |> Encoding.b64()

    {fragment, challenge}
  end

  defp return_fragment(action_id, outcome) do
    {:ok, return} = Prima.Carry.Return.new(action_id, outcome)
    Prima.Carry.Return.fragment(return)
  end

  defp open_confirmations(ctx) do
    {:ok, rows} = Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)
    rows
  end

  test "a person not signed in here is sent through the sign-in page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/carry")
  end

  test "a destination in the fragment only fills the form; Begin is the person's, for that one home",
       %{conn: conn} do
    %{conn: conn, user: user} = enrolled!(conn)
    {:ok, view, html} = live(conn, ~p"/carry")
    assert html =~ ~s(data-carry="source")
    assert html =~ "learns this home&#39;s address"

    html = render_hook(view, "carry_destination", %{"destination" => @hub})
    assert html =~ ~s(value="#{@hub}")
    assert actions(user) == []

    # A destination that is no home's origin fills nothing.
    html = render_hook(view, "carry_destination", %{"destination" => "javascript:alert(1)"})
    assert html =~ "names no home"
    assert actions(user) == []

    begun = begin!(view)
    [action] = actions(user)
    assert begun.action_id == action.action_id
    assert begun.destination == @hub
    assert begun.key_epoch == head(user)
    assert "https://hub.example/login#carry=" <> fragment = begun.to

    # The carry the hub reads: this action, to that hub, under this head.
    assert {:ok, %{envelope: envelope}} = Prima.Carry.parse_fragment(fragment)
    assert envelope.action_id == action.action_id
    assert envelope.destination == @hub
    assert envelope.key_epoch == head(user)

    # The pending list shows the carry and nothing it signs or carries.
    html = render(view)
    assert html =~ ~s(id="carry-#{action.action_id}")
    refute html =~ fragment
    Cyfr.Test.Sandbox.end_views()
  end

  test "a link naming no action of the person's begins and signs nothing", %{conn: conn} do
    %{conn: conn, user: user, ctx: ctx} = enrolled!(conn)
    {:ok, view, _html} = live(conn, ~p"/carry")

    {crafted, _} = challenge_fragment("car_nobody")
    html = render_hook(view, "carry_challenge", %{"fragment" => crafted, "own" => true})
    assert html =~ "nothing was signed"

    # An action of theirs, but a challenge from another home than its own
    # destination.
    begun = begin!(view)
    {other, _} = challenge_fragment(begun.action_id, "https://other.example")
    html = render_hook(view, "carry_challenge", %{"fragment" => other, "own" => true})
    assert html =~ "nothing was signed"

    html = render_hook(view, "carry_challenge", %{"fragment" => "not a challenge", "own" => true})
    assert html =~ "could not be read"

    assert open_confirmations(ctx) == []
    assert [%{challenge: nil}] = actions(user)
    Cyfr.Test.Sandbox.end_views()
  end

  test "a challenge for an action this tab began is asked for at once, through the system layer, and the confirmed assertion goes to the destination's callback",
       %{conn: conn} do
    %{conn: conn, user: user, ctx: ctx} = enrolled!(conn)
    {:ok, view, _html} = live(conn, ~p"/carry")
    begun = begin!(view)
    {fragment, challenge} = challenge_fragment(begun.action_id)

    render_hook(view, "carry_challenge", %{"fragment" => fragment, "own" => true})

    # Nothing is signed on the session alone: the request waits on its
    # record, whose preview names the hub and the code it shows.
    assert [%{ref: ref, operation: "person.assert", preview: preview}] = open_confirmations(ctx)
    assert preview =~ Prima.PersonAssertion.comparison_code(challenge)
    assert preview =~ "learns this home"
    wait_until(fn -> render(view) =~ ~s(data-ref="#{ref}") end, 2_000, "the page's own prompt")
    refute render(view) =~ "cnf_"
    assert [%{assertion: nil}] = actions(user)

    Sanctum.TestContext.prove!(ctx, ref)

    assert_push_event(
      view,
      "carry:go",
      %{to: "https://hub.example/login#cyfr=" <> transport},
      2_000
    )

    assert {:ok, decoded} = Prima.Carry.decode_object(transport)
    assert {:ok, %{assertion: assertion}} = Prima.PersonAssertion.open(decoded)
    assert assertion.action_id == begun.action_id
    assert assertion.audience == @hub
    assert assertion.challenge == challenge
    assert [%{phase: "delivered"}] = actions(user)
    Cyfr.Test.Sandbox.end_views()
  end

  test "a challenge for an action this tab did not begin shows Continue first, and attaches nothing before the click",
       %{conn: conn} do
    %{conn: conn, user: user, ctx: ctx} = enrolled!(conn)
    {:ok, view, _html} = live(conn, ~p"/carry")
    begun = begin!(view)
    {fragment, challenge} = challenge_fragment(begun.action_id)

    html = render_hook(view, "carry_challenge", %{"fragment" => fragment, "own" => false})
    assert html =~ ~s(data-test="carry-continue")
    assert [%{challenge: nil}] = actions(user)
    assert open_confirmations(ctx) == []

    # Not now: still nothing attached.
    view |> element("[data-test=carry-continue] button", "Not now") |> render_click()
    refute has_element?(view, "[data-test=carry-continue]")
    assert [%{challenge: nil}] = actions(user)

    render_hook(view, "carry_challenge", %{"fragment" => fragment, "own" => false})
    view |> element("[data-test=carry-continue] button", "Continue") |> render_click()

    assert [%{challenge: attached}] = actions(user)
    assert attached == Encoding.b64(challenge)
    assert [%{operation: "person.assert"}] = open_confirmations(ctx)
    Cyfr.Test.Sandbox.end_views()
  end

  test "the destination's return is recorded once, and an admitted person goes on to the destination this home's row names",
       %{conn: conn} do
    %{conn: conn, user: user} = enrolled!(conn)
    {:ok, view, _html} = live(conn, ~p"/carry")
    begun = begin!(view)

    html =
      render_hook(view, "carry_return", %{
        "fragment" => return_fragment(begun.action_id, :admitted)
      })

    assert html =~ ~s(data-outcome="admitted")
    assert_push_event(view, "carry:forget", %{action_id: action_id})
    assert action_id == begun.action_id
    assert_push_event(view, "carry:go", %{to: "https://hub.example/"})

    assert %{phase: "completed", outcome: "admitted", payload: nil} =
             Arca.Repo.get!(CarryAction, begun.action_id)

    assert actions(user) == []

    # A changed outcome under the same action is refused; nothing moves.
    html =
      render_hook(view, "carry_return", %{
        "fragment" => return_fragment(begun.action_id, :refused)
      })

    assert html =~ "another outcome"
    assert %{outcome: "admitted"} = Arca.Repo.get!(CarryAction, begun.action_id)
    Cyfr.Test.Sandbox.end_views()
  end

  test "a refused return is recorded and says so; nobody is sent anywhere", %{conn: conn} do
    %{conn: conn} = enrolled!(conn)
    {:ok, view, _html} = live(conn, ~p"/carry")
    begun = begin!(view)

    html =
      render_hook(view, "carry_return", %{
        "fragment" => return_fragment(begun.action_id, :refused)
      })

    assert html =~ ~s(data-outcome="refused")
    assert html =~ "did not sign you in"
    refute_push_event(view, "carry:go", %{})
    assert %{outcome: "refused"} = Arca.Repo.get!(CarryAction, begun.action_id)
    Cyfr.Test.Sandbox.end_views()
  end

  test "a return for another person's action records nothing", %{conn: conn} do
    %{conn: theirs} = enrolled!(conn)
    {:ok, their_view, _} = live(theirs, ~p"/carry")
    begun = begin!(their_view)

    %{conn: mine} = enrolled!(build_conn())
    {:ok, view, _} = live(mine, ~p"/carry")

    html =
      render_hook(view, "carry_return", %{
        "fragment" => return_fragment(begun.action_id, :admitted)
      })

    refute html =~ ~s(data-outcome=)
    assert %{phase: "pending", outcome: nil} = Arca.Repo.get!(CarryAction, begun.action_id)
    Cyfr.Test.Sandbox.end_views()
  end

  test "Cancel ends a pending carry; Resume without its challenge here opens the destination's sign-in",
       %{conn: conn} do
    %{conn: conn, user: user} = enrolled!(conn)
    {:ok, view, _html} = live(conn, ~p"/carry")
    first = begin!(view)
    second = begin!(view, "https://other-hub.example")

    view
    |> element("#carry-#{second.action_id} button", "Resume")
    |> render_click()

    assert_push_event(view, "carry:go", %{to: "https://other-hub.example/login"})

    view
    |> element("#carry-#{first.action_id} button", "Cancel")
    |> render_click()

    assert_push_event(view, "carry:forget", %{action_id: cancelled})
    assert cancelled == first.action_id
    assert %{phase: "cancelled", payload: nil} = Arca.Repo.get!(CarryAction, first.action_id)
    assert [%{action_id: left}] = actions(user)
    assert left == second.action_id
    refute has_element?(view, "#carry-#{first.action_id}")
    Cyfr.Test.Sandbox.end_views()
  end

  test "an oversized carry or a refused begin sends nothing", %{conn: conn} do
    %{conn: conn, user: user} = enrolled!(conn)
    {:ok, view, _html} = live(conn, ~p"/carry")

    assert render_hook(view, "carry_oversized", %{}) =~ "nothing was sent"

    html = view |> element("#carry-begin") |> render_submit(%{"destination" => "not a home"})
    assert html =~ "origin"
    refute_push_event(view, "carry:begun", %{})

    {big, _} = challenge_fragment("car_1")

    html =
      render_hook(view, "carry_challenge", %{
        "fragment" => big <> String.duplicate("A", Prima.Carry.max_fragment_bytes()),
        "own" => true
      })

    assert html =~ "nothing was sent"
    assert actions(user) == []
    Cyfr.Test.Sandbox.end_views()
  end
end
