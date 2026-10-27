# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Admission do
  @moduledoc """
  The admission roster: every path an intent enters CYFR by, as compiled
  data. A path not on the roster admits nothing.

  Five paths are built:

    * `:loopback` — the endpoint's loopback listener, in every mode, the
      one this machine's loopback reaches: the MCP transport, the HTTP
      API and its event streams, webhooks, tinctures and their data
      routes, and the console's LiveView socket, each through the gate but
      at the entries that admit for themselves: a webhook's delivery, an
      execution's event stream, and what no person of this home admits,
      the identity directory, restore, the recovery kit, the OAuth
      callback that completes a `vault.authorize`, and the browser's
      sign-in, re-authentication and policy acceptance.
    * `:http` — the endpoint's proxy listener, in a tailnet or public
      home, the one its proxy forwards to: the same entries, reached from
      other devices.
    * `:host_api` — the HostAPI listener: a running chain's host calls,
      each admitted as a child through Opus.
    * `:scheduler` — the scheduler's fire, which listens on nothing: its
      own admission is the occurrence it claims under a held generation.
    * `:device_channel` — a paired glass's socket on the endpoint, whose
      discrete intents reach the gate once the glass has proven its key.

  Two are declared and deferred (`fetch/1`): `:unix_socket`, a local
  socket on a device, and `:compositor`, a compositor or physical jack,
  which appears as a body and never as a namespace. A deferred row is
  refused by its shape: it names no listener, socket or entry, and the
  boot refuses any listener or socket no built path names.

  Each built path names the listener it enters by, the endpoint sockets
  it enters through, and the modules of the admission entries it carries,
  the rows `Cyfr.Boundaries.admission_entries/0` drives to their refusals:
  every entry belongs to a path and every module a path names is an
  entry's. Every module is named here as data, by its name, because the
  host names no domain or surface.

  The roster is read by the composition root, never by a listener: the
  boot is refused when a listener under the supervision tree or a socket
  on the endpoint is not on it (`listener_findings/1`,
  `socket_findings/1`), so no domain or surface names this module and a
  listener cannot admit itself.
  """

  @typedoc "A path on the roster, built or declared."
  @type path ::
          :loopback
          | :http
          | :host_api
          | :scheduler
          | :device_channel
          | :unix_socket
          | :compositor

  @typedoc """
  One row: the path; whether it is built; the listener it enters by (the
  child of the supervision tree whose subtree runs its socket server), or
  nil for a path that listens on nothing; the endpoint sockets it enters
  through, `{mount path, socket module}`; the modules of the admission
  entries it carries; and why the row reads as it does.
  """
  @type row :: %{
          path: path(),
          built: boolean(),
          listener: String.t() | nil,
          sockets: [{String.t(), String.t()}],
          entries: [String.t()],
          reason: String.t()
        }

  # The endpoint's sockets and entries, which each of its listeners
  # carries: whichever accepted a request, it meets every one of them.
  @endpoint_sockets [
    {"/live", "CyfrWeb.LiveSocket"},
    # Compiled into the endpoint only when code reloading is on, in
    # development: it pushes reload notices to the page and reads nothing a
    # client sends.
    {"/phoenix/live_reload/socket", "Phoenix.LiveReloader.Socket"}
  ]

  @endpoint_entries [
    "Sanctum.Gate",
    "Emissary.MCP.Router",
    "Emissary.Web.MCPController",
    "Emissary.Web.Plugs.MCPRequestMetadata",
    "Emissary.Web.TinctureController",
    "Emissary.Web.TinctureDataController",
    "Emissary.Web.WebhookController",
    "Emissary.Web.ExecutionEventsController",
    "Emissary.Web.DirectoryController",
    "Emissary.Web.RestoreController",
    "Emissary.Web.OAuthCallbackController",
    "PrismWeb.AuthController",
    "PrismWeb.PasskeyController",
    "PrismWeb.ReauthController",
    "PrismWeb.LegalAcceptController",
    "CyfrWeb.Plugs.AuthRateLimit",
    "CyfrWeb.Plugs.Authenticate",
    "CyfrWeb.Plugs.ControlPlaneOwnership",
    "CyfrWeb.Plugs.FrameRequest",
    "CyfrWeb.Plugs.MCPOrigin",
    "CyfrWeb.Plugs.MCPRateLimit",
    "CyfrWeb.Plugs.TinctureRateLimit",
    "CyfrWeb.Plugs.VerifyWebhookSignature",
    "CyfrWeb.Plugs.WebhookIdempotency",
    "CyfrWeb.Plugs.WebhookRateLimit"
  ]

  @endpoint_reason "its pipelines' plugs, controllers and the MCP router refuse before " <>
                     "the gate, and every operation and stream they admit, and every one " <>
                     "the console's LiveView socket dispatches, enters through the " <>
                     "gate's external heads, but at the entries that admit for " <>
                     "themselves and record their own decisions: a webhook's delivery, " <>
                     "admitted under its row and run as its bound profile's root; an " <>
                     "execution's event stream, read under the caller's own standing; " <>
                     "and what no person of this CYFR admits: the identity directory, " <>
                     "whose writes the identifier's own chain authorizes, restore, an " <>
                     "entry path that runs before its person exists, and the recovery " <>
                     "kit, its own ingress (§9.1, §6.9), the OAuth callback, which " <>
                     "completes the vault.authorize the gate admitted under the state it " <>
                     "left, and the browser's sign-in, re-authentication and policy " <>
                     "acceptance, which establish a person's sign-in, prove it fresh or " <>
                     "complete it rather than act under a context the gate admitted"

  @roster [
    %{
      path: :loopback,
      built: true,
      listener: "CyfrWeb.Endpoint",
      sockets: @endpoint_sockets,
      entries: @endpoint_entries,
      reason:
        "the endpoint's loopback listener, which only this machine's loopback reaches, in " <>
          "every mode, and whose forwarded headers are never read: " <> @endpoint_reason
    },
    %{
      path: :http,
      built: true,
      listener: "CyfrWeb.Ingress.Proxy",
      sockets: @endpoint_sockets,
      entries: @endpoint_entries,
      reason:
        "the endpoint's proxy listener, which CYFR's proxy forwards to " <>
          "from other devices with tailnet or public access, the one listener whose forwarded headers are trusted from " <>
          "that proxy alone: " <> @endpoint_reason
    },
    %{
      path: :host_api,
      built: true,
      listener: "Opus.HostListener",
      sockets: [],
      entries: ["Opus.Host.Children", "Sanctum.Gate"],
      reason:
        "a runner's host call, verified by its worker service and again by the listener, " <>
          "is admitted as a child of its attempt, and its tool call enters the gate's " <>
          "in-chain head"
    },
    %{
      path: :scheduler,
      built: true,
      listener: nil,
      sockets: [],
      entries: ["Opus.Schedules.Scheduler"],
      reason:
        "a due schedule's fire is the occurrence it claims under a held generation, and " <>
          "the run it admits refused is that fire's failed completion; it listens on nothing"
    },
    %{
      path: :device_channel,
      built: true,
      listener: "CyfrWeb.Endpoint",
      sockets: [{"/device", "Emissary.Web.DeviceChannel"}],
      entries: ["Emissary.Web.DeviceChannel", "Sanctum.Gate"],
      reason:
        "a paired glass's socket, on either of the endpoint's listeners: it admits nothing " <>
          "until the glass proves its device key, then dispatches each discrete intent " <>
          "through the gate's external head"
    },
    %{
      path: :unix_socket,
      built: false,
      listener: nil,
      sockets: [],
      entries: [],
      reason: "a local socket on a device; deferred, so it admits nothing"
    },
    %{
      path: :compositor,
      built: false,
      listener: nil,
      sockets: [],
      entries: [],
      reason:
        "a compositor or physical jack, which appears as a body and never as a namespace; " <>
          "deferred, so it admits nothing"
    }
  ]

  @built for %{built: true} = row <- @roster, do: row
  @listeners @built |> Enum.map(& &1.listener) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  @sockets for row <- @built, socket <- row.sockets, do: socket

  @doc "Every row on the roster, built or declared, in its order."
  @spec roster() :: [row()]
  def roster, do: @roster

  @doc """
  One sentence per listener in `listeners` that no built path enters by,
  naming it; empty when every one is on the roster. A listener is named by
  its child id in the supervision tree.
  """
  @spec listener_findings([term()]) :: [String.t()]
  def listener_findings(listeners) when is_list(listeners) do
    for listener <- listeners,
        name = name(listener),
        name not in @listeners,
        do: "#{name} listens under the supervision tree and is on no admission path"
  end

  @doc """
  One sentence per endpoint socket in `sockets` (the endpoint's
  `__sockets__/0`: `{mount path, socket module, options}`) that no built
  path enters through at that mount; empty when every one is on the
  roster.
  """
  @spec socket_findings([{String.t(), module(), keyword()}]) :: [String.t()]
  def socket_findings(sockets) when is_list(sockets) do
    for {mount, socket, _opts} <- sockets,
        {mount, name(socket)} not in @sockets,
        do: "the endpoint's socket at #{mount} (#{name(socket)}) is on no admission path"
  end

  # A module by its name, `Opus.HostListener`; any other child id as
  # it reads.
  defp name(id), do: inspect(id)
end
