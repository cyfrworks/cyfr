# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.EdgeGuard do
  @moduledoc """
  Resource checks over a consent edge, shared by every WASI host handler.

  An execution's capability is the `%Sanctum.Authority.Blob.Edge{}` it runs
  under plus the node's `%Sanctum.Limits{}`. This module is the single home
  for matching a concrete request against that edge — domains, schemes,
  methods, private IPs, storage paths and actions — and for the request /
  response size checks against the limits.

  ## Semantics

  Fail-closed throughout: a `nil` edge (an authority with `resources: :none`)
  or a `nil` resource group behaves as all-empty lists, and an empty list
  denies. Schemes are always explicit in blobs — there is no "no scheme
  restriction" value. Domain patterns support `"*"` and `"*.example.com"`
  wildcards; storage paths support `"*"`, trailing-`/` prefixes, and exact
  file matches. Link-local / cloud-metadata addresses are denied regardless
  of the private-IP allowlist.

  Denial messages are part of the guest-visible contract: components and
  tests pin them, so they must not drift.
  """

  alias Sanctum.Authority.Blob.Edge
  alias Sanctum.Limits

  @type edge :: Edge.t() | nil

  # ============================================================================
  # Edge accessors (nil edge / nil group => empty list => deny)
  # ============================================================================

  @doc "Allowed egress domains for an edge (empty = deny all)."
  @spec domains(edge()) :: [String.t()]
  def domains(edge), do: egress(edge, :domains)

  @doc "Allowed HTTP methods for an edge (empty = deny all)."
  @spec methods(edge()) :: [String.t()]
  def methods(edge), do: egress(edge, :methods)

  @doc "Allowed URL schemes for an edge (empty = deny all)."
  @spec schemes(edge()) :: [String.t()]
  def schemes(edge), do: egress(edge, :schemes)

  @doc "Allowed private IPs/CIDRs for an edge (empty = deny all)."
  @spec private_ips(edge()) :: [String.t()]
  def private_ips(edge), do: egress(edge, :private_ips)

  @doc "Allowed storage paths for an edge (empty = deny all)."
  @spec paths(edge()) :: [String.t()]
  def paths(edge), do: storage(edge, :paths)

  @doc "Allowed storage actions for an edge (empty = deny all)."
  @spec actions(edge()) :: [String.t()]
  def actions(edge), do: storage(edge, :actions)

  @doc "Granted tool actions for an edge (empty = deny all)."
  @spec tools(edge()) :: [String.t()]
  def tools(nil), do: []
  def tools(%Edge{tools: tools}), do: tools

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
    allowed = domains(edge)

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
  Link-local / cloud-metadata ranges (`169.254.0.0/16`, `fe80::/10`) are always
  denied regardless of the allowlist. Empty allowlist denies all.
  """
  @spec allows_private_ip?(edge(), :inet.ip4_address() | :inet.ip6_address()) :: boolean()
  def allows_private_ip?(edge, ip_tuple) do
    case private_ips(edge) do
      [] ->
        false

      entries ->
        if Sanctum.Cidr.link_local?(ip_tuple) do
          false
        else
          ip_string = :inet.ntoa(ip_tuple) |> to_string()
          Enum.any?(entries, &ip_entry_matches?(&1, ip_tuple, ip_string))
        end
    end
  end

  # ============================================================================
  # Storage checks
  # ============================================================================

  @doc """
  Whether a storage action is allowed by the edge (case-insensitive).
  """
  @spec allows_action?(edge(), String.t()) :: boolean()
  def allows_action?(edge, action) when is_binary(action) do
    down = String.downcase(action)
    Enum.any?(actions(edge), &(String.downcase(&1) == down))
  end

  @doc """
  Whether a storage path is allowed by the edge.

  - `"*"` allows everything
  - a trailing-`/` entry is a directory prefix
  - anything else is an exact file match

  Empty allowlist denies all.
  """
  @spec allows_path?(edge(), String.t()) :: boolean()
  def allows_path?(edge, path) when is_binary(path) do
    Enum.any?(paths(edge), fn
      "*" ->
        true

      entry ->
        if String.ends_with?(entry, "/") do
          String.starts_with?(path, entry)
        else
          path == entry
        end
    end)
  end

  # ============================================================================
  # Size checks (against node limits)
  # ============================================================================

  @doc """
  Check an HTTP request's body (or multipart parts) against the node's
  `max_request_size`. Returns `:ok` or `{:error, :request_too_large, message}`.
  """
  @spec check_request_size(Limits.t(), map()) ::
          :ok | {:error, :request_too_large, String.t()}
  def check_request_size(%Limits{} = limits, %{multipart: parts}) when is_list(parts) do
    size = Enum.reduce(parts, 0, fn part, acc -> acc + multipart_part_size(part) end)

    if size > limits.max_request_size do
      {:error, :request_too_large,
       "Multipart body (#{size} bytes) exceeds limit (#{limits.max_request_size} bytes)"}
    else
      :ok
    end
  end

  def check_request_size(%Limits{} = limits, %{body: body}) do
    size = byte_size(body || "")

    if size > limits.max_request_size do
      {:error, :request_too_large,
       "Request body (#{size} bytes) exceeds limit (#{limits.max_request_size} bytes)"}
    else
      :ok
    end
  end

  @doc """
  Check an HTTP response body against the node's `max_response_size`.
  Returns `:ok` or `{:error, :response_too_large, message}`.
  """
  @spec check_response_size(Limits.t(), binary() | nil) ::
          :ok | {:error, :response_too_large, String.t()}
  def check_response_size(%Limits{} = limits, body) do
    size = byte_size(body || "")

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

  defp storage(nil, _key), do: []
  defp storage(%Edge{storage: nil}, _key), do: []
  defp storage(%Edge{storage: storage}, key), do: Map.get(storage, key, [])

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
  # delegate to the Sanctum.Cidr SSOT (IPv4 + IPv6).
  defp ip_entry_matches?(entry, ip_tuple, ip_string) do
    if String.contains?(entry, "/") do
      Sanctum.Cidr.ip_in_cidr?(ip_tuple, entry)
    else
      entry == ip_string
    end
  end

  defp multipart_part_size(%{data: data}) when is_binary(data), do: byte_size(data)
  defp multipart_part_size(%{value: value}) when is_binary(value), do: byte_size(value)
  defp multipart_part_size(_), do: 0
end
