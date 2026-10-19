# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Ingress do
  @moduledoc """
  The endpoint's listeners, and the ingress each one tags its requests
  with. The listener that accepted a request is the boundary: no header,
  `Host` or `Origin` stands in for it.

  The endpoint's Phoenix adapter (`adapter:` in `config/config.exs`)
  starts them as server children of the endpoint's own supervisor, so they
  start after its configuration, stop after Phoenix's socket drainer has
  closed the sockets they carry, and neither starts under `server: false`:

    * the loopback listener, the endpoint's `http:` options, in every
      mode: the address this machine's loopback reaches
      (`CYFR_BIND_ADDRESS:CYFR_PORT`). It is Phoenix's own child,
      `{endpoint, :http}`.
    * the proxy listener, the endpoint's `proxy:` options (its `ip:` and
      `port:`), in a tailnet or public home alone: the address Tailscale
      Serve or Caddy forwards to (`CYFR_PROXY_BIND_ADDRESS:CYFR_PROXY_PORT`).
      It runs under its own supervisor, the child `CyfrWeb.Ingress.Proxy`
      the admission roster names, so the census tells it from the loopback
      listener (`Cyfr.Application.listeners/1`). It takes every Bandit
      option of the loopback listener but its address and port, so the
      drain, the read timeout and HTTP/1.1 alone hold on both.

  `config/runtime.exs` writes both from the home's access settings
  (`Cyfr.RuntimeConfig.resolve_access/1`). The endpoint serves no TLS
  listener of its own: TLS is the proxy's.

  Each listener's plug is this module around the endpoint, and its first
  act tags the request with the listener (`Sanctum.ClientIp.put_ingress/2`):
  in `conn.private`, and as the one `x-cyfr-ingress` request header after
  every copy the client sent is deleted, so a socket transport's
  `connect_info` carries the listener's tag and never a client's. It runs
  before the endpoint's `call/2`, and so before `socket_dispatch` hands
  the request to a socket transport.

  On the proxy listener it then sets the request's scheme and port to
  `https` and 443: the proxy terminated the TLS the client spoke, so a URL
  the request names itself by (`Plug.Conn.request_url/1`, an OpenID
  Connect callback's) is the home's own address. And it registers the
  endpoint's HSTS (`CyfrWeb.Plugs.ApiSecurityHeaders.maybe_hsts/1`) on
  every response the listener sends, success, error and a refusal made
  before any pipeline alike.
  """

  @behaviour Plug

  import Plug.Conn, only: [register_before_send: 2]

  alias CyfrWeb.Plugs.ApiSecurityHeaders

  # The proxy listener's child id under the endpoint's supervisor, the
  # name the admission roster and the listener census know it by.
  @proxy __MODULE__.Proxy

  @doc "The proxy listener's child id, the name the admission roster gives it."
  @spec proxy_listener() :: module()
  def proxy_listener, do: @proxy

  @doc false
  # Phoenix's adapter callback: the endpoint's listeners as children of
  # its supervisor, the loopback listener always and the proxy listener
  # when the endpoint is configured with `proxy:`.
  @spec child_specs(module(), keyword()) :: [Supervisor.child_spec()]
  def child_specs(endpoint, config) do
    if config[:https] do
      raise ArgumentError,
            "the endpoint is configured with https:, but it serves no TLS listener " <>
              "of its own: TLS is the proxy's in front of its proxy listener"
    end

    http = Keyword.fetch!(config, :http)
    plug = endpoint_plug(config[:code_reloader], endpoint)
    base = [display_plug: endpoint, scheme: :http, otp_app: Keyword.fetch!(config, :otp_app)]

    loopback =
      [plug: {__MODULE__, {:loopback, plug}}]
      |> Kernel.++(base)
      |> Kernel.++(http)
      |> Bandit.child_spec()
      |> Supervisor.child_spec(id: {endpoint, :http})

    proxy =
      case config[:proxy] do
        nil ->
          []

        address ->
          server =
            [plug: {__MODULE__, {:proxy, plug}}]
            |> Kernel.++(base)
            |> Kernel.++(Keyword.drop(http, [:ip, :port]))
            |> Kernel.++(Keyword.take(address, [:ip, :port]))
            |> Bandit.child_spec()

          [
            %{
              id: @proxy,
              start: {Supervisor, :start_link, [[server], [strategy: :one_for_one]]},
              type: :supervisor
            }
          ]
      end

    [loopback | proxy]
  end

  @doc false
  # Phoenix's adapter callback, `c:Phoenix.Endpoint.server_info/1`: the
  # loopback listener is Phoenix's own `{endpoint, :http}` child.
  @spec server_info(module(), :http | :https) ::
          {:ok, ThousandIsland.Transport.socket_info()} | :error | {:error, :no_server_found}
  def server_info(endpoint, scheme), do: Bandit.PhoenixAdapter.server_info(endpoint, scheme)

  # The plug a listener hands its requests to, as Phoenix's Bandit adapter
  # picks it: the endpoint, behind the code reloader's sync when that is on.
  defp endpoint_plug(code_reload?, endpoint) do
    if code_reload? &&
         Code.ensure_loaded?(Phoenix.Endpoint.SyncCodeReloadPlug) &&
         function_exported?(Phoenix.Endpoint.SyncCodeReloadPlug, :call, 2) do
      {Phoenix.Endpoint.SyncCodeReloadPlug, {endpoint, []}}
    else
      endpoint
    end
  end

  @impl Plug
  def init({ingress, plug}) when ingress in [:loopback, :proxy] do
    {module, opts} =
      case plug do
        {module, opts} -> {module, opts}
        module -> {module, []}
      end

    {ingress, module, module.init(opts)}
  end

  @impl Plug
  def call(conn, {ingress, module, opts}) do
    conn
    |> Sanctum.ClientIp.put_ingress(ingress)
    |> listener(ingress)
    |> module.call(opts)
  end

  defp listener(conn, :loopback), do: conn

  defp listener(conn, :proxy) do
    %{conn | scheme: :https, port: 443}
    |> register_before_send(&ApiSecurityHeaders.maybe_hsts/1)
  end
end
