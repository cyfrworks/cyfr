# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.CanvasController do
  @moduledoc """
  A canvas's page, `GET /_c/v1/<asset credential>/<frame id>`
  (`Prima.TinctureWire.page_path/2`): the canvas version's own entry
  document, which the shell frames for one canvas open, and the SDK that
  page loads, `GET` at its one path (`sdk/2`).

  The page is served only for an asset credential that stands
  (`Sanctum.TinctureAuth.verify_asset_credential/2`) and a frame id naming
  a standing frame of the credential's person, athanor and version
  (`Sanctum.TinctureAuth.page_frame/2`), while that version's release
  digest is still the credential's and its placement is `canvas`. Every
  refusal is 404 with an empty body, whatever its cause, so the page says
  nothing of what a credential or a frame id names; an entry that cannot
  be read is one. A store that could not say is 503 with `retry-after`,
  as a version's served files answer it
  (`Emissary.Web.TinctureController`): that refuses nothing.

  The body is CYFR's prefix followed by the version's entry, read through
  `Arca` as every served file is and sent byte for byte as published
  (`Emissary.Web.TinctureAssets.canvas_page/5`). The prefix is
  `<!doctype html>`, then a `<base>` naming the entry's directory under the
  version's served prefix and the asset credential, so the page's
  relative URLs resolve to its own files, then the SDK's script from its
  one path (`Emissary.Web.TinctureAssets.canvas_sdk_path/0`). No HTML of
  the entry is read or matched: the HTML parser puts the two elements
  first in the document's head whatever the entry holds. Before any
  `<html>` or `<head>` tag, the `<base>` makes the parser create the html
  and head elements and both elements land in that head. The entry's own
  doctype is then ignored, its `<html>` start tag adds its attributes
  (`lang` among them) to the html element, its `<head>` start tag is
  ignored, and its head's children follow CYFR's two in the same head; a
  comment before them is kept as a comment. The leading doctype keeps the
  page out of quirks mode. No inline script runs in the page and none
  carries a nonce. The page's policy is
  the canvas's one policy (`Compendium.tincture_canvas_page_csp/1`),
  which names the version's files under the credential, the SDK's path,
  the open's own data path and the shell. The page carries no credential
  beyond the one its own address carries: the asset credential, which its
  script can read in its URL, is in its `<base>` and its policy, and no
  bearer and no frame credential is in it. It is never cached.

  The SDK is served to anyone at its one path, whose name is its digest,
  and cached as immutable; any other name under that prefix is 404.
  """

  use Emissary.Web, :controller

  import Emissary.Web.TinctureController, only: [asset_context: 2]

  alias Emissary.Web.TinctureAssets

  # The SDK's bytes never change under their path, which names their
  # digest.
  @sdk_cache "public, max-age=31536000, immutable"

  @doc """
  The SDK a canvas page loads, at `Emissary.Web.TinctureAssets.canvas_sdk_path/0`
  alone: any other file name under the SDK's prefix is 404 with an empty
  body.
  """
  @spec sdk(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sdk(conn, %{"file" => file}) when is_binary(file) do
    if Prima.TinctureWire.page_prefix() <> "sdk/" <> file == TinctureAssets.canvas_sdk_path(),
      do: send_sdk(conn),
      else: not_found(conn)
  end

  def sdk(conn, _params), do: not_found(conn)

  # The tracked bundle, compiled in; nothing in it is echoed from the
  # request, so Sobelow's send_resp finding does not apply here.
  # sobelow_skip ["XSS.SendResp"]
  defp send_sdk(conn) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", @sdk_cache)
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("content-type", "text/javascript; charset=utf-8")
    |> send_resp(200, TinctureAssets.canvas_sdk())
  end

  @doc "The page of the canvas open the path's frame id names."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"credential" => credential, "frame_id" => frame_id}) do
    client_ip = Sanctum.ClientIp.resolve(conn)

    with :ok <- grammar(credential, frame_id),
         {:ok, authority} <-
           Sanctum.TinctureAuth.verify_asset_credential(credential, client_ip: client_ip),
         {:ok, frame} <- Sanctum.TinctureAuth.page_frame(authority, frame_id),
         ctx = asset_context(authority, client_ip),
         {:ok, version} <- canvas_version(ctx, frame.reference, authority.version_digest) do
      page(conn, ctx, version, credential, frame_id)
    else
      {:error, reason} when reason in [:unavailable, :identity_stale] -> unavailable(conn, reason)
      _refused -> not_found(conn)
    end
  end

  defp grammar(credential, frame_id) do
    if Prima.TinctureUrl.credential?(credential) and Prima.TinctureWire.frame_id?(frame_id),
      do: :ok,
      else: {:error, :not_found}
  end

  # The version the frame opened, in the credential's athanor, while its
  # release digest is the credential's and its declaration is a canvas's:
  # its reference, its files' segments, its manifest and its entry. The
  # reference is held to its grammar first, so any other refusal of the
  # read is the store's: it could not say, and nothing is served.
  defp canvas_version(ctx, %{publisher: publisher, name: name, version: version}, digest) do
    with :ok <- Prima.ComponentRef.validate_ref_parts(publisher, name),
         :ok <- Prima.ComponentRef.validate_version(version) do
      reference = Prima.ComponentRef.build("tincture", publisher, name, version)

      case Compendium.inspect_component(ctx, reference) do
        {:ok, %{"release_digest" => ^digest} = row} ->
          manifest = decode_manifest(row["manifest"])

          with :ok <- canvas_declared(manifest),
               {:ok, entry} <- Compendium.tincture_entry(manifest) do
            {:ok,
             %{
               reference: [publisher, name, version],
               segments: Prima.ComponentPath.version_dir("tincture", publisher, name, version),
               manifest: manifest,
               entry: entry
             }}
          else
            _not_a_page -> {:error, :not_found}
          end

        {:ok, _another_version} ->
          {:error, :not_found}

        {:error, {:not_found, _reference}} ->
          {:error, :not_found}

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    else
      _malformed -> {:error, :not_found}
    end
  end

  defp canvas_declared(manifest) do
    case Compendium.tincture_declaration(manifest) do
      {:ok, %{frame: %{placement: "canvas"}}} -> :ok
      _another_placement -> {:error, :not_found}
    end
  end

  defp decode_manifest(manifest) when is_map(manifest), do: manifest

  defp decode_manifest(manifest) when is_binary(manifest) do
    case Jason.decode(manifest) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_manifest(_manifest), do: %{}

  # The page: CYFR's prefix and the version's entry as published, under
  # the canvas's policy and the served files' document headers, except
  # that the page is never cached and carries no
  # `access-control-allow-origin`: only the shell frames it. The body is
  # the version's own immutable entry after a prefix built from the
  # credential the route verified and the version it names; nothing in it
  # is echoed from the request, so Sobelow's send_resp finding does not
  # apply here.
  # sobelow_skip ["XSS.SendResp"]
  defp page(conn, ctx, version, credential, frame_id) do
    # The shell is framed from the endpoint's own origin, as a tincture
    # document's policy reads it when it names no other.
    endpoint = TinctureAssets.endpoint_origin()
    sdk_path = TinctureAssets.canvas_sdk_path()

    base =
      endpoint <>
        Prima.TinctureUrl.asset_path(credential, version.reference) <>
        "/" <> entry_dir(version.entry)

    case TinctureAssets.canvas_page(ctx, version, version.entry, base, endpoint <> sdk_path) do
      {:ok, body} ->
        policy =
          Compendium.tincture_canvas_page_csp(%{
            endpoint: endpoint,
            shell: endpoint,
            asset_credential: credential,
            frame_id: frame_id,
            sdk_path: sdk_path
          })

        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("referrer-policy", "no-referrer")
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-frame-options", "SAMEORIGIN")
        |> put_resp_header("content-security-policy", policy)
        # Chromium alone reads it, where it stops a peer connection from the
        # page; other browsers ignore it, so it closes nothing there.
        |> put_resp_header(
          "connection-allowlist",
          Compendium.tincture_canvas_connection_allowlist()
        )
        |> put_resp_header("content-type", "text/html; charset=utf-8")
        |> send_resp(200, body)

      :error ->
        not_found(conn)
    end
  end

  defp entry_dir(entry) do
    case Path.dirname(entry) do
      "." -> ""
      dir -> dir <> "/"
    end
  end

  # A refusal says nothing: no body, whatever its cause.
  defp not_found(conn), do: send_resp(conn, 404, "")

  # A store that could not say whether the credential, the frame or the
  # version stands: retryable, and nothing is served.
  defp unavailable(conn, reason) do
    conn
    |> put_resp_header("retry-after", "5")
    |> CyfrWeb.ApiError.send(503, reason, nil)
  end
end
