# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CliLiveTest do
  @moduledoc """
  `/cli`, where a person approves a command line's sign-in: session-only,
  so a person not signed in is sent through the sign-in page. The page's
  script hands it the link's secret; the page shows the machine and the
  code the command line shows, and nothing happens until Approve. The
  approval waits on its fresh confirmation, shown with the home's preview
  naming the machine and the code, and is made once the record reads
  confirmed, wherever it was proven: the command line's token is then the
  person's session. A link no sign-in names, an expired one and one
  already used say so and offer no approval.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Sanctum.Context

  setup %{conn: conn} do
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()

    ctx =
      Context.build(
        user_id: user.user_id,
        athanor_id: athanor.id,
        permissions: Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    %{conn: conn, user: user, athanor: athanor, ctx: ctx}
  end

  # A command line's begin, as `cyfr login` makes it: its token and the
  # link's secret.
  defp begin!(machine \\ "laptop") do
    {:ok, begun} = Sanctum.CliSignIn.begin(machine, "198.51.100.90")
    secret = secret_of!(begun.approve_url)
    Map.put(begun, :secret, secret)
  end

  defp status(token) do
    {:ok, %{status: status}} = Sanctum.CliSignIn.poll(token, "198.51.100.90")
    status
  end

  defp open_record!(ctx, operation) do
    {:ok, rows} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)
    assert [%{ref: ref, operation: ^operation}] = rows
    ref
  end

  test "a person not signed in here is sent through the sign-in page" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/cli")
  end

  test "the link's command line is shown, approved under a fresh confirmation, and signed in as the person",
       %{conn: conn, ctx: ctx, user: user} do
    begun = begin!()
    {:ok, view, html} = live(conn, ~p"/cli")
    assert html =~ ~s(phx-hook="CommandLine")
    refute html =~ begun.secret

    html = render_hook(view, "cli_code", %{"code" => begun.secret})
    assert has_element?(view, ~s([data-test="cli-machine"]), "laptop")
    assert has_element?(view, ~s([data-test="cli-code"]), begun.user_code)
    assert has_element?(view, ~s([data-test="cli-sign-in"][data-status="pending"]))
    refute html =~ begun.secret
    assert status(begun.session_token) == "pending"

    # Approve asks for the confirmation and makes nothing yet; its record
    # names the machine and the code, and this page is the asker.
    view |> element(~s([data-test="cli-approve"])) |> render_click()
    ref = open_record!(ctx, "session.cli_approve")
    assert {:ok, %{preview: preview}} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
    assert preview =~ "laptop" and preview =~ begun.user_code
    assert has_element?(view, ~s([data-test="confirmation-preview"]), "session.cli_approve")
    assert has_element?(view, ~s([data-test="confirmation-asker"]), "a browser signed in")
    assert status(begun.session_token) == "pending"

    # Proven elsewhere, by its ref: the page approves it, once.
    Sanctum.TestContext.prove!(ctx, ref)

    wait_until(
      fn -> has_element?(view, ~s([data-test="cli-sign-in"][data-status="approved"])) end,
      2_000,
      "the approval"
    )

    assert has_element?(view, ~s([data-test="cli-notice"]), "signed in")
    refute has_element?(view, ~s([data-test="cli-approve"]))
    assert status(begun.session_token) == "approved"

    assert {:ok, cli_ctx} = Sanctum.Caller.establish(begun.session_token, refresh: false)
    assert cli_ctx.user_id == user.user_id

    Cyfr.Test.Sandbox.end_views()
  end

  test "a link no sign-in names says so, and an address with none says what to open",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cli")

    render_hook(view, "cli_code", %{
      "code" => Prima.Identity.Encoding.b64(:crypto.strong_rand_bytes(16))
    })

    assert has_element?(view, ~s([data-test="cli-notice"]), "not one this home knows")
    refute has_element?(view, ~s([data-test="cli-approve"]))

    {:ok, view, _html} = live(conn, ~p"/cli")
    render_hook(view, "cli_code", %{"code" => nil})
    assert has_element?(view, ~s([data-test="cli-none"]))
    refute has_element?(view, ~s([data-test="cli-approve"]))
  end

  test "cancelling the confirmation leaves the still-pending sign-in to approve again", %{
    conn: conn
  } do
    begun = begin!()
    {:ok, view, _html} = live(conn, ~p"/cli")
    render_hook(view, "cli_code", %{"code" => begun.secret})

    view |> element(~s([data-test="cli-approve"])) |> render_click()
    assert has_element?(view, ~s([data-test="cli-approve"][disabled]))

    view |> element(~s([data-test="confirm-cancel"])) |> render_click()

    wait_until(
      fn -> has_element?(view, ~s([data-test="cli-notice"]), "confirmation was cancelled") end,
      2_000,
      "the cancelled confirmation said on the page"
    )

    assert status(begun.session_token) == "pending"
    assert has_element?(view, ~s([data-test="cli-sign-in"][data-status="pending"]))
    assert has_element?(view, ~s([data-test="cli-approve"]))
    refute has_element?(view, ~s([data-test="cli-approve"][disabled]))

    Cyfr.Test.Sandbox.end_views()
  end

  test "a link withdrawn while the page shows it is refused and offers no approval", %{
    conn: conn
  } do
    begun = begin!()
    {:ok, view, _html} = live(conn, ~p"/cli")
    render_hook(view, "cli_code", %{"code" => begun.secret})
    assert has_element?(view, ~s([data-test="cli-approve"]))

    {:ok, %{status: "cancelled"}} = Sanctum.CliSignIn.cancel(begun.session_token, "198.51.100.90")
    view |> element(~s([data-test="cli-approve"])) |> render_click()

    assert has_element?(view, ~s([data-test="cli-notice"]), "stopped waiting")
    assert has_element?(view, ~s([data-test="cli-sign-in"][data-status="cancelled"]))
    refute has_element?(view, ~s([data-test="cli-approve"]))
  end

  test "an expired link and a used one offer no approval", %{conn: conn, ctx: ctx} do
    expired = begin!()
    hash = Sanctum.Session.token_hash(expired.session_token)

    {1, _} =
      Arca.Repo.update_all(from(c in Arca.Schemas.CliSignIn, where: c.token_hash == ^hash),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

    {:ok, view, _html} = live(conn, ~p"/cli")
    render_hook(view, "cli_code", %{"code" => expired.secret})
    assert has_element?(view, ~s([data-test="cli-sign-in"][data-status="expired"]))
    refute has_element?(view, ~s([data-test="cli-approve"]))

    used = begin!("desk")
    session_ctx = establish_session!(ctx)

    assert {:ok, _} =
             Sanctum.TestContext.confirming(session_ctx, fn ctx ->
               Sanctum.CliSignIn.approve(ctx, used.secret)
             end)

    {:ok, view, _html} = live(conn, ~p"/cli")
    render_hook(view, "cli_code", %{"code" => used.secret})
    assert has_element?(view, ~s([data-test="cli-sign-in"][data-status="approved"]))
    refute has_element?(view, ~s([data-test="cli-approve"]))
  end

  # A session of the person's own, established as a browser's is.
  defp establish_session!(ctx) do
    {:ok, session} =
      Sanctum.TestContext.create_session(%{
        ctx
        | email: "approver@example.com",
          provider: "github"
      })

    {:ok, session_ctx} =
      Sanctum.Caller.establish(session.token, focus: ctx.athanor_id, refresh: false)

    session_ctx
  end

  # The approval secret the link carries in its fragment, the link being
  # this home's `/cli` page.
  defp secret_of!(link) do
    prefix = Sanctum.Person.home() <> "/cli#code="
    assert String.starts_with?(link, prefix), "#{link} is not this home's /cli link"
    String.replace_prefix(link, prefix, "")
  end
end
