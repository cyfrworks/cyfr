# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Egress do
  @moduledoc """
  Where a guest's outbound HTTP request connects: the address CYFR pinned
  for it under the attempt's admitted authority
  (`c:Prima.HostAPI.egress_pin/3`). The engine resolves no name itself,
  and the runner connects nowhere: its relay's service end does.

  In the runner, `pin/3` asks the attempt's host client for the pin of a
  URL (`Locus.Runtime.HostClient.egress_pin/3`), a call the relay's service end
  reads the answer of and keeps as a pin granted to that attempt, checks
  that the pin names the URL's own scheme, host and port (`names?/2`), and
  that its address is no metadata address whatever CYFR answered. The
  runner's handlers then send the request through the relay naming the pin
  by id (`Locus.Runtime.Relay.Runner.fetch/7`).

  In the service, `connect_options/3` builds the request options that
  connect to exactly the pinned address (`Prima.Network.pin/3`), its
  socket reading at most 64 KiB at a time unless told more
  (`transport_opts/1`). CYFR has
  already applied the attempt's private-address policy to that address,
  so the options are built under `:allow_all`, and a metadata address is
  still refused there. The pin's host is kept for TLS SNI and certificate
  verification, and the relay sets the `Host` header from the pin itself
  (`Locus.Runtime.Relay`); the transport policy stays
  closed: no redirect, no retry, no compression, no body decoding. A pin
  is only an address: every request is still checked and charged, by the
  handlers and again by the relay, before it connects.

  ## One request, one decision

  The engine keeps no pin: every request asks CYFR for its own, and a
  stream asks again right before its delayed send (`repin/3`). The relay's
  service end honours a runner's pin for one fetch, only before its
  `expires_at`, and asks CYFR once more itself, for the request's URL with
  the purpose (and a redirect hop's `from`) the runner asked with, before
  it connects to the address of that answer (`Locus.Runtime.Relay`). So
  CYFR decides each send against the authority as it stands when it
  leaves, never against a pin taken earlier.

  `refusal/2` is how every refused pin reaches the guest, whichever end
  asked for it: a relay that ends a fetch because its own ask got no pin
  names why with `Prima.RunnerRelay.pin_code/1`, and the runner's
  handlers read that code back with `relay_refusal/2`.

  ## Redirects

  The transport follows no redirect. A handler that receives a
  redirecting answer records where it points (`redirected/4`); the
  guest's next request to that URL is the redirect's next hop, pinned
  with `purpose: :redirect` naming the pin the redirecting answer came
  from, and the hop is consumed. CYFR refuses a hop to another origin
  than the pin it came from (`redirect_credentials`), since the request
  carries the guest's credentials. The engine checks it again: a pin
  answered for a hop whose scheme, host or effective port differs from
  its pin's (`Prima.Network.same_origin?/2`) is refused the same way, as
  the engine's own, and nothing is sent. The redirects an attempt's
  handlers remember live in the state of the process the guest's host
  functions run in — the component instance's, which calls every import
  itself — so they are the attempt's alone and end with its instance.
  """

  alias Locus.Runtime.HostClient
  alias Prima.PinnedTarget

  @typedoc """
  What `pin/3` answers: the address as text and as a tuple, the URI with
  the pin's host, the pin itself (`:target`), whose id the relay's fetch
  names, the purpose it was asked for (`:purpose`) and, for a redirect's
  next hop, the pin the redirect came from (`:from`).
  """
  @type pinned :: %{
          ip: String.t(),
          ip_tuple: :inet.ip_address(),
          uri: URI.t(),
          target: PinnedTarget.t(),
          purpose: :fetch | :stream | :redirect,
          from: PinnedTarget.t() | nil
        }

  @typedoc """
  What `connect_options/3` answers: the address as text and as a tuple,
  the URI with the pin's host, and the `Req` options that connect to that
  address with the fail-closed transport policy, ready for the caller's
  method, headers and body.
  """
  @type connection :: %{
          ip: String.t(),
          ip_tuple: :inet.ip_address(),
          uri: URI.t(),
          req_opts: keyword()
        }

  @typedoc "The guest error type of a refused pin."
  @type refusal ::
          :domain_blocked
          | :invalid_url
          | :invalid_request
          | :dns_error
          | :private_ip_blocked
          | :redirect_credentials

  @typedoc """
  Why a request got no pin: a refusal CYFR answered
  (`Prima.PinnedTarget.refusals/0`), or the engine's own — CYFR's answer
  unavailable or lost, a pin naming another target than the request's
  (`:elsewhere`), a pin for a redirect's next hop to another origin than
  the pin it came from (`:cross_origin`), or a runner's pin past its
  `expires_at` when the relay was handed its request (`:expired`).
  """
  @type why ::
          PinnedTarget.refusal() | :unavailable | :lost | :elsewhere | :cross_origin | :expired

  # The redirects an attempt's handlers remember before the guest follows
  # them; the oldest is forgotten first.
  @max_hops 8

  @read_bytes 65_536

  @doc """
  Pin `url` for one outbound request of the attempt `client` holds: CYFR
  is asked for every request, and its answer serves that request alone.

  ## Options

    * `:purpose` — `:fetch` (default) or `:stream`; a request to where a
      redirect the attempt received points is its next hop instead, and
      is pinned as `:redirect`

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
        {:ok, from} -> connect(client, url, uri, :redirect, from)
        :none -> connect(client, url, uri, purpose, nil)
      end
    end
  end

  @doc """
  Ask CYFR again for the request `pinned` was answered for, `url`, right
  before it is sent: with the same purpose and, for a redirect's next hop,
  from the same pin, so the send is decided against what the run has read
  by then. Answers as `pin/3` does; consumes no redirect hop.
  """
  @spec repin(HostClient.t(), String.t(), pinned()) ::
          {:ok, pinned()}
          | {:error, refusal(), String.t()}
          | {:refused, refusal(), String.t()}
  def repin(%HostClient{} = client, url, %{purpose: purpose, from: from}) when is_binary(url) do
    with {:ok, uri} <- Prima.Network.parse_url(url),
         do: connect(client, url, uri, purpose, from)
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
  Whether the pin `target` is the URL `uri`'s own: its scheme, its port
  (the scheme's default when the URL names none) and its host, a hostname
  in any case or an IP literal, bracketed or not when it is IPv6.
  """
  @spec names?(PinnedTarget.t(), URI.t()) :: boolean()
  def names?(%PinnedTarget{} = target, %URI{} = uri) do
    target.scheme == uri.scheme and target.port == uri.port and
      host_key(target.host) == host_key(uri.host || "")
  end

  @doc """
  The socket options of a connection the service reads for its runners
  `read_bytes` at a time, a pinned fetch's and CYFR's host calls': 64 KiB
  unless a fetch has its count's room for more (`Locus.Runtime.Relay`), so
  the piece a holder keeps while it asks the runtime's count for room is
  at most one read, and the kernel queues at most as much of what the
  peer sent and the service has not yet read. The HTTP client widens a
  socket's read buffer (`buffer`) to its send and receive buffers as the
  kernel reports them once it has connected, and Linux reports each at
  twice what was set: each is set to half the read.
  """
  @spec transport_opts(pos_integer()) :: keyword()
  def transport_opts(read_bytes \\ @read_bytes) when is_integer(read_bytes) and read_bytes > 1,
    do: [buffer: read_bytes, recbuf: div(read_bytes, 2), sndbuf: div(read_bytes, 2)]

  @doc """
  The request options that connect to exactly the address `target` pins,
  for `uri` (its path and query the request's), keeping the pin's host for
  TLS SNI and certificate verification; the relay sets the `Host` header
  from the pin itself (`Locus.Runtime.Relay`). A metadata
  address is `{:error, :private_ip_blocked, message}`.

  Its socket is made with `transport_opts/1`.

  ## Options

    * `:receive_timeout` — ms (default 30_000)
    * `:protocols` — Mint protocols list (e.g. `[:http1]`)
    * `:read_bytes` — what its socket reads at a time (default 65_536)
  """
  @spec connect_options(PinnedTarget.t(), URI.t(), keyword()) ::
          {:ok, connection()} | {:error, :private_ip_blocked, String.t()}
  def connect_options(%PinnedTarget{} = target, %URI{} = uri, opts) when is_list(opts),
    do: build(uri, target, opts)

  @doc """
  How a request to `host` that got no pin, for `why` (`t:why/0`), answers
  the guest: a refusal CYFR answered as `{:refused, type, message}`, since
  CYFR has already recorded it as a denial of the attempt; the engine's
  own as `{:error, type, message}`, which the caller records. A sentence
  names the host, never the URL, whose path and query can carry a
  credential.
  """
  @spec refusal(term(), String.t()) ::
          {:refused, refusal(), String.t()} | {:error, refusal(), String.t()}
  # A host outside the edge's domains, in the words of CYFR's own refusal
  # of an attached request's.
  def refusal(:domain, host),
    do: {:refused, :domain_blocked, "HTTP egress refused: #{host} is not in the egress domains"}

  def refusal(:denied, host),
    do:
      {:refused, :private_ip_blocked, "Address of #{host} blocked: the egress policy refuses it"}

  def refusal(:metadata, host),
    do: {:refused, :private_ip_blocked, "metadata IP blocked (resolved from #{host})"}

  def refusal(:resolution, host), do: {:refused, :dns_error, Prima.Network.dns_failure(host)}

  def refusal(:redirect_credentials, host),
    do: {:refused, :redirect_credentials, redirect_refused(host)}

  def refusal(:malformed, _host), do: {:refused, :invalid_request, "Invalid URL"}

  def refusal(:elsewhere, host),
    do: {:error, :dns_error, "HTTP egress refused: #{host} was pinned elsewhere"}

  def refusal(:cross_origin, host), do: {:error, :redirect_credentials, redirect_refused(host)}

  def refusal(:expired, host),
    do:
      {:error, :dns_error,
       "HTTP egress refused: the pin for #{host} expired before its request was sent"}

  def refusal(:unavailable, host),
    do: {:error, :dns_error, "HTTP egress refused: the address of #{host} could not be pinned"}

  def refusal(_lost, _host),
    do: {:error, :dns_error, "HTTP egress refused: the execution attempt is not current"}

  @doc """
  How a fetch the relay ended with `code` answers the guest, for a request
  to `host`, when the code is a `Prima.RunnerRelay.pin_code/1`: as
  `refusal/2` answers that reason. Any other code is `:none`.
  """
  @spec relay_refusal(term(), String.t()) ::
          {:refused, refusal(), String.t()} | {:error, refusal(), String.t()} | :none
  def relay_refusal(code, host) do
    case Prima.RunnerRelay.pin_why(code) do
      {:ok, why} -> refusal(why, host)
      :error -> :none
    end
  end

  defp connect(client, url, uri, purpose, from) do
    with {:ok, target} <- ask(client, url, uri, purpose, from),
         {:ok, pinned} <- build(uri, target, []) do
      {:ok,
       pinned
       |> Map.delete(:req_opts)
       |> Map.merge(%{target: target, purpose: purpose, from: from})}
    end
  end

  # Every request is asked for: a pin is never reused, so CYFR decides each
  # one against what the run has read when it is asked. A pin CYFR answered
  # for a redirect's next hop to another origin is refused as CYFR refuses
  # one: the request carries the guest's credentials.
  defp ask(client, url, uri, purpose, from) do
    from_id = if from, do: from.id

    case HostClient.egress_pin(client, url, purpose: purpose, from: from_id) do
      {:ok, target} ->
        cond do
          not names?(target, uri) -> refusal(:elsewhere, uri.host)
          not same_origin?(from, target) -> refusal(:cross_origin, uri.host)
          true -> {:ok, target}
        end

      {:error, why} ->
        refusal(why, uri.host)
    end
  end

  defp same_origin?(nil, _target), do: true

  defp same_origin?(%PinnedTarget{} = from, %PinnedTarget{} = target),
    do: Prima.Network.same_origin?(origin(from), origin(target))

  defp origin(%PinnedTarget{scheme: scheme, host: host, port: port}),
    do: %URI{scheme: scheme, host: host, port: port}

  defp redirect_refused(host),
    do: "Redirect to #{host} refused: the request's credentials may not follow it"

  defp build(uri, target, opts) do
    Prima.Network.pin(
      %{uri | host: unbracket(target.host)},
      PinnedTarget.address(target),
      opts
      |> Keyword.take([:receive_timeout, :protocols])
      |> Keyword.merge(
        transport_opts: transport_opts(Keyword.get(opts, :read_bytes, @read_bytes)),
        private_policy: :allow_all
      )
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
  # The attempt's redirects, in the calling process's state
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

  # Keyed by the attempt, so a process that ran another attempt's guest
  # never hands this one its redirects.
  defp state(client), do: Process.get({__MODULE__, client.attempt}, %{hops: []})

  defp put_state(client, state), do: Process.put({__MODULE__, client.attempt}, state)

  defp update(client, fun), do: put_state(client, fun.(state(client)))
end
