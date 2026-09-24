# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.FileController do
  @moduledoc """
  The bytes of one of the athanor's files, for the member browsing them:
  `GET /a/:athanor/files/download/*path`, where the path is the console's
  (`data/reports/q3.csv`).

  The session cookie names the person; the URL's athanor is focused the
  way a LiveView mount focuses it (so a non-member gets nothing); the
  path is resolved by `Arca.Files.locate/2`, so only a shown folder can
  be named and the server's own storage has no address. What comes back
  is a download with a content type from a short allowlist (anything
  else is `application/octet-stream`), `nosniff`, and no caching.
  """

  use PrismWeb, :controller

  alias Sanctum.Tenancy.Athanors

  # Types a browser may render inline safely; everything else downloads as
  # opaque bytes. Never text/html or image/svg+xml — both run script.
  @inline_types ~w(image/png image/jpeg image/gif image/webp application/pdf text/plain text/csv text/markdown application/json)

  def show(conn, %{"athanor" => route, "path" => segments}) when is_list(segments) do
    token = get_session(conn, PrismWeb.SignInResponse.session_key())

    with {:ok, athanor} <- Athanors.by_route_slug(route),
         {:ok, ctx} <- authenticate(token, athanor.id),
         {:ok, physical} <- located(ctx, Enum.join(segments, "/")) do
      name = List.last(segments)

      conn
      |> put_resp_header("content-type", serve_type(name))
      |> put_resp_header("content-disposition", disposition(name))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, no-store")
      |> serve(ctx, physical)
    else
      :sign_in -> redirect(conn, to: PrismWeb.AuthHelpers.sign_in_path())
      :unavailable -> send_resp(conn, 503, "Try again shortly")
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "Not found")

  # A session refusal is rendered by its disposition; a path the tree does
  # not show is simply not found, whatever the reason.
  defp authenticate(token, athanor_id) do
    case CyfrWeb.ContextGuard.authenticate(token, athanor_id) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, refusal} -> PrismWeb.AuthHelpers.disposition(refusal)
    end
  end

  defp located(ctx, path) do
    case Arca.Files.locate(Sanctum.Context.actor(ctx), path) do
      {:ok, physical, _tier} -> {:ok, physical}
      {:error, _} -> :not_found
    end
  end

  defp serve(conn, ctx, physical) do
    case Arca.serve_to_conn(conn, Sanctum.Context.actor(ctx), physical) do
      {:ok, %Plug.Conn{} = served} -> served
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  defp serve_type(name) do
    type = MIME.from_path(name)
    if type in @inline_types, do: type, else: Cyfr.MediaType.binary()
  end

  defp disposition(name) do
    safe = name |> Aqua.Attachments.strip_controls() |> String.replace(~r/["\\]/, "")

    if safe == name do
      ~s(attachment; filename="#{safe}")
    else
      encoded = URI.encode(name, &URI.char_unreserved?/1)
      ~s(attachment; filename="#{safe}"; filename*=UTF-8''#{encoded})
    end
  end
end
