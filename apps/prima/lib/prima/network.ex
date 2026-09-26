# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Network do
  @moduledoc """
  Pure outbound URL, address-policy and pinned-connection contracts.

  Callers supply the resolved address and any private-address policy. This
  module performs no DNS lookup, configuration read or HTTP request. Metadata
  addresses are refused before any policy override. A pinned connection uses
  exactly the supplied address and retains the original TLS and Host identity.
  """

  import Prima.MapUtil, only: [put_unless_nil: 3]

  # Lowercase header names that carry a credential, besides any name ending
  # in one of @credential_suffixes.
  @credential_headers ~w(authorization cookie proxy-authorization x-api-key x-auth-token
                         x-access-token x-csrf-token)
  @credential_suffixes ["-token", "-key", "-secret"]

  @default_ports %{"http" => 80, "https" => 443}

  @type pinned :: %{
          ip: String.t(),
          ip_tuple: :inet.ip_address(),
          uri: URI.t(),
          req_opts: keyword()
        }

  @doc "Parse an HTTP(S) URL with a hostname before its caller resolves it."
  @spec parse_url(String.t()) :: {:ok, URI.t()} | {:error, :invalid_url, String.t()}
  def parse_url(url) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- check_scheme(uri.scheme), :ok <- check_host(uri.host), do: {:ok, uri}
  rescue
    ArgumentError -> {:error, :invalid_url, "invalid URL"}
  end

  @doc """
  Validate a resolved address and construct its pinned connection options.

  `:private_policy` is `:deny` (default), `:allow_all`, `{:allowlist, targets}`
  or `{:fun, predicate}`. `:receive_timeout`, `:protocols` and `:transport_opts`
  are copied into the connection options. Redirects, retries, decompression
  and body decoding stay disabled so the caller controls every next request.

  An engine connecting to an address CYFR pinned for it
  (`Prima.PinnedTarget.address/1`) passes `private_policy: :allow_all`: the
  control plane already applied the attempt's private-address policy to
  that address, so the engine keeps only the metadata refusal, which no
  policy overrides, and resolves nothing itself.
  """
  @spec pin(URI.t(), :inet.ip_address(), keyword()) ::
          {:ok, pinned()} | {:error, :private_ip_blocked, String.t()}
  def pin(%URI{} = uri, ip_tuple, opts) when is_list(opts) do
    policy = Keyword.get(opts, :private_policy, :deny)

    with :ok <- check_ip(ip_tuple, uri.host, policy) do
      ip = format_ip(ip_tuple)

      req_opts =
        [
          url: URI.to_string(%{uri | host: ip}),
          compressed: false,
          decode_body: false,
          redirect: false,
          retry: false,
          connect_options:
            [hostname: uri.host]
            |> put_unless_nil(:protocols, Keyword.get(opts, :protocols))
            |> put_unless_nil(:transport_opts, Keyword.get(opts, :transport_opts)),
          receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
        ]

      {:ok, %{ip: ip, ip_tuple: ip_tuple, uri: uri, req_opts: req_opts}}
    end
  end

  defp check_scheme(scheme) when scheme in ["http", "https"], do: :ok
  defp check_scheme(nil), do: {:error, :invalid_url, "missing URL scheme"}
  defp check_scheme(scheme), do: {:error, :invalid_url, "blocked URL scheme: #{scheme}"}

  defp check_host(nil), do: {:error, :invalid_url, "missing hostname"}
  defp check_host(""), do: {:error, :invalid_url, "missing hostname"}
  defp check_host(_), do: :ok

  # A metadata address is refused before the private classification or any
  # policy is consulted.
  defp check_ip(ip_tuple, hostname, policy) do
    cond do
      Prima.Cidr.metadata?(ip_tuple) ->
        {:error, :private_ip_blocked,
         "metadata IP #{format_ip(ip_tuple)} blocked (resolved from #{hostname})"}

      not Prima.Cidr.private_ip?(ip_tuple) ->
        :ok

      private_permitted?(policy, hostname, ip_tuple) ->
        :ok

      true ->
        {:error, :private_ip_blocked,
         "private IP #{format_ip(ip_tuple)} blocked (resolved from #{hostname})"}
    end
  end

  defp private_permitted?(:allow_all, _hostname, _ip), do: true

  defp private_permitted?({:allowlist, targets}, hostname, ip),
    do: private_allowed?(hostname, ip, targets)

  defp private_permitted?({:fun, fun}, _hostname, ip) when is_function(fun, 1), do: fun.(ip)
  defp private_permitted?(_, _hostname, _ip), do: false

  @doc "Match an explicit private-egress allowlist by hostname, address or CIDR."
  @spec private_allowed?(String.t() | nil, :inet.ip_address(), [String.t()]) :: boolean()
  def private_allowed?(hostname, ip_tuple, targets) do
    host = if is_binary(hostname), do: String.downcase(hostname), else: nil

    Enum.any?(targets, fn target ->
      String.downcase(target) == host or Prima.Cidr.match?(ip_tuple, target)
    end)
  end

  defp format_ip(ip_tuple), do: :inet.ntoa(ip_tuple) |> to_string()

  @doc """
  Whether `a` and `b` name one origin: the same scheme, host and effective
  port.

  Each is a `%URI{}` or a URL. Scheme and host compare case-folded, and one
  trailing dot on a host is dropped first. An IPv6 literal compares by its
  address, so `[::1]` and `[0:0:0:0:0:0:0:1]` are one host. The effective
  port is the explicit one, or 80 for `http` and 443 for `https`; a
  `%URI{}`'s `port` counts as explicit. Anything malformed answers `false`:
  a URL that does not parse, no scheme, an empty host, an IPv6 literal that
  is not an address or names a zone, a port of 0 or above 65535, or a
  scheme other than `http` and `https` without an explicit port.
  """
  @spec same_origin?(URI.t() | String.t(), URI.t() | String.t()) :: boolean()
  def same_origin?(a, b) do
    case {origin(a), origin(b)} do
      {{:ok, origin}, {:ok, origin}} -> true
      _different_or_malformed -> false
    end
  end

  defp origin(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} -> origin(uri, explicit_port?(url))
      {:error, _part} -> :error
    end
  end

  defp origin(%URI{port: port} = uri), do: origin(uri, port != nil)
  defp origin(_url), do: :error

  defp origin(%URI{scheme: scheme, host: host, port: port}, explicit?)
       when is_binary(scheme) and scheme != "" and is_binary(host) do
    scheme = String.downcase(scheme)

    with {:ok, host} <- origin_host(host),
         {:ok, port} <- effective_port(scheme, port, explicit?) do
      {:ok, {scheme, host, port}}
    end
  end

  defp origin(_uri, _explicit?), do: :error

  defp origin_host(host) do
    host = host |> unbracket() |> drop_trailing_dot() |> String.downcase()

    cond do
      host == "" or String.contains?(host, "%") ->
        :error

      String.contains?(host, ":") ->
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, {_, _, _, _, _, _, _, _} = address} -> {:ok, {:ipv6, address}}
          _not_ipv6 -> :error
        end

      true ->
        {:ok, host}
    end
  end

  # `URI` fills in the registered default port of every scheme it knows, so
  # for a scheme without a default of ours the port counts only when the URL
  # spells it.
  defp effective_port(scheme, nil, _explicit?), do: Map.fetch(@default_ports, scheme)

  defp effective_port(scheme, port, explicit?) when is_integer(port) and port in 1..65_535 do
    if Map.has_key?(@default_ports, scheme) or explicit?, do: {:ok, port}, else: :error
  end

  defp effective_port(_scheme, _port, _explicit?), do: :error

  @explicit_port ~r{\A[^:/?#]+://(?:[^/?#@]*@)?(?:\[[^\]/?#]*\]|[^:/?#]*):[0-9]+(?:[/?#]|\z)}

  defp explicit_port?(url), do: Regex.match?(@explicit_port, url)

  defp unbracket("[" <> rest), do: String.trim_trailing(rest, "]")
  defp unbracket(host), do: host

  defp drop_trailing_dot(host) do
    if String.ends_with?(host, "."),
      do: binary_part(host, 0, byte_size(host) - 1),
      else: host
  end

  @doc """
  The lowercase names of the headers that carry a credential by name:
  `authorization`, `cookie`, `proxy-authorization`, `x-api-key`,
  `x-auth-token`, `x-access-token` and `x-csrf-token`. Any name ending in
  `-token`, `-key` or `-secret` carries one too (`credential_header?/1`).
  """
  @spec credential_headers() :: [String.t()]
  def credential_headers, do: @credential_headers

  @doc """
  Whether a header `name`, in any case, carries a credential: one of
  `credential_headers/0`, or a name ending in `-token`, `-key` or `-secret`.
  """
  @spec credential_header?(term()) :: boolean()
  def credential_header?(name) when is_binary(name) do
    name = String.downcase(name)
    name in @credential_headers or String.ends_with?(name, @credential_suffixes)
  end

  def credential_header?(_name), do: false

  @doc """
  `headers` without any `{name, value}` pair whose name
  `credential_header?/1` accepts, the rest in their order.
  """
  @spec strip_credentials([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def strip_credentials(headers) when is_list(headers),
    do: Enum.reject(headers, &credential_pair?/1)

  defp credential_pair?({name, _value}), do: credential_header?(name)
  defp credential_pair?(_header), do: false

  @doc """
  Whether `host` matches one of the `egress.domains` `patterns`.

  `"*"` matches any host. `"*.example.com"` matches every name below
  `example.com` (`a.example.com`, `a.b.example.com`) and neither
  `example.com` itself nor a name sharing only part of a label
  (`aexample.com`). Any other pattern matches exactly. Host and pattern
  compare case-folded, each with one trailing dot dropped. An empty host,
  or no pattern, matches nothing.
  """
  @spec domain_allowed?(String.t() | nil, [String.t()]) :: boolean()
  def domain_allowed?(host, patterns) when is_binary(host) and is_list(patterns) do
    host = host |> drop_trailing_dot() |> String.downcase()
    host != "" and Enum.any?(patterns, &domain_matches?(&1, host))
  end

  def domain_allowed?(_host, _patterns), do: false

  defp domain_matches?("*", _host), do: true

  defp domain_matches?("*." <> base, host) do
    case base |> drop_trailing_dot() |> String.downcase() do
      "" -> false
      base -> String.ends_with?(host, "." <> base)
    end
  end

  defp domain_matches?(pattern, host) when is_binary(pattern),
    do: pattern |> drop_trailing_dot() |> String.downcase() == host

  defp domain_matches?(_pattern, _host), do: false
end
