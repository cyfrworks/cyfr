# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Host.Egress do
  @moduledoc """
  The host call a runner makes before its guest's outbound request:
  `egress_pin` (`c:Prima.HostAPI.egress_pin/3`). The engine resolves no
  name itself; CYFR resolves the URL's host, decides the address under the
  authority it holds for the calling attempt, and answers the address the
  engine connects to (`Prima.PinnedTarget`).

  `Crucible.Host` verifies the call and reads its args
  (`Prima.PinnedTarget.read_request/1`, `malformed` otherwise) before
  `pin/3` acts. The attempt must be held by the calling runner and live,
  as for a child or a catalog tool (`Crucible.Attempt.call/3` with
  `:chain`); otherwise the call is `lost` or `unavailable` and nothing is
  resolved. What decides the address is the run's admitted authority,
  never the runner's copy of it:

    1. a `redirect` names, as `from`, a pin this attempt was answered
       within the last two windows, and keeps its scheme and host;
       anything else is `redirect_credentials`, since the engine carries
       the request's credentials only on such a hop;
    2. the host is resolved once through `Sanctum.Network.pin/2`, IPv4
       first and IPv6 only when no IPv4 address resolves, and a name that
       resolves to nothing is `resolution`;
    3. a metadata address (`Prima.Cidr.metadata?/1`) is `metadata`,
       before any policy is consulted;
    4. a private address (`Prima.Cidr.private_ip?/1`) is `denied` unless
       the authority's edge grants it (`egress.private_ips`, IPs and
       CIDRs); an authority with no edge, or an edge with no egress,
       grants no private address. The operator's
       `CYFR_PRIVATE_EGRESS_TARGETS` is the control plane's own and never
       applies to a guest.

  A pin answers the address with the URL's scheme and port, its host (an
  IPv6 literal in brackets), an `id` minted for it and an `expires_at` one
  header window (`Prima.WorkerAuth.window_ms/0`) past the call. Each of
  the four refusals is recorded as a denial of the attempt's component in
  its athanor (`Sanctum.Policy.Enforcement.record/1`, as
  `Crucible.Host.Storage` records a runner's `record_denial`), naming the
  host and never the URL, whose path and query can carry a credential.

  Pins are not persisted. The pins an attempt was answered are kept, as
  `{id, host, scheme}` under the attempt, in a node-local ETS table for
  two header windows, which is as long as a redirect of the request a pin
  was answered for can follow it: one window for the pin and one for the
  answer's own timeout (`Prima.HostAPI.request_timeout_ms/1`).
  `Crucible.Host.Egress.Pins` owns the table and sweeps it; every host
  listener (`Crucible.HostListener`) starts one, and the first started
  holds the table for the node.
  """

  alias Crucible.Attempt
  alias Prima.Authority
  alias Prima.Authority.Blob.Edge
  alias Prima.PinnedTarget

  @window_ms Prima.WorkerAuth.window_ms()
  @keep_ms 2 * @window_ms
  @table __MODULE__

  @typedoc "What `pin/3` answers."
  @type answer ::
          {:ok, PinnedTarget.t()}
          | {:error, :lost | :unavailable | PinnedTarget.refusal()}

  @doc """
  Pin the address the attempt of `caller` (the verified header) may reach
  `request`'s URL at, for its purpose. Options: `:now` (Unix ms, default
  the clock) and `:resolver` (a module answering `getaddr/2` as `:inet`
  does, default `:inet`), which `Crucible.Host` never passes.
  """
  @spec pin(Attempt.caller(), PinnedTarget.request(), keyword()) :: answer()
  def pin(caller, %{url: url, purpose: _purpose} = request, opts \\ []) when is_binary(url) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)
    resolver = Keyword.get(opts, :resolver, :inet)

    with {:ok, chain} <- Attempt.call(caller.execution_id, caller, :chain) do
      case decide(caller, request, chain.authority, resolver, now) do
        {:ok, pin} ->
          remember(caller, pin, now)
          {:ok, pin}

        {:refused, :malformed, _sentence} ->
          {:error, :malformed}

        {:refused, refusal, sentence} ->
          record(chain, sentence)
          {:error, refusal}
      end
    end
  end

  defp decide(caller, request, authority, resolver, now) do
    with :ok <- same_origin(caller, request, now),
         {:ok, pinned} <- resolve(request.url, resolver),
         :ok <- permitted(pinned, private_ips(authority)) do
      pinned(pinned, now)
    end
  end

  # A redirect carries the request's credentials only to the origin of the
  # pin it follows; a hop to another scheme or host, or from a pin this
  # attempt was never answered (or no longer remembers), is refused before
  # anything is resolved.
  defp same_origin(_caller, %{purpose: purpose}, _now) when purpose != :redirect, do: :ok

  defp same_origin(caller, %{url: url, from: from}, now) do
    {:ok, uri} = Prima.Network.parse_url(url)

    case :ets.lookup(@table, {caller.attempt, from}) do
      [{_key, host, scheme, keep_until}] when keep_until >= now ->
        if host == host_of(uri) and scheme == scheme_of(uri),
          do: :ok,
          else: redirect_refused("to another origin than its pin's", uri)

      _unknown ->
        redirect_refused("from a pin this attempt holds none of", uri)
    end
  end

  defp redirect_refused(why, uri) do
    {:refused, :redirect_credentials,
     "redirect to #{scheme_of(uri)}://#{host_of(uri)} refused with credentials: #{why}"}
  end

  # Resolved once, under no private-address policy: a metadata address is
  # the one refusal left, and it is refused before any policy. The policy
  # is applied to that same address next, so nothing is resolved twice.
  defp resolve(url, resolver) do
    case Sanctum.Network.pin(url, private_policy: :allow_all, resolver: resolver) do
      {:ok, pinned} -> {:ok, pinned}
      {:error, :private_ip_blocked, sentence} -> {:refused, :metadata, sentence}
      {:error, :dns_error, sentence} -> {:refused, :resolution, sentence}
      {:error, _invalid, sentence} -> {:refused, :malformed, sentence}
    end
  end

  defp permitted(pinned, private_ips) do
    case Prima.Network.pin(pinned.uri, pinned.ip_tuple, private_policy: {:allowlist, private_ips}) do
      {:ok, _pinned} -> :ok
      {:error, :private_ip_blocked, sentence} -> {:refused, :denied, sentence}
    end
  end

  # The admitted authority's edge; an authority with none grants no private
  # address.
  defp private_ips(%Authority{resources: %Edge{egress: %{private_ips: ips}}}) when is_list(ips),
    do: ips

  defp private_ips(_authority), do: []

  defp pinned(%{ip: ip, ip_tuple: ip_tuple, uri: uri}, now) do
    pin = %PinnedTarget{
      id: "pin_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      ip: ip,
      family: if(tuple_size(ip_tuple) == 4, do: 4, else: 6),
      scheme: scheme_of(uri),
      port: uri.port,
      host: host_of(uri),
      expires_at: now + @window_ms
    }

    if PinnedTarget.valid?(pin),
      do: {:ok, pin},
      else: {:refused, :malformed, "the URL names no host a pin can carry"}
  end

  # `URI` answers an IPv6 literal without its brackets; a pin carries it as
  # the Host header and the certificate name it, in brackets.
  defp host_of(%URI{host: host}) do
    host = String.downcase(host)

    case :inet.parse_ipv6strict_address(String.to_charlist(host)) do
      {:ok, _address} -> "[" <> host <> "]"
      {:error, _not_v6} -> host
    end
  end

  defp scheme_of(%URI{scheme: scheme}), do: String.downcase(scheme)

  defp remember(caller, pin, now) do
    :ets.insert(@table, {{caller.attempt, pin.id}, pin.host, pin.scheme, now + @keep_ms})
    :ok
  end

  # The same record a runner's `record_denial` of a policy refusal writes,
  # attributed to the attempt's component in its guest context.
  defp record(chain, sentence) do
    Sanctum.Policy.Enforcement.record(%{
      ctx: chain.ctx,
      component_ref: chain.component_ref,
      component_type: :catalyst,
      event_type: :denied,
      decision: :denied,
      decision_reason: sentence
    })
  end

  defmodule Pins do
    @moduledoc false
    # The node's table of recent pins, `{{attempt, id}, host, scheme,
    # keep_until}`, owned here and swept each header window. A host
    # listener starts one; a second listener on the same node finds the
    # first and starts nothing, so every listener's calls share one table.

    use GenServer

    @table Crucible.Host.Egress
    @window_ms Prima.WorkerAuth.window_ms()

    def child_spec(_opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, []}, shutdown: 5_000}
    end

    def start_link do
      case GenServer.start_link(__MODULE__, :ok, name: __MODULE__) do
        {:error, {:already_started, _holder}} -> :ignore
        started -> started
      end
    end

    @impl true
    def init(:ok) do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

      Process.send_after(self(), :sweep, @window_ms)
      {:ok, nil}
    end

    @impl true
    def handle_info(:sweep, state) do
      now = System.system_time(:millisecond)
      :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
      Process.send_after(self(), :sweep, @window_ms)
      {:noreply, state}
    end
  end
end
