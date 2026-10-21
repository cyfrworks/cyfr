# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.CanvasController do
  @moduledoc """
  A canvas's host page, `GET /_c/v1/<asset credential>/<frame id>`
  (`Prima.CanvasWire.page_path/2`): CYFR's own page, which the shell frames
  for one canvas open and no canvas version writes.

  It is served only for an asset credential that stands
  (`Sanctum.TinctureAuth.verify_asset_credential/2`) and a frame id naming
  a standing frame of the credential's person, athanor and version
  (`Sanctum.TinctureAuth.page_frame/2`), while that version's release
  digest is still the credential's and its placement is `canvas`. Every
  refusal is 404 with an empty body, whatever its cause, so the page says
  nothing of what a credential or a frame id names. A store that could not
  say is 503 with `retry-after`, as a version's served files answer it
  (`Emissary.Web.TinctureController`): that refuses nothing.

  The page carries the toolkit, embedded at compile time from
  `priv/static/toolkit/`: the host bundle as its one script, under the
  page's fresh nonce, refused when the module is compiled if it holds
  `</script` or `<!--`, and the worker bundle as inert data, one JSON string
  in a `<script type="application/json">` element the page never executes,
  whose text holds no `<`. The host script starts the toolkit's workers
  from that string. The page's policy is the canvas's one policy
  (`Compendium.tincture_canvas_page_csp/1`), naming the version's served
  prefix under the credential and the open's own data path, and the
  workers the page starts from `blob:` URLs inherit it. No bearer and no
  frame credential is in the page, and the asset credential only in its
  policy. It is never cached: each page has its own nonce.
  """

  use Emissary.Web, :controller

  import Emissary.Web.TinctureController, only: [asset_context: 2]

  @toolkit Path.join(:code.priv_dir(:cyfr), "static/toolkit")
  @host_path Path.join(@toolkit, "host.js")
  @worker_path Path.join(@toolkit, "worker.js")
  @external_resource @host_path
  @external_resource @worker_path

  # arca:bypass-ok=C — compile-time embed of the toolkit's host bundle.
  # Runtime never reads from disk for it; mix recompiles the module if the
  # file changes.
  @host_source File.read!(@host_path)
  # arca:bypass-ok=C — compile-time embed of the toolkit's worker bundle, as
  # the host bundle above is.
  @worker_source File.read!(@worker_path)

  # The host bundle is held to `page_safe?/1` as soon as this module is
  # compiled, and a bundle it refuses fails the build: a module's body
  # cannot call its own functions, so the check runs here.
  @after_compile __MODULE__

  # The worker bundle as one JSON string holding no `<`, so nothing in it
  # can end or escape the inert element it is written into.
  @worker_data @worker_source |> Jason.encode!() |> String.replace("<", "\\u003c")

  @page_head ~s(<!doctype html><html><head><meta charset="utf-8"><script nonce=")
  @page_rest ~s(">) <>
               @host_source <>
               ~s(</script></head><body><script type="application/json" id="cyfr-toolkit-worker">) <>
               @worker_data <> "</script></body></html>"

  # Whether `source` may be inlined as the page's script: it holds no
  # `</script`, in any ASCII case as the HTML parser matches it, which would
  # end the element early, and no `<!--`, which would change how the parser
  # reads the rest of it.
  @spec page_safe?(String.t()) :: boolean()
  defp page_safe?(source) when is_binary(source),
    do: not String.contains?(String.downcase(source, :ascii), ["</script", "<!--"])

  @doc false
  # Refuses the build when the embedded host bundle is not `page_safe?/1`.
  def __after_compile__(_env, _bytecode) do
    unless page_safe?(@host_source) do
      raise ArgumentError,
            "the toolkit's host bundle holds </script or <!--, which would end or " <>
              "reshape its inline script"
    end
  end

  @doc "The host page of the canvas open the path's frame id names."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"credential" => credential, "frame_id" => frame_id}) do
    client_ip = Sanctum.ClientIp.resolve(conn)

    with :ok <- grammar(credential, frame_id),
         {:ok, authority} <-
           Sanctum.TinctureAuth.verify_asset_credential(credential, client_ip: client_ip),
         {:ok, frame} <- Sanctum.TinctureAuth.page_frame(authority, frame_id),
         :ok <-
           canvas_version(
             asset_context(authority, client_ip),
             frame.reference,
             authority.version_digest
           ) do
      page(conn, credential, frame_id)
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
  # release digest is the credential's and its declaration is a canvas's.
  # The reference is held to its grammar first, so any other refusal of
  # the read is the store's: it could not say, and nothing is served.
  defp canvas_version(ctx, %{publisher: publisher, name: name, version: version}, digest) do
    with :ok <- Prima.ComponentRef.validate_ref_parts(publisher, name),
         :ok <- Prima.ComponentRef.validate_version(version) do
      reference = Prima.ComponentRef.build("tincture", publisher, name, version)

      case Compendium.inspect_component(ctx, reference) do
        {:ok, %{"release_digest" => ^digest} = row} -> canvas_declared(row["manifest"])
        {:ok, _another_version} -> {:error, :not_found}
        {:error, {:not_found, _reference}} -> {:error, :not_found}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    else
      _malformed -> {:error, :not_found}
    end
  end

  defp canvas_declared(manifest) do
    case Compendium.tincture_declaration(decode_manifest(manifest)) do
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

  # The page: a fresh nonce, the canvas's policy under it, and the served
  # files' document headers, except that the page is never cached and
  # carries no `access-control-allow-origin`: only the shell frames it.
  # The body is the compile-time page around the nonce, which is base64url
  # and nothing a request said; nothing in it is echoed from the request,
  # so Sobelow's send_resp finding does not apply here.
  # sobelow_skip ["XSS.SendResp"]
  defp page(conn, credential, frame_id) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    # The shell is framed from the endpoint's own origin, as a tincture
    # document's policy reads it when it names no other.
    endpoint = Emissary.Web.TinctureAssets.endpoint_origin()

    policy =
      Compendium.tincture_canvas_page_csp(%{
        endpoint: endpoint,
        shell: endpoint,
        asset_credential: credential,
        frame_id: frame_id,
        nonce: nonce
      })

    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> put_resp_header("content-security-policy", policy)
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_resp(200, [@page_head, nonce, @page_rest])
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
