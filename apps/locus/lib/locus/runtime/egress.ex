# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Egress do
  @moduledoc """
  Where a guest's outbound HTTP request connects: the address CYFR pinned
  for it under the attempt's admitted authority
  (`c:Prima.HostAPI.egress_pin/3`). The runner resolves no name and
  connects nowhere: it asks CYFR for each request's pin through its relay
  and sends the request through the relay naming the pin by id, and the
  relay's service end (`Locus.Runtime.Relay`) connects.

  `names?/2` checks that a pin names a URL's own scheme, host and port.
  `connect_options/3` builds the request options that connect to exactly
  the pinned address (`Prima.Network.pin/3`), its socket reading at most
  64 KiB at a time unless told more (`transport_opts/1`). CYFR has
  already applied the attempt's private-address policy to that address,
  so the options are built under `:allow_all`, and a metadata address is
  still refused there. The pin's host is kept for TLS SNI and certificate
  verification, and the relay sets the `Host` header from the pin itself;
  the transport policy stays closed: no redirect, no retry, no
  compression, no body decoding. A pin is only an address: every request
  is still checked and charged by the relay before it connects.

  ## One request, one decision

  The relay honours a runner's pin for one fetch, only before its
  `expires_at`, and asks CYFR once more itself, for the request's URL with
  the purpose (and a redirect hop's `from`) the runner asked with, before
  it connects to the address of that answer. So CYFR decides each send
  against the authority as it stands when it leaves, never against a pin
  taken earlier.
  """

  alias Prima.PinnedTarget

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

  @read_bytes 65_536

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
end
