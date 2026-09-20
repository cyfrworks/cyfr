# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.Blob do
  @moduledoc """
  OCI Distribution blob operations.

  Provides blob existence checks, downloads, and uploads following
  the OCI Distribution Spec v2 API.

  Every operation takes the caller `ctx` first so the per-namespace push
  token is attached on authenticated requests (uploads). `nil` is accepted
  for anonymous/public reads.
  """

  alias Compendium.OCI.{Errors, Reference, Transport}
  alias Sanctum.Context

  # 10MB
  @chunked_threshold 10 * 1024 * 1024

  # The wire ceiling for a blob download, enforced while the body streams
  # in. Its DEFAULT is the tincture decompressed cap — a compressed archive
  # cannot legitimately exceed its own decompressed cap, and that cap is
  # the largest blob any pull may carry (WASM is bounded lower again, by
  # Compendium.WasmValidator, after download) — but it is its own knob:
  # an operator lowering the tincture cap for memory reasons must not
  # silently cap the WASM components they can pull.
  defp max_blob_bytes do
    Application.get_env(
      :cyfr,
      :oci_max_blob_bytes,
      Compendium.Registry.tincture_max_decompressed_bytes()
    )
  end

  @doc """
  Check if a blob exists in the registry.

  Issues `HEAD /v2/<repo>/blobs/<digest>`.
  Returns `{:ok, true}` if exists, `{:ok, false}` if not.
  """
  @spec exists?(Context.t() | nil, Reference.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def exists?(ctx, %Reference{} = ref, digest) do
    path = "/v2/#{ref.repository}/blobs/#{digest}"

    case Transport.request(ctx, :head, path, ref) do
      {:ok, 200, _headers, _body} -> {:ok, true}
      {:ok, 404, _headers, _body} -> {:ok, false}
      {:ok, status, _headers, body} -> {:error, Errors.from_response(status, body, ref.registry)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Download a blob from the registry.

  Issues `GET /v2/<repo>/blobs/<digest>`.
  Returns `{:ok, bytes}` with the raw blob content.
  Verifies the digest matches after download.
  """
  @spec download(Context.t() | nil, Reference.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def download(ctx, %Reference{} = ref, digest) do
    path = "/v2/#{ref.repository}/blobs/#{digest}"
    headers = [{"accept", Cyfr.MediaType.binary()}]

    case Transport.request(ctx, :get, path, ref, headers, nil,
           max_response_bytes: max_blob_bytes()
         ) do
      {:ok, 200, _headers, body} ->
        actual_digest = compute_digest(body)

        if actual_digest == digest do
          {:ok, body}
        else
          {:error, Errors.digest_mismatch(digest, actual_digest)}
        end

      # CDN-backed registries answer 302 as often as 307; every 3xx target
      # goes through the same pinned SSRF validation in follow_redirect/3.
      {:ok, status, resp_headers, _body} when status in [301, 302, 303, 307, 308] ->
        location = get_header(resp_headers, "location")

        if location do
          follow_redirect(location, digest, ref.registry)
        else
          {:error,
           %Errors{
             reason: :blob_upload_failed,
             message: "Redirect without Location header",
             registry: ref.registry
           }}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, ref.registry)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Upload a blob to the registry.

  Uses monolithic upload for blobs under 10MB, chunked for larger.

  Flow:
  1. POST `/v2/<repo>/blobs/uploads/` to initiate
  2. PUT the blob content to the upload URL with digest query param

  Returns `{:ok, digest}` on success.
  """
  @spec upload(Context.t() | nil, Reference.t(), binary(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def upload(ctx, %Reference{} = ref, content, content_type \\ Cyfr.MediaType.binary()) do
    digest = compute_digest(content)

    # Check if blob already exists
    case exists?(ctx, ref, digest) do
      {:ok, true} ->
        {:ok, digest}

      _ ->
        if byte_size(content) > @chunked_threshold do
          chunked_upload(ctx, ref, content, digest, content_type)
        else
          monolithic_upload(ctx, ref, content, digest, content_type)
        end
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp monolithic_upload(ctx, ref, content, digest, content_type) do
    # Initiate upload
    path = "/v2/#{ref.repository}/blobs/uploads/"

    case Transport.request(ctx, :post, path, ref, [{"content-length", "0"}]) do
      {:ok, 202, resp_headers, _body} ->
        location = get_header(resp_headers, "location")

        if location do
          put_blob(ctx, ref, location, content, digest, content_type)
        else
          {:error,
           %Errors{
             reason: :blob_upload_failed,
             message: "Upload initiation missing Location header"
           }}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, ref.registry)}

      {:error, _} = error ->
        error
    end
  end

  defp chunked_upload(ctx, ref, content, digest, content_type) do
    # Initiate upload
    path = "/v2/#{ref.repository}/blobs/uploads/"

    case Transport.request(ctx, :post, path, ref, [{"content-length", "0"}]) do
      {:ok, 202, resp_headers, _body} ->
        location = get_header(resp_headers, "location")

        if location do
          # For simplicity, we still do a single PUT even for large blobs.
          # True chunked upload (PATCH + PUT) can be added later if needed.
          put_blob(ctx, ref, location, content, digest, content_type)
        else
          {:error,
           %Errors{
             reason: :blob_upload_failed,
             message: "Upload initiation missing Location header"
           }}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, ref.registry)}

      {:error, _} = error ->
        error
    end
  end

  defp put_blob(ctx, ref, location, content, digest, content_type) do
    # Normalize relative Location URLs to absolute (some registries return relative paths)
    location = normalize_url(location, ref)

    case Cyfr.Network.validate_redirect_url(location,
           private_policy: :operator
         ) do
      :ok ->
        # Append digest query param to the upload URL
        url = append_query(location, "digest", digest)

        headers = [
          {"content-type", content_type},
          {"content-length", Integer.to_string(byte_size(content))}
        ]

        case Transport.request_url(ctx, :put, url, ref.registry, ref.repository, headers, content) do
          {:ok, status, _headers, _body} when status in [201, 202] ->
            {:ok, digest}

          {:ok, status, _headers, body} ->
            {:error, Errors.from_response(status, body, ref.registry)}

          {:error, _} = error ->
            error
        end

      {:error, reason} ->
        {:error,
         %Errors{
           reason: :ssrf_blocked,
           message: "Upload redirect blocked: #{reason}",
           registry: ref.registry
         }}
    end
  end

  # A blob-download 307 redirects to 3rd-party/presigned storage (e.g. cloud
  # object store). It must stay auth-less — the presigned URL carries its own
  # credentials, and forwarding the `cyfr_pt_` push token to an off-registry
  # host would leak it. Intentionally no `ctx`.
  defp follow_redirect(url, expected_digest, registry) do
    # A redirect target is attacker-influenced (a malicious/compromised registry
    # chooses it). pinned_request validates the resolved IP AND connects to that
    # exact IP (no second resolution), closing the DNS-rebinding window. The
    # size ceiling streams — this is the most attacker-influenced hop, so the
    # body must never buffer past the largest legitimate blob.
    opts = [
      receive_timeout: 60_000,
      private_policy: :operator,
      max_response_bytes: max_blob_bytes()
    ]

    case Cyfr.Egress.pinned_request(:get, url, [], nil, opts) do
      {:ok, 200, _headers, body} ->
        actual_digest = compute_digest(body)

        if actual_digest == expected_digest do
          {:ok, body}
        else
          {:error, Errors.digest_mismatch(expected_digest, actual_digest)}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, registry)}

      # SSRF/DNS validation failures come back as descriptive strings.
      {:error, reason} when is_binary(reason) ->
        {:error,
         %Errors{
           reason: :ssrf_blocked,
           message: "Redirect blocked: #{reason}",
           registry: registry
         }}

      {:error, reason} ->
        {:error, Errors.connection_error(registry, reason)}
    end
  end

  @doc false
  defdelegate compute_digest(content), to: Cyfr.Digest, as: :sha256

  defp get_header(headers, name) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name, do: v

      _ ->
        nil
    end)
  end

  defp normalize_url("/" <> _ = path, ref) do
    Reference.api_base(ref) <> path
  end

  defp normalize_url(url, _ref), do: url

  defp append_query(url, key, value) do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    "#{url}#{separator}#{URI.encode_www_form(key)}=#{URI.encode_www_form(value)}"
  end
end
