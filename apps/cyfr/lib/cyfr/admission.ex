# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Admission do
  @moduledoc """
  The admission roster: every path an intent enters CYFR by, as compiled
  data. A path not on the roster admits nothing.

  Four paths are built:

    * `:http` — the endpoint: the MCP transport, the HTTP API and its
      event streams, webhooks, tinctures and their data routes, and the
      console's LiveView socket, each through the gate.
    * `:host_api` — the HostAPI listener: a running chain's host calls,
      each admitted as a child through Crucible.
    * `:scheduler` — the scheduler's fire, which listens on nothing: its
      own admission is the occurrence it claims under a held generation.
    * `:device_channel` — a paired glass's socket on the endpoint, whose
      discrete intents reach the gate once the glass has proven its key.

  Two are declared and refused as not built (`fetch/1`): `:unix_socket`,
  a local socket on a device, and `:compositor`, a compositor or physical
  jack, which appears as a body and never as a namespace.

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
  @type path :: :http | :host_api | :scheduler | :device_channel | :unix_socket | :compositor

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

  @roster [
    %{
      path: :http,
      built: true,
      listener: "CyfrWeb.Endpoint",
      sockets: [
        {"/live", "Phoenix.LiveView.Socket"},
        # Compiled into the endpoint only when code reloading is on, in
        # development: it pushes reload notices to the page and reads
        # nothing a client sends.
        {"/phoenix/live_reload/socket", "Phoenix.LiveReloader.Socket"}
      ],
      entries: [
        "Grimoire",
        "Emissary.MCP.Router",
        "Emissary.Web.MCPController",
        "Emissary.Web.Plugs.MCPRequestMetadata",
        "Emissary.Web.TinctureController",
        "Emissary.Web.TinctureDataController",
        "Emissary.Web.WebhookController",
        "Emissary.Web.ExecutionEventsController",
        "CyfrWeb.Plugs.Authenticate",
        "CyfrWeb.Plugs.ControlPlaneOwnership",
        "CyfrWeb.Plugs.FrameRequest",
        "CyfrWeb.Plugs.MCPOrigin",
        "CyfrWeb.Plugs.MCPRateLimit",
        "CyfrWeb.Plugs.TinctureRateLimit",
        "CyfrWeb.Plugs.VerifyWebhookSignature",
        "CyfrWeb.Plugs.WebhookIdempotency",
        "CyfrWeb.Plugs.WebhookRateLimit"
      ],
      reason:
        "the one endpoint: its pipelines' plugs, controllers and the MCP router refuse " <>
          "before the gate, and every operation and stream they admit, and every one the " <>
          "console's LiveView socket dispatches, enters through the gate's external heads"
    },
    %{
      path: :host_api,
      built: true,
      listener: "Crucible.HostListener",
      sockets: [],
      entries: ["Crucible.Host.Children", "Grimoire"],
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
      entries: ["Crucible.Schedules.Scheduler"],
      reason:
        "a due schedule's fire is the occurrence it claims under a held generation, and " <>
          "the run it admits refused is that fire's failed completion; it listens on nothing"
    },
    %{
      path: :device_channel,
      built: true,
      listener: "CyfrWeb.Endpoint",
      sockets: [{"/device", "Emissary.Web.DeviceChannel"}],
      entries: ["Emissary.Web.DeviceChannel", "Grimoire"],
      reason:
        "a paired glass's socket: it admits nothing until the glass proves its device " <>
          "key, then dispatches each discrete intent through the gate's external head"
    },
    %{
      path: :unix_socket,
      built: false,
      listener: nil,
      sockets: [],
      entries: [],
      reason: "a local socket on a device; not built, so it admits nothing"
    },
    %{
      path: :compositor,
      built: false,
      listener: nil,
      sockets: [],
      entries: [],
      reason:
        "a compositor or physical jack, which appears as a body and never as a namespace; " <>
          "not built, so it admits nothing"
    }
  ]

  @built for %{built: true} = row <- @roster, do: row
  @listeners @built |> Enum.map(& &1.listener) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  @sockets for row <- @built, socket <- row.sockets, do: socket

  @doc "Every row on the roster, built or declared, in its order."
  @spec roster() :: [row()]
  def roster, do: @roster

  @doc "Every path on the roster, built or declared."
  @spec paths() :: [path()]
  def paths, do: Enum.map(@roster, & &1.path)

  @doc "The paths that admit: every built path."
  @spec built() :: [path()]
  def built, do: Enum.map(@built, & &1.path)

  @doc """
  The row of a built path. A path the roster declares and has not built
  is `{:error, :not_built}`; anything else is `{:error, :not_on_roster}`.
  Either way it admits nothing.
  """
  @spec fetch(term()) :: {:ok, row()} | {:error, :not_built | :not_on_roster}
  def fetch(path) do
    case Enum.find(@roster, &(&1.path == path)) do
      %{built: true} = row -> {:ok, row}
      %{built: false} -> {:error, :not_built}
      nil -> {:error, :not_on_roster}
    end
  end

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

  # A module by its name, `Crucible.HostListener`; any other child id as
  # it reads.
  defp name(id), do: inspect(id)
end
