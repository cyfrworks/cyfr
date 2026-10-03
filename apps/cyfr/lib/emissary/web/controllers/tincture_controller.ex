# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.TinctureController do
  @moduledoc """
  Tincture HTTP serving, Emissary's adapter for tinctures' served files.

  A public tincture is served at its address, to anyone; a private
  tincture version's files only under an asset credential in their path
  (`Prima.TinctureUrl`), which `Sanctum.TinctureAuth` mints for a person
  and verifies on every request. No other credential opens a private
  tincture's files: the credential names the person, the version and its
  window, so the path is the whole of the authority a frame carries.

  GET  /t/:athanor/:publisher/:tincture_name           — a public tincture's entry page
  GET  /t/:athanor/:publisher/:tincture_name/*path     — a public tincture's files
  GET  /_s/:credential/:publisher/:name/:version/*file — a private tincture version's files

  The bytes and their headers are `Emissary.Web.TinctureAssets`'. A
  tincture's data — its invocations, actions and streams — is
  `Emissary.Web.TinctureDataController`'s.
  """

  use Emissary.Web, :controller

  alias Emissary.Web.TinctureAssets
  alias Sanctum.TinctureAccess

  # A public tincture's files may be cached for this long; its address,
  # which follows its latest version, is revalidated.
  @public_max_age 3600

  # -------------------------------------------------------------------
  # A public tincture: its entry page at its address, and its files
  # -------------------------------------------------------------------

  def index(conn, %{
        "athanor" => athanor,
        "publisher" => publisher,
        "tincture_name" => tincture_name
      }) do
    with {:ok, tincture, ctx} <- resolve_public(athanor, publisher, tincture_name),
         {:ok, entry} <- Compendium.tincture_entry(tincture) do
      TinctureAssets.serve(conn, ctx, tincture, String.split(entry, "/"),
        cache: :revalidate,
        base: Prima.TinctureUrl.path(athanor, publisher, tincture_name) <> "/"
      )
    else
      {:error, :unavailable} -> unavailable(conn)
      {:error, _not_found_or_no_entry} -> CyfrWeb.ApiError.send(conn, 404, :not_found, nil)
    end
  end

  def asset(conn, %{
        "athanor" => athanor,
        "publisher" => publisher,
        "tincture_name" => tincture_name,
        "path" => segments
      }) do
    case resolve_public(athanor, publisher, tincture_name) do
      {:ok, tincture, ctx} ->
        TinctureAssets.serve(conn, ctx, tincture, segments,
          cache: {:public, @public_max_age},
          base: Prima.TinctureUrl.path(athanor, publisher, tincture_name) <> "/"
        )

      {:error, :unavailable} ->
        unavailable(conn)

      {:error, :not_found} ->
        CyfrWeb.ApiError.send(conn, 404, :not_found, nil)
    end
  end

  # -------------------------------------------------------------------
  # A private tincture version's files, under an asset credential
  # -------------------------------------------------------------------

  # The credential is verified on every request, against the rows it
  # names as they are now: a retired source, a person or athanor that
  # changed standing, or a window that ended refuses the next fetch. The
  # version is read in the credential's athanor and served only when its
  # release digest (`Compendium.ReleaseDigest`: its bytes bound to its
  # manifest) is the one the credential names; the bytes are read through the
  # context the credential narrows, and cached for no longer than it has
  # left.
  def served(conn, %{"path" => segments}) do
    with {:ok, %{credential: credential, path: [publisher, name, version | file]}}
         when file != [] <-
           Prima.TinctureUrl.parse_asset_path([Prima.TinctureUrl.asset_prefix() | segments]),
         client_ip = Sanctum.ClientIp.resolve(conn),
         {:ok, authority} <-
           Sanctum.TinctureAuth.verify_asset_credential(credential, client_ip: client_ip),
         ctx = asset_context(authority, client_ip),
         {:ok, tincture} <- version(ctx, publisher, name, version, authority.version_digest) do
      TinctureAssets.serve(conn, ctx, tincture, file,
        cache: {:private, authority.remaining_s},
        base: Prima.TinctureUrl.asset_path(credential, [publisher, name, version]) <> "/"
      )
    else
      {:error, reason}
      when reason in [:invalid_credential, :expired_credential] ->
        CyfrWeb.ApiError.send(conn, 401, reason, nil)

      {:error, reason} when reason in [:not_member, :not_standing, :ip_not_allowed] ->
        CyfrWeb.ApiError.send(conn, 403, reason, nil)

      {:error, :unavailable} ->
        unavailable(conn)

      # A remote person whose identity could not be confirmed fresh: their
      # files wait with their session, retryable, and are not gone.
      {:error, :identity_stale} ->
        conn
        |> put_resp_header("retry-after", "5")
        |> CyfrWeb.ApiError.send(503, :identity_stale, nil)

      _not_found ->
        CyfrWeb.ApiError.send(conn, 404, :not_found, nil)
    end
  end

  # What the credential opens, as a context: reads in the person's
  # athanor, bound to the credential's source and deadline. It is not an
  # authenticated caller — only `Sanctum.Caller.establish/2` builds one —
  # and carries no permission: it names whose bytes are read, and nothing
  # runs under it.
  defp asset_context(authority, client_ip) do
    Sanctum.Context.build(
      user_id: authority.user_id,
      athanor_id: authority.athanor_id,
      scope: :athanor,
      authenticated: false,
      credential_binding: authority.credential_binding,
      credential_deadline: authority.expires_at,
      client_ip: client_ip
    )
  end

  # The version the path names, in the credential's athanor, when its
  # release digest is the credential's; any other version, absent or not, is not
  # found.
  defp version(ctx, publisher, name, version, digest) do
    with :ok <- Prima.ComponentRef.validate_ref_parts(publisher, name),
         :ok <- Prima.ComponentRef.validate_version(version) do
      reference =
        Prima.ComponentRef.to_string(%Prima.ComponentRef{
          type: "tincture",
          namespace: publisher,
          name: name,
          version: version
        })

      case Compendium.inspect_component(ctx, reference) do
        {:ok, %{"release_digest" => ^digest} = row} ->
          {:ok,
           %{
             segments: Prima.ComponentPath.version_dir("tincture", publisher, name, version),
             manifest: decode_manifest(row["manifest"])
           }}

        {:ok, _another_version} ->
          {:error, :not_found}

        {:error, {:not_found, _reference}} ->
          {:error, :not_found}

        # The reference was held to its grammar above, so any other refusal
        # is the store's: it could not say, and nothing is served.
        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    else
      _malformed -> {:error, :not_found}
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

  # A store that could not say whether the credential stands: retryable,
  # and nothing is served — never read as "not found" or as allowed.
  defp unavailable(conn) do
    conn
    |> put_resp_header("retry-after", "5")
    |> CyfrWeb.ApiError.send(503, :unavailable, nil)
  end

  # -------------------------------------------------------------------
  # Resolution
  # -------------------------------------------------------------------

  # A public tincture in the athanor the address names, with the public
  # context its bytes are read under. An athanor segment that names no
  # active athanor is not found, and one the store cannot resolve is
  # unavailable.
  defp resolve_public(athanor, publisher, tincture_name) do
    with {:ok, public_ctx} <- TinctureAccess.public_context(athanor),
         {:ok, tincture} <- TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
      {:ok, tincture, public_ctx}
    end
  end
end
