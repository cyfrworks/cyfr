# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.PendingProbe do
  @moduledoc """
  The `_cyfr_pending_probe` cookie and the current-provider read, shared by
  the claim-namespace and legal-accept controllers.

  `EmissaryWeb.AuthController.maybe_stash_pending_probe/3` writes the
  cookie with `encrypt: true`; fetching it `signed:` fails verification
  and reads as nil — the fetch here is the one that matches the write.
  The two controllers used to carry near-identical copies whose no-cookie
  arms disagreed (one always answered `:expired`, the other told a
  never-signed-in person apart), and each hardcoded the provider list.
  """

  import Plug.Conn

  @cookie "_cyfr_pending_probe"

  @doc "The cookie's name — for the one writer in EmissaryWeb."
  def cookie_name, do: @cookie

  @doc """
  Read the stashed IdP access token. `{:ok, conn, token}`, `{:expired,
  conn}` when a session exists but the probe cookie lapsed, or
  `{:not_logged_in, conn}` when there is no session either.

  Callers clear the cookie only on their success path — a failed submit
  re-renders the form and retries with the same token; deleting early
  dooms the retry.
  """
  def pop(conn) do
    conn = fetch_cookies(conn, encrypted: [@cookie])

    case conn.cookies[@cookie] do
      token when is_binary(token) and token != "" ->
        {:ok, conn, token}

      _ ->
        case get_session(conn, EmissaryWeb.SignInResponse.session_key()) do
          token when is_binary(token) and token != "" -> {:expired, conn}
          _ -> {:not_logged_in, conn}
        end
    end
  end

  @doc "Delete the probe cookie (success paths, and dead-cookie cleanups)."
  def clear(conn), do: delete_resp_cookie(conn, @cookie)

  @doc """
  The provider for the current flow: an explicit valid `"provider"` param
  wins; otherwise the session's provider; otherwise the roster's first.
  """
  def current_provider(conn, params \\ %{}) do
    case params do
      %{"provider" => p} ->
        if Sanctum.Auth.DeviceFlow.provider?(p), do: p, else: session_provider(conn)

      _ ->
        session_provider(conn)
    end
  end

  # The session's provider is not caller input to be validated — it is what
  # actually signed this person in, and it is what cyfr.run is being told
  # about them. Filtering it through the device-flow roster (github,
  # google) meant an OIDC deployment reported every one of its people as
  # "github", because `provider?("oidcc")` is false and the fallback is the
  # roster's first entry. The `params` path above still validates, because
  # that value does come from the request.
  defp session_provider(conn) do
    case Sanctum.Caller.peek(get_session(conn, EmissaryWeb.SignInResponse.session_key())) do
      {:ok, %{provider: p}} when is_binary(p) and p != "" -> p
      _ -> default_provider()
    end
  end

  # No session at all: nothing has said who this is, and the claim that
  # follows will fail on its own. The roster's first entry is a placeholder,
  # not a claim about the person.
  defp default_provider, do: hd(Sanctum.Auth.DeviceFlow.providers())
end
