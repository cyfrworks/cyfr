# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AttachmentController do
  @moduledoc """
  The bytes of a chat attachment, for the member reading the thread on
  another device: `GET /a/:athanor/attachments/:message_id/:filename`.

  The session cookie names the person; the URL's athanor is focused the
  way a LiveView mount focuses it (`Sanctum.Context.focus/2`, so a
  non-member gets nothing); the message is read tenant-scoped, and the
  file must be one of the message's own refs — the path served is the
  stored ref's, never one built from the URL. What comes back is a
  download with a content type from a short allowlist (anything else is
  `application/octet-stream`), `nosniff`, and no caching — the uploader's
  declared type is not trusted to be inert.
  """

  use PrismWeb, :controller

  alias Arca.ConversationStorage, as: Conversations
  alias Sanctum.Tenancy.Athanors

  # Types a browser may render inline safely; everything else downloads as
  # opaque bytes. Never text/html or image/svg+xml — both run script.
  @inline_types ~w(image/png image/jpeg image/gif image/webp application/pdf text/plain text/csv application/json)

  def show(conn, %{"athanor" => route, "message_id" => message_id, "filename" => filename}) do
    token = get_session(conn, :sanctum_session_token)

    with {:ok, athanor} <- Athanors.by_route_slug(route),
         {:ok, ctx} <- PrismWeb.AuthHelpers.authenticate_session(token, athanor.id),
         {:ok, msg} <- Conversations.get_message(ctx, message_id),
         {:ok, ref} <- find_ref(msg, filename) do
      conn
      |> put_resp_header("content-type", serve_type(ref["media_type"]))
      |> put_resp_header("content-disposition", disposition(ref["filename"]))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, no-store")
      |> serve(ctx, ref["path"])
    else
      {:error, :unauthenticated} -> redirect(conn, to: "/login")
      {:error, :namespace_unavailable} -> send_resp(conn, 503, "Try again shortly")
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  defp find_ref(msg, filename) do
    case Enum.find(Prism.Attachments.refs_of(msg), &(&1["filename"] == filename)) do
      %{"path" => path} = ref when is_list(path) -> {:ok, ref}
      _ -> {:error, :not_found}
    end
  end

  defp serve(conn, ctx, path) do
    case Arca.serve_to_conn(conn, ctx, path) do
      {:ok, %Plug.Conn{} = served} -> served
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  defp serve_type(type) when type in @inline_types, do: type
  defp serve_type(_), do: "application/octet-stream"

  defp disposition(filename) do
    safe = filename |> to_string() |> String.replace(~s("), "")
    ~s(attachment; filename="#{safe}")
  end
end
