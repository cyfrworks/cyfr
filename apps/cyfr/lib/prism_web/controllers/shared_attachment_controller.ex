# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SharedAttachmentController do
  @moduledoc """
  The bytes of a file said in a shared thread, for a person seated in it:
  `GET /shared/:thread/attachments/:message_id/:filename`, where the last
  segment is the file's STORED name (`<n>-<name>`).

  The session cookie names the person, established before anything of
  the thread is read: a visitor with no standing session is sent to sign
  in whether the thread exists or not. No athanor is focused — a shared
  thread is no athanor's. The seat, the message and the file are
  `Sanctum.SharedThreads.attachment/4`'s, which reads the blob only for a
  person seated in the thread and rebuilds its path from the message's
  identity, never from the URL; a person without a seat gets the 404 a
  missing file gets. What comes back is a download with a content type
  from a short allowlist (anything else is `application/octet-stream`),
  `nosniff`, and no caching — the poster's declared type is not trusted
  to be inert.
  """

  use PrismWeb, :controller

  # Types a browser may render inline safely; everything else downloads as
  # opaque bytes. Never text/html or image/svg+xml — both run script.
  @inline_types ~w(image/png image/jpeg image/gif image/webp application/pdf text/plain text/csv application/json)

  def show(conn, %{"thread" => thread_id, "message_id" => message_id, "filename" => stored}) do
    token = get_session(conn, CyfrWeb.SignInResponse.session_key())

    case CyfrWeb.ContextGuard.authenticate(token) do
      {:ok, %Sanctum.Context{user_id: user_id}} when is_binary(user_id) ->
        serve(conn, Sanctum.SharedThreads.attachment(user_id, thread_id, message_id, stored))

      {:ok, _no_person} ->
        redirect(conn, to: PrismWeb.AuthHelpers.sign_in_path())

      {:error, refusal} ->
        case PrismWeb.AuthHelpers.disposition(refusal) do
          :company_login -> redirect(conn, to: "/company-login")
          :unavailable -> send_resp(conn, 503, "Try again shortly")
          _sign_in -> redirect(conn, to: PrismWeb.AuthHelpers.sign_in_path())
        end
    end
  end

  # Every refusal but an unanswered store is the missing file's: a thread
  # the person does not sit in, a message it does not hold, a file the
  # message does not carry.
  defp serve(conn, {:ok, file}) do
    conn
    |> put_resp_header("content-type", serve_type(file.media_type))
    |> put_resp_header("content-disposition", disposition(file.filename))
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", "private, no-store")
    |> send_resp(200, file.bytes)
  end

  defp serve(conn, {:error, {:unavailable, _what}}), do: send_resp(conn, 503, "Try again shortly")
  defp serve(conn, {:error, _missing}), do: send_resp(conn, 404, "Not found")

  defp serve_type(type) when type in @inline_types, do: type
  defp serve_type(_), do: Prima.MediaType.binary()

  # A CR/LF here would split the header, and no C0 control has a place in
  # one; non-ASCII survives through RFC 5987's filename* parameter.
  defp disposition(filename) do
    name = to_string(filename)
    safe = name |> Aqua.strip_attachment_name() |> String.replace(~r/["\\]/, "")

    if safe == name do
      ~s(attachment; filename="#{safe}")
    else
      encoded = URI.encode(name, &URI.char_unreserved?/1)
      ~s(attachment; filename="#{safe}"; filename*=UTF-8''#{encoded})
    end
  end
end
