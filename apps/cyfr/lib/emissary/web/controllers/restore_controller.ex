# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.RestoreController do
  @moduledoc """
  The restore ingress (`Sanctum.Recovery`): an identity brought back onto
  an empty, installation-authorized node from its printed kit. Restore is
  an ingress, not an operation, because no person exists yet to admit
  one, exactly as a first sign-in is.

  Every route takes the installation capability, the deployment's
  `CYFR_RESTORE_TOKEN`, as `authorization: Bearer <token>` and nowhere
  else: never a URL, a query or a body field. Sanctum checks it first, so
  a request without it causes no row, no staged key and no outbound call.
  The kit is the JSON body's `identifier`, `directory_url` and
  `recovery_secret`, which the request log redacts; the body is at most
  16 KiB (`CyfrWeb.Plugs.RawBodyReader`).

    * `POST /restore` — restore, or resume this token's restore. Success
      answers `200 {"status": "completed", "identifier": …}` and sets the
      cookie session to a new session of the restored person, with the
      reserved provider `restore`; the token travels no further.
    * `POST /restore/challenge` — a first-method reproof challenge for this
      token's completed restore: `200 {"challenge": …, "expires_at": …}`,
      alive five minutes.
    * `POST /restore/reproof` — the kit and `challenge` again, for a new
      `restore` session once the first one's window has closed with no
      method installed: answered as `POST /restore` is.

  Refusals are this route's own JSON, `{"error": code}`:

    * `404 restore_disabled` — this node configures no restore token;
    * `401 invalid_token` — the capability is absent or not this node's;
    * `422 invalid_kit` — the kit is malformed; `422 unknown_identity` —
      its directory serves no such identity; `422 not_a_holder` — its seed
      is not one of the identity's recovery kits now;
    * `409 token_claimed` (another restore holds this node, or this
      token's restore is another kit's), `409 token_spent`,
      `409 not_empty` (the node holds a person), `409 superseded` (a later
      recovery replaced the keys this restore introduced), `409 refused`
      (the directory refused the recovery), `409 restored` (a plain retry
      after completion, which issues no session), `409 not_restored`,
      `409 closed` (a first method exists, so no reproof), and
      `409 challenge_refused`;
    * `503 {"status": phase, "retry_after": seconds}` — the restore stands
      at `phase` and resumes under the same token, with a `retry-after`
      header.
  """

  use Emissary.Web, :controller

  @kit_fields ["identifier", "directory_url", "recovery_secret"]

  @doc "`POST /restore`."
  def restore(conn, params) do
    answer(conn, Sanctum.Recovery.restore(Map.take(params, @kit_fields), capability(conn)))
  end

  @doc "`POST /restore/challenge`."
  def challenge(conn, _params) do
    case Sanctum.Recovery.restore_challenge(capability(conn)) do
      {:ok, %{challenge: challenge, expires_at: expires_at}} ->
        conn
        |> put_status(200)
        |> json(%{challenge: challenge, expires_at: DateTime.to_iso8601(expires_at)})

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  @doc "`POST /restore/reproof`."
  def reproof(conn, params) do
    answer(
      conn,
      Sanctum.Recovery.reproof(Map.take(params, ["challenge" | @kit_fields]), capability(conn))
    )
  end

  # The session goes to the holder of the capability, in its cookie alone,
  # on a session cleared of whatever the browser carried before.
  defp answer(conn, {:ok, %{session_token: token, identifier: identifier}}) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(CyfrWeb.SignInResponse.session_key(), token)
    |> put_status(200)
    |> json(%{status: "completed", identifier: identifier})
  end

  defp answer(conn, {:error, reason}), do: refuse(conn, reason)

  defp capability(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      _absent -> nil
    end
  end

  defp refuse(conn, {:retry, phase, seconds}) when is_binary(phase) and is_integer(seconds),
    do: retry(conn, phase, seconds)

  defp refuse(conn, {:limit_reached, _key, _cap}), do: retry(conn, "minted", 60)

  defp refuse(conn, reason) do
    case status(reason) do
      {status, code} -> conn |> put_status(status) |> json(%{error: code})
      nil -> retry(conn, "unavailable", 1)
    end
  end

  defp retry(conn, phase, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_status(503)
    |> json(%{status: phase, retry_after: seconds})
  end

  defp status(:restore_disabled), do: {404, "restore_disabled"}
  defp status(:invalid_token), do: {401, "invalid_token"}

  defp status(reason) when reason in [:invalid_kit, :unknown_identity, :not_a_holder],
    do: {422, Atom.to_string(reason)}

  defp status(reason)
       when reason in [
              :token_claimed,
              :token_spent,
              :not_empty,
              :superseded,
              :refused,
              :restored,
              :not_restored,
              :closed,
              :challenge_refused
            ],
       do: {409, Atom.to_string(reason)}

  defp status(_reason), do: nil
end
