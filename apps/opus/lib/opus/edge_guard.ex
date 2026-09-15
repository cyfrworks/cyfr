# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.EdgeGuard do
  @moduledoc """
  Egress checks over a consent edge, shared by the runner's HTTP host
  handlers.

  An execution's capability is the `%Cyfr.Authority.Blob.Edge{}` it runs
  under plus the node's `%Cyfr.Limits{}`. This module is the runner's home
  for matching a concrete request against that edge's egress — domains,
  schemes, methods and private IPs — and for the envelope, request and
  response size checks against the limits. Storage grants are checked on
  CYFR (`Cyfr.Execution.GuestStorage`).

  ## Semantics

  Fail-closed throughout: a `nil` edge (an authority with `resources: :none`)
  or a `nil` resource group behaves as all-empty lists, and an empty list
  denies. Schemes are always explicit in blobs — there is no "no scheme
  restriction" value. Domain patterns support `"*"` and `"*.example.com"`
  wildcards. Cloud-metadata addresses are denied regardless of the
  private-IP allowlist.

  Denial messages are part of the guest-visible contract: components and
  tests pin them, so they must not drift.
  """

  alias Cyfr.Authority.Blob.Edge
  alias Cyfr.Limits

  @type edge :: Edge.t() | nil

  # Internal accessors for the checks below; the allowed lists themselves
  # are `Cyfr.Authority.Blob.Edge`'s.
  defp methods(edge), do: egress(edge, :methods)
  defp schemes(edge), do: egress(edge, :schemes)
  defp private_ips(edge), do: egress(edge, :private_ips)

  # ============================================================================
  # Egress checks
  # ============================================================================

  @doc """
  Check a domain against the edge's egress allowlist.

  Supports `"*"` and `"*.example.com"` wildcard patterns. Returns `:ok` or
  `{:error, message}` with the message shape guests and tests pin.
  """
  @spec check_domain(edge(), String.t()) :: :ok | {:error, String.t()}
  def check_domain(edge, domain) when is_binary(domain) do
    allowed = Edge.domains(edge)

    if Enum.any?(allowed, &domain_matches?(&1, domain)) do
      :ok
    else
      {:error,
       "Error: Policy violation - domain \"#{domain}\" not in allowed_domains\n" <>
         "Allowed: #{Enum.join(allowed, ", ")}"}
    end
  end

  @doc """
  Check a URL scheme against the edge's egress allowlist.

  Schemes are always explicit on an edge — an empty list denies every scheme.
  """
  @spec check_scheme(edge(), String.t()) :: :ok | {:error, String.t()}
  def check_scheme(edge, scheme) when is_binary(scheme) do
    allowed = schemes(edge)

    if scheme in allowed do
      :ok
    else
      {:error,
       "Error: Policy violation - scheme \"#{scheme}\" not in allowed_schemes\n" <>
         "Allowed: #{Enum.join(allowed, ", ")}"}
    end
  end

  @doc """
  Check an HTTP method against the edge's egress allowlist (case-insensitive).
  """
  @spec check_method(edge(), String.t()) :: :ok | {:error, String.t()}
  def check_method(edge, method) when is_binary(method) do
    allowed = methods(edge)
    upcase_method = String.upcase(method)

    if Enum.any?(allowed, &(String.upcase(&1) == upcase_method)) do
      :ok
    else
      {:error,
       "Error: Policy violation - method \"#{upcase_method}\" not in allowed_methods\n" <>
         "Allowed: #{Enum.join(allowed, ", ")}"}
    end
  end

  @doc """
  Whether a private IP is allowed by the edge's `private_ips` allowlist.

  Supports individual IPs (`"192.168.1.100"`) and CIDR ranges (`"10.0.0.0/8"`).
  Cloud-metadata addresses (`Cyfr.Cidr.metadata?/1`) are always denied
  regardless of the allowlist. Empty allowlist denies all.
  """
  @spec allows_private_ip?(edge(), :inet.ip4_address() | :inet.ip6_address()) :: boolean()
  def allows_private_ip?(edge, ip_tuple) do
    case private_ips(edge) do
      [] ->
        false

      entries ->
        if Cyfr.Cidr.metadata?(ip_tuple) do
          false
        else
          ip_string = :inet.ntoa(ip_tuple) |> to_string()
          Enum.any?(entries, &ip_entry_matches?(&1, ip_tuple, ip_string))
        end
    end
  end

  # ============================================================================
  # Size checks (against node limits)
  # ============================================================================

  @doc """
  The ENVELOPE ceiling for a host-function call: the bound on the raw JSON
  string, checked before `Jason.decode/1` ever sees it.

  Bounds the encoded request before parsing. `max_request_size` separately limits the decoded payload.

  Generous on purpose: a payload at the consented ceiling must always fit,
  base64 overhead (4/3), JSON escaping and the scaffolding included. This
  refuses the blob, not the legitimate request.
  """
  @spec check_envelope_size(Limits.t(), binary()) :: :ok | {:error, :request_too_large}
  def check_envelope_size(%Limits{max_request_size: max}, json)
      when is_binary(json) and is_integer(max) and max > 0 do
    if byte_size(json) <= max * 2 + envelope_overhead(),
      do: :ok,
      else: {:error, :request_too_large}
  end

  def check_envelope_size(_limits, _json), do: :ok

  @doc "Slack allowed above the consented payload ceiling for framing."
  @spec envelope_overhead() :: pos_integer()
  def envelope_overhead, do: 4096

  @doc """
  Check an HTTP request against the node's `max_request_size`. Returns `:ok`
  or `{:error, :request_too_large, message}`.

  Counts what the host will actually hold and put on the wire: the body (or
  the multipart parts) **plus the URL and headers**. Measuring the body alone
  meant a guest could move megabytes into header values — into host memory and
  out to the upstream — while the consented ceiling read as enforced.
  """
  @spec check_request_size(Limits.t(), map()) ::
          :ok | {:error, :request_too_large, String.t()}
  def check_request_size(%Limits{} = limits, %{multipart: parts} = request)
      when is_list(parts) do
    payload = Enum.reduce(parts, 0, fn part, acc -> acc + multipart_part_size(part) end)

    refuse_over(limits, payload + metadata_size(request), "Multipart request")
  end

  def check_request_size(%Limits{} = limits, %{body: body} = request) do
    refuse_over(limits, byte_size(body || "") + metadata_size(request), "Request")
  end

  @doc """
  Check an HTTP response body against the node's `max_response_size`.
  Returns `:ok` or `{:error, :response_too_large, message}`.
  """
  @spec check_response_size(Limits.t(), binary() | nil) ::
          :ok | {:error, :response_too_large, String.t()}
  def check_response_size(%Limits{} = limits, body) do
    check_response_bytes(limits, byte_size(body || ""))
  end

  @doc """
  The size-arity form of `check_response_size/2` — for the streaming path,
  where the byte count is known at the abort without assembling the body.
  One message for both arities, so the denial contract cannot fork.
  """
  @spec check_response_bytes(Limits.t(), non_neg_integer()) ::
          :ok | {:error, :response_too_large, String.t()}
  def check_response_bytes(%Limits{} = limits, size) when is_integer(size) and size >= 0 do
    if size > limits.max_response_size do
      {:error, :response_too_large,
       "Response body (#{size} bytes) exceeds limit (#{limits.max_response_size} bytes)"}
    else
      :ok
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp egress(nil, _key), do: []
  defp egress(%Edge{egress: nil}, _key), do: []
  defp egress(%Edge{egress: egress}, key), do: Map.get(egress, key, [])

  defp domain_matches?(pattern, domain) when is_binary(pattern) and is_binary(domain) do
    cond do
      pattern == "*" ->
        true

      pattern == domain ->
        true

      String.starts_with?(pattern, "*.") ->
        suffix = String.slice(pattern, 1..-1//1)
        String.ends_with?(domain, suffix)

      true ->
        false
    end
  end

  # Exact-IP entries compare against the canonical ntoa string; CIDR entries
  # delegate to the Cyfr.Cidr SSOT (IPv4 + IPv6).
  defp ip_entry_matches?(entry, ip_tuple, ip_string) do
    if String.contains?(entry, "/") do
      Cyfr.Cidr.ip_in_cidr?(ip_tuple, entry)
    else
      entry == ip_string
    end
  end

  defp refuse_over(%Limits{} = limits, size, what) do
    if size > limits.max_request_size do
      {:error, :request_too_large,
       "#{what} (#{size} bytes incl. URL and headers) exceeds limit " <>
         "(#{limits.max_request_size} bytes)"}
    else
      :ok
    end
  end

  # The URL and headers travel with the body and are held in host memory the
  # same way, so they count against the same ceiling. Header framing (`: ` and
  # CRLF) is not modelled — this is a resource bound, not a wire-length
  # computation.
  defp metadata_size(request) do
    url_size = byte_size(Map.get(request, :url) || "")

    header_size =
      request
      |> Map.get(:headers)
      |> List.wrap()
      |> Enum.reduce(0, fn
        {k, v}, acc -> acc + string_size(k) + string_size(v)
        _, acc -> acc
      end)

    url_size + header_size
  end

  defp string_size(s) when is_binary(s), do: byte_size(s)
  defp string_size(s), do: s |> to_string() |> byte_size()

  defp multipart_part_size(%{data: data}) when is_binary(data), do: byte_size(data)
  defp multipart_part_size(%{value: value}) when is_binary(value), do: byte_size(value)
  defp multipart_part_size(_), do: 0
end
