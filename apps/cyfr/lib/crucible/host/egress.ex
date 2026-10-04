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
  never the runner's copy of it, in this order:

    1. the URL's host matches the edge's `egress.domains`
       (`Prima.Network.domain_allowed?/2`, where `"*"` matches every
       host); an authority with no edge, an edge with no egress, and a
       host no pattern matches are `denied`;
    2. a `redirect` names, as `from`, a pin this attempt was answered
       within the last two windows, and its URL has that pin's origin
       (`Prima.Network.same_origin?/2`: scheme, host and effective port);
       anything else is `redirect_credentials`. The engine carries the
       request's credentials on a guest's redirect, so the hop stays on
       its pin's origin: a hop elsewhere is refused, not stripped;
    3. only then is the host resolved, once, through
       `Sanctum.Network.pin/2`, IPv4 first and IPv6 only when no IPv4
       address resolves, and a name that resolves to nothing is
       `resolution`. A host the names refused is never resolved, so a
       guest cannot carry data out in the labels of a name its policy
       refuses;
    4. a metadata address (`Prima.Cidr.metadata?/1`) is `metadata`,
       whatever the policy grants;
    5. a private address (`Prima.Cidr.private_ip?/1`) is `denied` unless
       the edge grants it (`egress.private_ips`, IPs and CIDRs); an
       authority with no edge, or an edge with no egress, grants no
       private address. The operator's `CYFR_PRIVATE_EGRESS_TARGETS` is
       the control plane's own and never applies to a guest.

  A pin answers the address with the URL's scheme and port, its host (an
  IPv6 literal in brackets), an `id` minted for it and an `expires_at` one
  header window (`Prima.WorkerAuth.window_ms/0`) past the call. Each of
  the four refusals is recorded as a denial of the attempt's component in
  its athanor (`Sanctum.Policy.Enforcement.record/1`, as
  `Crucible.Host.Storage` records a runner's `record_denial`), its reason
  led by the request's purpose (`fetch: …`, `attached: …`) and naming the
  host and never the URL, whose path and query can carry a credential.

  `pin/3` takes the purposes a runner may ask for and `:attached`, the pin
  CYFR takes for an attached request (`Crucible.Host.AttachedFetch`), which
  is decided the same way and recorded as its own; a runner's
  `egress_pin` naming `attached` never reaches here, since its args do not
  read (`Prima.PinnedTarget.read_request/1`).

  Pins are not persisted. The pins an attempt was answered are kept, each
  as its origin (a `%URI{}` of its scheme, host and port) under the
  attempt and its id, in a node-local ETS table for two header windows,
  which is as long as a redirect of the request a pin was answered for
  can follow it: one window for the pin and one for the answer's own
  timeout (`Prima.HostAPI.request_timeout_ms/1`). A row of any other
  shape names no pin a redirect may follow.
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
          record(chain, request.purpose, sentence)
          {:error, refusal}
      end
    end
  end

  defp decide(caller, request, authority, resolver, now) do
    edge = edge(authority)

    # The name checks come before the resolution: a refused host is never
    # looked up.
    with {:ok, uri} <- parse(request.url),
         :ok <- domain_allowed(uri, edge),
         :ok <- same_origin(caller, request, uri, now),
         {:ok, pinned} <- resolve(request.url, resolver),
         :ok <- permitted(pinned, private_ips(edge)) do
      pinned(pinned, now)
    end
  end

  defp parse(url) do
    case Prima.Network.parse_url(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _invalid, sentence} -> {:refused, :malformed, sentence}
    end
  end

  # Resolved once, under no private-address policy: a metadata address is
  # this step's one refusal, and it is refused before any policy. The
  # private-address policy is applied to that same address next, so
  # nothing is resolved twice.
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

  # The admitted authority's edge; an authority with none (`resources:
  # :none`) reads as `nil`, which allows no domain and grants no private
  # address.
  defp edge(%Authority{resources: %Edge{} = edge}), do: edge
  defp edge(_authority), do: nil

  defp domain_allowed(%URI{host: host} = uri, edge) do
    if Prima.Network.domain_allowed?(host, Edge.domains(edge)),
      do: :ok,
      else: {:refused, :denied, "host #{host_of(uri)} is not in the egress domains"}
  end

  defp private_ips(%Edge{egress: %{private_ips: ips}}) when is_list(ips), do: ips
  defp private_ips(_edge), do: []

  # A redirect carries the request's credentials, so it keeps to the
  # origin of the pin it follows: a hop to another scheme, host or port,
  # or from a pin this attempt was never answered (or no longer
  # remembers), is refused.
  defp same_origin(_caller, %{purpose: purpose}, _uri, _now) when purpose != :redirect, do: :ok

  defp same_origin(caller, %{from: from}, uri, now) do
    case :ets.lookup(@table, {caller.attempt, from}) do
      [{_key, %URI{} = origin, keep_until}] when is_integer(keep_until) and keep_until >= now ->
        if Prima.Network.same_origin?(uri, origin),
          do: :ok,
          else: redirect_refused("to another origin than its pin's", uri)

      _unknown ->
        redirect_refused("from a pin this attempt holds none of", uri)
    end
  end

  defp redirect_refused(why, uri) do
    {:refused, :redirect_credentials,
     "redirect to #{scheme_of(uri)}://#{host_of(uri)}:#{uri.port} refused with credentials: " <>
       why}
  end

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
    origin = %URI{scheme: pin.scheme, host: pin.host, port: pin.port}
    :ets.insert(@table, {{caller.attempt, pin.id}, origin, now + @keep_ms})
    :ok
  end

  # The same record a runner's `record_denial` of a policy refusal writes,
  # attributed to the attempt's component in its guest context, its reason
  # led by the purpose the pin was asked for.
  defp record(chain, purpose, sentence) do
    Sanctum.Policy.Enforcement.record(%{
      ctx: chain.ctx,
      component_ref: chain.component_ref,
      component_type: :catalyst,
      event_type: :denied,
      decision: :denied,
      decision_reason: "#{purpose}: #{sentence}"
    })
  end

  defmodule Pins do
    @moduledoc false
    # The node's table of recent pins, `{{attempt, id}, origin,
    # keep_until}`, owned here and swept each header window of every row
    # past its keep_until and every row of another shape, which no lookup
    # answers. A host listener starts one; a second listener on the same
    # node finds the first and starts nothing, so every listener's calls
    # share one table.

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

      :ets.select_delete(@table, [
        {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]},
        {:_, [{:"=/=", {:tuple_size, :"$_"}, 3}], [true]}
      ])

      Process.send_after(self(), :sweep, @window_ms)
      {:noreply, state}
    end
  end
end
