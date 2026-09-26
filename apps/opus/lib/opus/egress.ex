# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Egress do
  @moduledoc """
  Where a guest's outbound HTTP request connects: the address CYFR pinned
  for it under the attempt's admitted authority
  (`c:Prima.HostAPI.egress_pin/3`). The engine resolves no name itself.

  `pin/3` asks the attempt's host client for the pin of a URL
  (`Opus.HostClient.egress_pin/3`), checks that the pin names the URL's
  own scheme, host and port, and builds the request options that connect
  to exactly the pinned address (`Prima.Network.pin/3`). CYFR has already
  applied the attempt's private-address policy to that address, so the
  options are built under `:allow_all`, and a metadata address is still
  refused there whatever CYFR answered. The pin's host is kept for TLS
  SNI, certificate verification and the `Host` header, and the transport
  policy stays closed: no redirect, no retry, no compression, no body
  decoding. A pin is only an address: every request is still checked and
  charged as the handlers check and charge it, before it is pinned.

  A pin is reused for the next request of the same attempt with the same
  purpose to the same scheme, host and port until its `expires_at`, and
  asked for again after it. The pins live in the state of the process the
  guest's host functions run in — the component instance's, which calls
  every import itself — so they are the attempt's alone and end with its
  instance.

  ## Redirects

  The transport follows no redirect. A handler that receives a
  redirecting answer records where it points (`redirected/4`); the
  guest's next request to that URL is the redirect's next hop, pinned
  with `purpose: :redirect` naming the pin the redirecting answer came
  from, and the hop is consumed. CYFR may refuse the hop
  (`redirect_credentials`); a hop whose scheme or host differs from the
  pin it came from is `cross_origin?/1`, and its request is sent without
  the guest's credentials (`strip_credentials/1`).
  """

  alias Opus.HostClient
  alias Prima.PinnedTarget

  @typedoc """
  What `pin/3` answers: the address as text and as a tuple, the URI with
  the pin's host, the `Req` options that connect to that address with the
  fail-closed transport policy, ready for the caller's method, headers and
  body, the pin itself (`:target`) and, for a redirect's next hop, the pin
  the redirect came from (`:from`).
  """
  @type pinned :: %{
          ip: String.t(),
          ip_tuple: :inet.ip_address(),
          uri: URI.t(),
          req_opts: keyword(),
          target: PinnedTarget.t(),
          from: PinnedTarget.t() | nil
        }

  @typedoc "The guest error type of a refusal `pin/3` answers."
  @type refusal ::
          :invalid_url
          | :invalid_request
          | :dns_error
          | :private_ip_blocked
          | :redirect_credentials

  # The redirects an attempt's handlers remember before the guest follows
  # them; the oldest is forgotten first.
  @max_hops 8

  @credential_headers ["authorization", "cookie"]

  @doc """
  Pin `url` for one outbound request of the attempt `client` holds.

  ## Options

    * `:purpose` — `:fetch` (default) or `:stream`; a request to where a
      redirect the attempt received points is its next hop instead, and
      is pinned as `:redirect`
    * `:receive_timeout` — ms (default 30_000)
    * `:protocols` — Mint protocols list (e.g. `[:http1]`)
    * `:transport_opts` — extra Mint transport opts

  Answers `{:ok, pinned}` (`t:pinned/0`); `{:error, type, message}` for a
  refusal of the engine's own, which the caller records; or
  `{:refused, type, message}` for a refusal of CYFR's, which CYFR has
  already recorded as a denial of the attempt.
  """
  @spec pin(HostClient.t(), String.t(), keyword()) ::
          {:ok, pinned()}
          | {:error, refusal(), String.t()}
          | {:refused, refusal(), String.t()}
  def pin(%HostClient{} = client, url, opts \\ []) when is_binary(url) and is_list(opts) do
    purpose = if Keyword.get(opts, :purpose) == :stream, do: :stream, else: :fetch

    with {:ok, uri} <- Prima.Network.parse_url(url) do
      case take_hop(client, uri) do
        {:ok, from} -> connect(client, url, uri, :redirect, from, opts)
        :none -> connect(client, url, uri, purpose, nil, opts)
      end
    end
  end

  @doc """
  Record that the request `pinned` answered for `request_url` redirected
  to `location` (the answer's `Location`, absolute or relative to the
  request), so the attempt's next request there is pinned as the
  redirect's next hop. A location that is not an `http` or `https` URL
  with a host records nothing.
  """
  @spec redirected(HostClient.t(), pinned(), String.t(), String.t()) :: :ok
  def redirected(
        %HostClient{} = client,
        %{target: %PinnedTarget{} = target},
        request_url,
        location
      )
      when is_binary(request_url) and is_binary(location) do
    with {:ok, next} <- resolve_location(request_url, location) do
      update(client, fn state ->
        hops =
          state.hops
          |> Enum.reject(fn {url, _from} -> url == next end)
          |> Enum.take(@max_hops - 1)

        %{state | hops: [{next, target} | hops]}
      end)
    end

    :ok
  end

  @doc """
  Whether `pinned` is a redirect's next hop to another scheme or host than
  the pin its redirect came from: a request its credentials must not
  follow.
  """
  @spec cross_origin?(pinned()) :: boolean()
  def cross_origin?(%{from: nil}), do: false

  def cross_origin?(%{from: %PinnedTarget{} = from, target: %PinnedTarget{} = target}),
    do: from.scheme != target.scheme or host_key(from.host) != host_key(target.host)

  @doc "`headers` without the guest's credentials: every `Authorization` and `Cookie`, in any case."
  @spec strip_credentials([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def strip_credentials(headers) when is_list(headers), do: Enum.reject(headers, &credential?/1)

  defp credential?({name, _value}) when is_binary(name),
    do: String.downcase(name) in @credential_headers

  defp credential?(_header), do: false

  defp connect(client, url, uri, purpose, from, opts) do
    with {:ok, target} <- target(client, url, uri, purpose, from),
         {:ok, pinned} <- build(uri, target, opts) do
      if purpose != :redirect, do: remember(client, purpose, uri, target)
      {:ok, pinned |> Map.put(:target, target) |> Map.put(:from, from)}
    end
  end

  # A pin reused while it holds, or asked for. A redirect's hop is always
  # asked for: CYFR decides each hop from the pin it came from.
  defp target(client, url, uri, purpose, from) do
    case cached(client, purpose, uri) do
      {:ok, target} -> {:ok, target}
      :none -> ask(client, url, uri, purpose, from)
    end
  end

  defp ask(client, url, uri, purpose, from) do
    from_id = if from, do: from.id

    case HostClient.egress_pin(client, url, purpose: purpose, from: from_id) do
      {:ok, target} ->
        if names?(target, uri),
          do: {:ok, target},
          else: {:error, :dns_error, "HTTP egress refused: #{uri.host} was pinned elsewhere"}

      {:error, :denied} ->
        {:refused, :private_ip_blocked,
         "Address of #{uri.host} blocked: the egress policy refuses it"}

      {:error, :metadata} ->
        {:refused, :private_ip_blocked, "metadata IP blocked (resolved from #{uri.host})"}

      {:error, :resolution} ->
        {:refused, :dns_error, "DNS resolution failed for #{uri.host}"}

      {:error, :redirect_credentials} ->
        {:refused, :redirect_credentials,
         "Redirect to #{uri.host} refused: the request's credentials may not follow it"}

      {:error, :malformed} ->
        {:refused, :invalid_request, "Invalid URL"}

      {:error, :unavailable} ->
        {:error, :dns_error,
         "HTTP egress refused: the address of #{uri.host} could not be pinned"}

      {:error, _lost} ->
        {:error, :dns_error, "HTTP egress refused: the execution attempt is not current"}
    end
  end

  # The pin must be the URL's own: its scheme, its port (the scheme's
  # default when it names none) and its host, a hostname in any case or an
  # IP literal, bracketed when it is IPv6.
  defp names?(%PinnedTarget{} = target, %URI{} = uri) do
    target.scheme == uri.scheme and target.port == uri.port and
      host_key(target.host) == host_key(uri.host)
  end

  defp build(uri, target, opts) do
    Prima.Network.pin(
      %{uri | host: unbracket(target.host)},
      PinnedTarget.address(target),
      opts
      |> Keyword.take([:receive_timeout, :protocols, :transport_opts])
      |> Keyword.put(:private_policy, :allow_all)
    )
  end

  defp host_key(host), do: host |> unbracket() |> String.downcase()

  defp unbracket("[" <> rest), do: String.trim_trailing(rest, "]")
  defp unbracket(host), do: host

  defp resolve_location(request_url, location) do
    next = request_url |> URI.merge(location) |> URI.to_string()

    case Prima.Network.parse_url(next) do
      {:ok, _uri} -> {:ok, next}
      {:error, _type, _message} -> :error
    end
  rescue
    ArgumentError -> :error
  end

  # ============================================================================
  # The attempt's pins, in the calling process's state
  # ============================================================================

  defp take_hop(client, uri) do
    url = URI.to_string(uri)
    state = state(client)

    case List.keytake(state.hops, url, 0) do
      {{^url, from}, hops} ->
        put_state(client, %{state | hops: hops})
        {:ok, from}

      nil ->
        :none
    end
  end

  defp cached(client, purpose, uri) do
    now = System.system_time(:millisecond)

    case Map.fetch(state(client).pins, key(purpose, uri)) do
      {:ok, target} -> if PinnedTarget.expired?(target, now), do: :none, else: {:ok, target}
      :error -> :none
    end
  end

  defp remember(client, purpose, uri, target) do
    now = System.system_time(:millisecond)

    update(client, fn state ->
      pins =
        state.pins
        |> Map.reject(fn {_key, pin} -> PinnedTarget.expired?(pin, now) end)
        |> Map.put(key(purpose, uri), target)

      %{state | pins: pins}
    end)
  end

  defp key(purpose, uri), do: {purpose, uri.scheme, host_key(uri.host), uri.port}

  # Keyed by the attempt, so a process that ran another attempt's guest
  # never hands this one its pins.
  defp state(client),
    do: Process.get({__MODULE__, client.attempt}, %{pins: %{}, hops: []})

  defp put_state(client, state), do: Process.put({__MODULE__, client.attempt}, state)

  defp update(client, fun), do: put_state(client, fun.(state(client)))
end
