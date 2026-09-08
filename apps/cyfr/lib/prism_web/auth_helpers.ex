# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AuthHelpers do
  @moduledoc """
  The web adapter over `Sanctum.Caller` for LiveView hooks and
  controller plugs: establish the caller, tag the logger, and hand the
  named refusals to whoever must map them to a redirect or a status.
  """

  alias Sanctum.{Caller, Context}

  @doc """
  Establish the caller behind a session token. With an `athanor_id`, the
  context is focused on that athanor (`Sanctum.Context.focus/2`) — how a
  nested LiveView rendered by the layout (topbar, AQUA overlay) follows
  the page's focus, since it mounts with the session and no URL.

  Returns `{:ok, ctx}` or `{:error, Sanctum.Caller.refusal()}`.
  """
  @spec authenticate_session(String.t() | nil, String.t() | nil) ::
          {:ok, Context.t()} | {:error, Caller.refusal()}
  def authenticate_session(token, athanor_id \\ nil) do
    case Caller.establish(token, focus: athanor_id, task_supervisor: Aqua.TaskSupervisor) do
      {:ok, ctx} ->
        Cyfr.LoggerContext.set_from_context(ctx)
        {:ok, ctx}

      {:error, _} = refusal ->
        refusal
    end
  end

  @doc """
  The canonical disposition for a session refusal — one decision table
  for every surface. How a surface renders it stays local: a LiveView
  gate redirects, a binary endpoint answers a status, and the topbar —
  a nested layout LiveView that renders on every page and cannot
  meaningfully redirect — degrades to its signed-out shape.

    * `:sign_in` — no session, or one denied or revoked since it was
      minted: back through the door.
    * `:no_workspace` — signed in, but nowhere to work.
    * `:unavailable` — a transient failure reading who the person is:
      say so; never bounce them into a claim or sign-in they did not
      earn.
  """
  @spec disposition(Caller.refusal()) :: :sign_in | :no_workspace | :unavailable
  def disposition({:denied, _ctx}), do: :sign_in
  def disposition(:unavailable), do: :unavailable

  def disposition(reason) when reason in [:no_athanor, :not_member, :archived, :not_found],
    do: :no_workspace

  def disposition(_), do: :sign_in

  @doc """
  The client address behind a LiveView socket, for the anonymous flows
  that must budget by IP themselves.

  The `/live` socket is handled by `EmissaryWeb.Endpoint` before the
  router, so it passes no rate-limit plug: a LiveView that starts a device
  flow (sign-in, the registry appeal) is the only thing standing between
  one address and the server-wide budget. `connect_info` is readable only
  during `mount/3`, and only on the connected mount — the static render
  answers `"0.0.0.0"`, which no flow can reach, since starting one takes a
  click on a live socket.

  One spelling for both call sites: the hop rules live in
  `Sanctum.ClientIp` and the assembly of the two `connect_info` keys they
  need lives here, rather than once per LiveView.
  """
  @spec socket_client_ip(Phoenix.LiveView.Socket.t()) :: String.t()
  def socket_client_ip(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Sanctum.ClientIp.from_connect_info(%{
        peer_data: Phoenix.LiveView.get_connect_info(socket, :peer_data),
        x_headers: Phoenix.LiveView.get_connect_info(socket, :x_headers)
      })
    else
      "0.0.0.0"
    end
  end

  @doc "The one spelling of the sign-in path."
  def sign_in_path, do: "/login"
end
