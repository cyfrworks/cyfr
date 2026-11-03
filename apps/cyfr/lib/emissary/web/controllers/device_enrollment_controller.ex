# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DeviceEnrollmentController do
  @moduledoc """
  A protected device's enrollment (`Sanctum.DeviceUnlock`): the box's own
  screen, which holds a key a local unlock guards, enrolls it at the
  installation's setup, or as the first method of a person a restore
  brought back, and resumes an enrollment whose answer it lost.
  `tests/fixtures/device_unlock.json` (`exchange.http`) holds the field
  lists.

  Every route is JSON, its body at most 16 KiB, and an entry path: no
  person's session admits it, so each records its own refusals. What
  admits each:

    * `"admission": "setup"` — the installation's setup token in the
      `x-cyfr-setup-token` header, never a URL, query or body field; the
      request log redacts it (`Prima.Sanitizer`).
    * `"admission": "restore"` — on `challenge` and `complete`, the
      `restore` session `POST /restore` or `/restore/reproof` set, as its
      cookie, inside the first-method window that session opened; on
      `resume`, the installation's restore token as
      `authorization: Bearer <token>`, which a lost answer is resumed
      under once the window has spent itself.

  The routes:

    * `POST /device/enrollment/challenge` — `admission`, `device_key`,
      `request_id`, `holder_kind` and `display_name`: `200 {challenge}`,
      the `enroll` challenge, alive 60 seconds.
    * `POST /device/enrollment/complete` — `proof`, and for setup the new
      person's `name` and `recovery_secret`: `200 {certificate,
      recovery?}`, the device's first certificate and, for setup, the
      recovery code until the person says it is saved.
    * `POST /device/enrollment/resume` — `admission`, `device_key` and
      `request_id`: `200 {challenge}`; then `proof` alone: `200
      {certificate, recovery?}`, the committed enrollment's answer again.

  Refusals are `{"error": code}`, with `message` when the code has a
  sentence: `401 invalid_token`, `404 not_found`, `409 setup_closed`,
  `409 first_method_used`, `409 not_restored` (the restore's window
  closed: prove the recovery code again), `422 proof_refused`, `422
  invalid_request`, and `503 unavailable` with a `retry-after` header.
  """

  use Emissary.Web, :controller

  alias CyfrWeb.Plugs.CallIdentity
  alias Prima.DeviceCert
  alias Prima.DeviceCert.Challenge

  @setup_header "x-cyfr-setup-token"

  @doc "`POST /device/enrollment/challenge`."
  def challenge(conn, params) do
    with {:ok, admission} <- admission(conn, params) do
      answer(conn, Sanctum.DeviceUnlock.enrollment_challenge(admission, params))
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc "`POST /device/enrollment/complete`."
  def complete(conn, params) do
    with {:ok, admission} <- admission(conn, params) do
      answer(conn, Sanctum.DeviceUnlock.enroll(admission, Map.take(params, enrolled(admission))))
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc "`POST /device/enrollment/resume`."
  def resume(conn, params) do
    params = Map.take(params, ~w(admission device_key request_id proof))

    case capability(conn, params) do
      {:ok, capability} ->
        answer(conn, Sanctum.DeviceUnlock.resume(capability, proof_alone(params)))

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  # A resume's second step names its proof alone; its admission travels
  # in its first and in the capability.
  defp proof_alone(%{"proof" => proof}), do: %{"proof" => proof}
  defp proof_alone(params), do: params

  defp enrolled({:setup, _token}), do: ~w(proof name recovery_secret)
  defp enrolled({:restore, _ctx}), do: ~w(proof)

  # What admits a challenge or a completion: the setup token, or the
  # restore's own session.
  defp admission(conn, %{"admission" => "restore"}) do
    case get_session(conn, CyfrWeb.SignInResponse.session_key()) do
      token when is_binary(token) ->
        case Sanctum.Caller.establish({:session, token}) do
          {:ok, ctx} -> {:ok, {:restore, ctx}}
          {:error, :unavailable} -> {:error, :unavailable}
          {:error, _refused} -> {:error, :not_restored}
        end

      _none ->
        {:error, :not_restored}
    end
  end

  defp admission(conn, %{"proof" => _proof} = params) when not is_map_key(params, "admission"),
    do: admission(conn, Map.put(params, "admission", proven_admission(params["proof"])))

  defp admission(conn, _params) do
    case get_req_header(conn, @setup_header) do
      [token] when token != "" -> {:ok, {:setup, token}}
      _absent -> {:error, :invalid_token}
    end
  end

  # A completion names its admission in its proof, which the held
  # challenge binds.
  defp proven_admission(%{"admission" => admission}) when is_binary(admission), do: admission
  defp proven_admission(_proof), do: "setup"

  defp capability(conn, %{"admission" => "restore"}), do: restore_token(conn)

  defp capability(conn, %{"proof" => %{"admission" => "restore"}}), do: restore_token(conn)

  defp capability(conn, _params) do
    case get_req_header(conn, @setup_header) do
      [token] when token != "" -> {:ok, {:setup, token}}
      _absent -> {:error, :invalid_token}
    end
  end

  defp restore_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, {:restore, String.trim(token)}}
      _absent -> {:error, :invalid_token}
    end
  end

  defp answer(conn, {:ok, %{challenge: %Challenge{} = challenge}}),
    do: conn |> put_status(200) |> json(%{challenge: Challenge.encode(challenge)})

  defp answer(conn, {:ok, %{certificate: %DeviceCert{} = certificate} = answer}) do
    body = %{certificate: DeviceCert.encode(certificate)}
    body = if answer[:recovery], do: Map.put(body, :recovery, answer.recovery), else: body
    conn |> put_status(200) |> json(body)
  end

  defp answer(conn, {:error, reason}), do: refuse(conn, reason)

  defp refuse(conn, reason) when reason in [:unavailable, :not_owner] do
    conn
    |> CallIdentity.refused(503, "unavailable")
    |> put_resp_header("retry-after", "1")
    |> put_status(503)
    |> json(%{error: "unavailable"})
  end

  defp refuse(conn, %Prima.Refusal{reason: reason, message: message} = refusal) do
    conn
    |> CallIdentity.refused(refusal)
    |> put_status(422)
    |> json(%{error: Atom.to_string(reason), message: message})
  end

  defp refuse(conn, {:invalid_argument, message}) when is_binary(message) do
    conn
    |> CallIdentity.refused(422, "invalid_request")
    |> put_status(422)
    |> json(%{error: "invalid_request", message: message})
  end

  defp refuse(conn, reason) do
    {status, code} = status(reason)
    conn |> CallIdentity.refused(status, code) |> put_status(status) |> json(%{error: code})
  end

  defp status(:invalid_token), do: {401, "invalid_token"}
  defp status(:not_found), do: {404, "not_found"}

  defp status(reason) when reason in [:setup_closed, :first_method_used, :not_restored],
    do: {409, Atom.to_string(reason)}

  defp status(:proof_refused), do: {422, "proof_refused"}
  defp status(_reason), do: {422, "invalid_request"}
end
