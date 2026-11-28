# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.EdgeGuard do
  @moduledoc """
  The relay's checks of a runner's request against its attempt's consent
  edge and the node's limits (`Locus.Runtime.Relay`), made before the
  service connects: the method, scheme and domain against the edge's
  egress, and the request's and an emitted event's size against the
  limits. The runner is untrusted, so whatever it asked is checked again
  here. The address a request connects to, and so the edge's
  private-address grant, is CYFR's to decide when it pins the request
  (`c:Prima.HostAPI.egress_pin/3`); storage grants are checked by CYFR
  when the attempt asks for a storage operation
  (`c:Prima.HostAPI.storage/3`).

  ## Semantics

  Fail-closed throughout: a `nil` edge (an authority with `resources: :none`)
  or a `nil` resource group behaves as all-empty lists, and an empty list
  denies. Schemes are always explicit in blobs — there is no "no scheme
  restriction" value. Domains match as `Prima.Network.domain_allowed?/2`
  matches them, the matcher CYFR's pin applies to the same edge: `"*"`,
  `"*.example.com"` by whole label, and exact names, case-folded.
  `tests/fixtures/host_api.json`'s `edge_checks`, `request_sizes` and
  `method_bytes` hold these checks, which a Go service makes the same.
  """

  alias Prima.Authority.Blob.Edge
  alias Prima.Limits

  @type edge :: Edge.t() | nil

  # Internal accessors for the checks below; the allowed lists themselves
  # are `Prima.Authority.Blob.Edge`'s.
  defp methods(edge), do: egress(edge, :methods)
  defp schemes(edge), do: egress(edge, :schemes)

  # ============================================================================
  # Egress checks
  # ============================================================================

  @doc """
  Check a domain against the edge's egress allowlist.

  Matched by `Prima.Network.domain_allowed?/2`. Returns `:ok` or
  `{:error, message}` with the message shape guests and tests pin.
  """
  @spec check_domain(edge(), String.t()) :: :ok | {:error, String.t()}
  def check_domain(edge, domain) when is_binary(domain) do
    allowed = Edge.domains(edge)

    if Prima.Network.domain_allowed?(domain, allowed) do
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

  # ============================================================================
  # Size checks (against node limits)
  # ============================================================================

  @doc """
  Check an HTTP request against the node's `max_request_size`. Returns `:ok`
  or `{:error, :request_too_large, message}`.

  Counts what the host will actually hold and put on the wire: the body
  **plus the URL and headers**, so a guest cannot move megabytes into
  header values — into host memory and out to the upstream — past the
  consented ceiling.
  """
  @spec check_request_size(Limits.t(), map()) ::
          :ok | {:error, :request_too_large, String.t()}
  def check_request_size(%Limits{} = limits, %{body: body} = request) do
    refuse_over(limits, byte_size(body || "") + metadata_size(request), "Request")
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp egress(nil, _key), do: []
  defp egress(%Edge{egress: nil}, _key), do: []
  defp egress(%Edge{egress: egress}, key), do: Map.get(egress, key, [])

  @doc """
  Check an event a guest emits against the node's `max_request_size`: the
  encoded event's bytes, which is what the host call carries. Returns
  `:ok` or `{:error, :request_too_large, message}`.
  """
  @spec check_event_size(Limits.t(), binary()) ::
          :ok | {:error, :request_too_large, String.t()}
  def check_event_size(%Limits{} = limits, json_event) when is_binary(json_event) do
    case refuse_over(limits, byte_size(json_event), "Emitted event") do
      :ok ->
        :ok

      {:error, :request_too_large, _message} ->
        {:error, :request_too_large,
         "Event exceeds the consented max_request_size for this component."}
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
end
