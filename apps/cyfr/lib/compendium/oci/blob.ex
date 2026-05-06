defmodule Compendium.OCI.Blob do
  @moduledoc """
  OCI Distribution blob operations.

  Provides blob existence checks, downloads, and uploads following
  the OCI Distribution Spec v2 API.
  """

  alias Compendium.OCI.{Errors, Reference, Transport}

  # 10MB
  @chunked_threshold 10 * 1024 * 1024

  @doc """
  Check if a blob exists in the registry.

  Issues `HEAD /v2/<repo>/blobs/<digest>`.
  Returns `{:ok, true}` if exists, `{:ok, false}` if not.
  """
  @spec exists?(Reference.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def exists?(%Reference{} = ref, digest) do
    path = "/v2/#{ref.repository}/blobs/#{digest}"

    case Transport.request(:head, path, ref) do
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
  @spec download(Reference.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def download(%Reference{} = ref, digest) do
    path = "/v2/#{ref.repository}/blobs/#{digest}"
    headers = [{"accept", "application/octet-stream"}]

    case Transport.request(:get, path, ref, headers) do
      {:ok, 200, _headers, body} ->
        actual_digest = compute_digest(body)

        if actual_digest == digest do
          {:ok, body}
        else
          {:error, Errors.digest_mismatch(digest, actual_digest)}
        end

      {:ok, 307, resp_headers, _body} ->
        # Follow redirect for blob storage
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
  @spec upload(Reference.t(), binary(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def upload(%Reference{} = ref, content, content_type \\ "application/octet-stream") do
    digest = compute_digest(content)

    # Check if blob already exists
    case exists?(ref, digest) do
      {:ok, true} ->
        {:ok, digest}

      _ ->
        if byte_size(content) > @chunked_threshold do
          chunked_upload(ref, content, digest, content_type)
        else
          monolithic_upload(ref, content, digest, content_type)
        end
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp monolithic_upload(ref, content, digest, content_type) do
    # Initiate upload
    path = "/v2/#{ref.repository}/blobs/uploads/"

    case Transport.request(:post, path, ref, [{"content-length", "0"}]) do
      {:ok, 202, resp_headers, _body} ->
        location = get_header(resp_headers, "location")

        if location do
          put_blob(ref, location, content, digest, content_type)
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

  defp chunked_upload(ref, content, digest, content_type) do
    # Initiate upload
    path = "/v2/#{ref.repository}/blobs/uploads/"

    case Transport.request(:post, path, ref, [{"content-length", "0"}]) do
      {:ok, 202, resp_headers, _body} ->
        location = get_header(resp_headers, "location")

        if location do
          # For simplicity, we still do a single PUT even for large blobs.
          # True chunked upload (PATCH + PUT) can be added later if needed.
          put_blob(ref, location, content, digest, content_type)
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

  defp put_blob(ref, location, content, digest, content_type) do
    # Normalize relative Location URLs to absolute (some registries return relative paths)
    location = normalize_url(location, ref)

    case Cyfr.Network.validate_redirect_url(location,
           allow_private: Sanctum.Edition.core?()
         ) do
      :ok ->
        # Append digest query param to the upload URL
        url = append_query(location, "digest", digest)

        headers = [
          {"content-type", content_type},
          {"content-length", Integer.to_string(byte_size(content))}
        ]

        case Transport.request_url(:put, url, ref.registry, ref.repository, headers, content) do
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

  defp follow_redirect(url, expected_digest, registry) do
    case Cyfr.Network.validate_redirect_url(url,
           allow_private: Sanctum.Edition.core?()
         ) do
      :ok ->
        # Direct GET to the redirect URL (e.g., cloud storage)
        request = Finch.build(:get, url)

        case Finch.request(request, Compendium.Finch, receive_timeout: 60_000) do
          {:ok, %Finch.Response{status: 200, body: body}} ->
            actual_digest = compute_digest(body)

            if actual_digest == expected_digest do
              {:ok, body}
            else
              {:error, Errors.digest_mismatch(expected_digest, actual_digest)}
            end

          {:ok, %Finch.Response{status: status, body: body}} ->
            {:error, Errors.from_response(status, body, registry)}

          {:error, reason} ->
            {:error, Errors.connection_error(registry, reason)}
        end

      {:error, reason} ->
        {:error,
         %Errors{
           reason: :ssrf_blocked,
           message: "Redirect blocked: #{reason}",
           registry: registry
         }}
    end
  end

  @doc false
  def compute_digest(content) when is_binary(content) do
    hash = :crypto.hash(:sha256, content)
    "sha256:" <> Base.encode16(hash, case: :lower)
  end

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
