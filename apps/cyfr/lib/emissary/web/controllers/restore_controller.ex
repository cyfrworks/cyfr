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

  Every refusal on these routes, the kit's included, is also the
  request's refused decision, recorded once with no person or athanor and
  the code as its reason: restore and the kit decide for themselves, not
  through the gate. Refusals are this route's own JSON, `{"error": code}`:

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

  ## After a declared restore: the kit

  A home restored from a backup (`ARCHITECTURE.md` §6.9) retired every
  session and suspended every passkey and device, so a person with no
  door left recovers with their printed kit, sessionless, and without the
  installation token. The kit's seed stays in the browser: it signs the
  home's challenge (`Prima.Identity.RestoreKit`), and the signature is
  verified against the recovery keys of the person's identity read fresh
  from their directory (`Sanctum.Recovery.kit_proof/2`).

    * `POST /restore/kit/challenge` — `{"identifier": per_…}`: `200
      {"challenge", "restore_id", "expires_at"}`, alive five minutes.
    * `POST /restore/kit` — `{"proof": {…}}`, the signed kit proof:
      `200 {"credential", "expires_at"}`, the kit credential, alive ten
      minutes and while the person's row of the restore stays open.
    * `POST /restore/kit/reenable` — the credential as
      `authorization: Bearer <credential>`, and `{"operation", …}` naming
      one of the four re-enable operations: with no item named, `200
      {"items": […]}`, that class's suspended items; with one
      (`key_id`, `webhook_id`, `client_id`, `passkey_id`), `200
      {"reenabled": …}`. The credential admits these four and nothing else
      (`Sanctum.Caller.establish_kit/2`).

  Their refusals: `404 not_recovering` (the identifier names no enrolled
  person of this home recovering from a restore, or their recovery has
  closed), `422 invalid_proof`, `409 challenge_refused` (not this person's
  held challenge, expired or used), `409 not_a_holder` (no recovery key
  of the identity signed it), `401 invalid_credential`, `403
  operation_not_permitted`, a re-enable's own refusal as `{"error": code,
  "message": sentence}`, and `503` with a `retry-after` header when the
  directory or the store cannot answer or the person's budget is spent.
  """

  use Emissary.Web, :controller

  alias CyfrWeb.Plugs.CallIdentity

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

  @doc "`POST /restore/kit/challenge`."
  def kit_challenge(conn, params) do
    case Sanctum.Recovery.kit_challenge(Map.get(params, "identifier")) do
      {:ok, %{challenge: challenge, restore_id: restore_id, expires_at: expires_at}} ->
        conn
        |> put_status(200)
        |> json(%{
          challenge: challenge,
          restore_id: restore_id,
          expires_at: DateTime.to_iso8601(expires_at)
        })

      {:error, reason} ->
        kit_refuse(conn, reason)
    end
  end

  @doc "`POST /restore/kit`."
  def kit(conn, params) do
    case Sanctum.Recovery.kit_proof(Map.get(params, "proof")) do
      {:ok, %{credential: credential, expires_at: expires_at}} ->
        conn
        |> put_status(200)
        |> json(%{credential: credential, expires_at: DateTime.to_iso8601(expires_at)})

      {:error, reason} ->
        kit_refuse(conn, reason)
    end
  end

  @doc "`POST /restore/kit/reenable`."
  def kit_reenable(conn, params) do
    operation = Map.get(params, "operation")
    args = Map.drop(params, ["operation"])

    with {:ok, ctx, grant} <- Sanctum.Caller.establish_kit(capability(conn), operation),
         {:ok, answer} <- Sanctum.Recovery.kit_reenable(ctx, grant, operation, args) do
      body =
        case answer do
          %{items: items} -> %{items: items}
          reenabled -> %{reenabled: reenabled}
        end

      conn |> put_status(200) |> json(body)
    else
      {:error, reason} -> kit_refuse(conn, reason)
    end
  end

  defp kit_refuse(conn, {:rate_limited, retry_after_ms}),
    do: retry(conn, :rate_limited, "rate_limited", max(div(retry_after_ms + 999, 1000), 1))

  defp kit_refuse(conn, reason) when reason in [:directory_unavailable, :unavailable, :not_owner],
    do: retry(conn, :unavailable, "unavailable", 1)

  defp kit_refuse(conn, %Prima.Refusal{class: class, reason: reason, message: message} = refusal) do
    conn
    |> CallIdentity.refused(refusal)
    |> put_status(refusal_status(class))
    |> json(%{error: Atom.to_string(reason), message: message})
  end

  defp kit_refuse(conn, reason) do
    {status, code} = kit_status(reason)
    conn |> recorded(status, code) |> put_status(status) |> json(%{error: code})
  end

  defp kit_status(:not_recovering), do: {404, "not_recovering"}
  defp kit_status(:invalid_proof), do: {422, "invalid_proof"}
  defp kit_status(:challenge_refused), do: {409, "challenge_refused"}
  defp kit_status(:not_a_holder), do: {409, "not_a_holder"}
  defp kit_status(:invalid_credential), do: {401, "invalid_credential"}
  defp kit_status(:operation_not_permitted), do: {403, "operation_not_permitted"}
  defp kit_status(:not_standing), do: {401, "invalid_credential"}
  defp kit_status(:not_found), do: {404, "not_found"}
  defp kit_status(:revoked), do: {409, "revoked"}
  defp kit_status(:not_suspended), do: {409, "not_suspended"}
  defp kit_status({:not_found, _kind, _id}), do: {404, "not_found"}
  defp kit_status({:invalid_argument, _message}), do: {422, "invalid_argument"}
  defp kit_status(_reason), do: {422, "refused"}

  defp refusal_status(:not_found), do: 404
  defp refusal_status(:unauthenticated), do: 401
  defp refusal_status(:forbidden), do: 403
  defp refusal_status(:conflict), do: 409
  defp refusal_status(_class), do: 422

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
    do: retry(conn, :unavailable, phase, seconds)

  defp refuse(conn, {:limit_reached, _key, _cap}), do: retry(conn, :unavailable, "minted", 60)

  defp refuse(conn, reason) do
    case status(reason) do
      {status, code} ->
        conn |> recorded(status, code) |> put_status(status) |> json(%{error: code})

      nil ->
        retry(conn, :unavailable, "unavailable", 1)
    end
  end

  defp retry(conn, class, phase, seconds) do
    conn
    |> CallIdentity.refused(%Prima.Refusal{class: class, reason: phase, message: phase})
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_status(503)
    |> json(%{status: phase, retry_after: seconds})
  end

  # Restore is an entry path and the kit its own ingress, so every refusal
  # here is the request's refused decision, recorded once under its call id
  # (`CyfrWeb.Plugs.CallIdentity.refused/2`), with no person or athanor,
  # the class its status means on these routes, and its code as the reason.
  defp recorded(conn, status, code),
    do:
      CallIdentity.refused(conn, %Prima.Refusal{class: class(status), reason: code, message: code})

  defp class(401), do: :unauthenticated
  defp class(403), do: :forbidden
  defp class(404), do: :not_found
  defp class(409), do: :conflict
  defp class(422), do: :invalid_argument

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
