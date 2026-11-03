# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.DeviceUnlockController do
  @moduledoc """
  A protected device's unlock, its browser's last hop
  (`Sanctum.DeviceUnlock`): the box's shell proved the person's unlock on
  its device channel and holds a one-time ticket for the session, and
  sends its browser to `GET /auth/device/complete#<ticket>`. The ticket
  rides in the fragment, which no request carries: the page this route
  answers takes it from the fragment, removes it from the address and its
  history, and posts it with the page's CSRF token to `POST
  /auth/device/complete`, which spends it once and sets the session's
  HttpOnly cookie (`CyfrWeb.SignInResponse`). The GET creates nothing.

  Both answers are `no-store` and `no-referrer`, so neither the page nor
  the way it was reached is kept or passed on. The ticket is bearer
  authority for this brief exchange alone, as a pairing link's fragment
  is; it is bound to no browser. A ticket spent, past its 60 seconds,
  locked before it was spent, held by another member, or of a device
  whose standing ended signs no one in: the page says so, and the shell
  unlocks again.
  """

  use PrismWeb, :controller

  alias CyfrWeb.SignInResponse

  # The box's shell on its own loopback listener, and the session provider
  # its unlock's sessions carry (`tests/fixtures/device_unlock.json`,
  # `exchange.shell`). Its Lock posts there, so the browser names this
  # page's origin, which the shell requires; its confirm opens there with
  # the public ref alone, so the asking page stays and repeats its change.
  @shell_origin "http://127.0.0.1:7340"
  @shell_provider "unlock"

  @doc "Whether `context` is a box's own screen, unlocked by its shell."
  @spec shell?(term()) :: boolean()
  def shell?(%Sanctum.Context{authenticated: true, provider: @shell_provider}), do: true
  def shell?(_context), do: false

  @doc "Where a box's screen locks: its shell's loopback `/lock`, posted to."
  @spec lock_url() :: String.t()
  def lock_url, do: @shell_origin <> "/lock"

  @doc "Where a box's screen confirms the pending change `ref`: its shell's page."
  @spec confirm_url(String.t()) :: String.t()
  def confirm_url(ref) when is_binary(ref),
    do: @shell_origin <> "/confirm?" <> URI.encode_query(%{"ref" => ref})

  @doc "`GET /auth/device/complete`: the page that posts the fragment's ticket."
  def show(conn, _params) do
    conn
    |> private_headers()
    |> put_root_layout(html: {PrismWeb.Layouts, :root})
    |> put_layout(false)
    |> put_view(PrismWeb.DeviceUnlockHTML)
    |> render(:complete, page_title: "Unlocking")
  end

  @doc "`POST /auth/device/complete`: spend the ticket and set the session."
  def redeem(conn, %{"ticket" => ticket}) when is_binary(ticket) do
    conn = private_headers(conn)

    case Sanctum.DeviceUnlock.redeem(ticket) do
      {:ok, %{token: token}} ->
        SignInResponse.respond(conn, :proceed, session: {:token, token})

      {:error, reason} when reason in [:unavailable, :not_owner] ->
        refused(conn, 503, "This CYFR could not open your session just now. Unlock again.")

      {:error, _refused} ->
        refused(conn, 403, "This unlock is no longer valid. Unlock again on this screen.")
    end
  end

  def redeem(conn, _params),
    do:
      refused(
        private_headers(conn),
        403,
        "This unlock is no longer valid. Unlock again on this screen."
      )

  defp private_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  # An unlock refused here is the request's refused decision, recorded once
  # under its sentence with no person or athanor
  # (`CyfrWeb.Plugs.CallIdentity.refused/3`), and answered as a page: the
  # shell's screen, not a sign-in page, is where the person unlocks again.
  defp refused(conn, status, message) do
    conn
    |> CyfrWeb.Plugs.CallIdentity.refused(status, message)
    |> CyfrWeb.MinimalPage.send_page(
      status,
      "Not unlocked",
      "<p>#{CyfrWeb.MinimalPage.h(message)}</p>"
    )
  end
end

defmodule PrismWeb.DeviceUnlockHTML do
  @moduledoc """
  The page `GET /auth/device/complete` answers: a form the console's
  script fills from the fragment and posts (`assets/js/device_unlock.js`).
  """

  use PrismWeb, :html

  @doc false
  def complete(assigns) do
    ~H"""
    <main class="flex min-h-full items-center justify-center p-8">
      <form
        method="post"
        action="/auth/device/complete"
        data-device-unlock
        class="text-center text-sm text-gray-400"
      >
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <input type="hidden" name="ticket" value="" />
        <p>Opening CYFR…</p>
        <noscript>
          <p>This screen needs JavaScript to open CYFR.</p>
        </noscript>
      </form>
    </main>
    """
  end
end
