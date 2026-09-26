# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.ScrubTinctureCredentials do
  @moduledoc """
  Redacts the asset credential a private tincture's served files carry in
  their path (`/_s/<credential>/…`, `Prima.TinctureUrl`) from
  `conn.request_path`, by shape: the segment after the served-file prefix
  is replaced whatever it holds, so a malformed or refused credential is
  redacted as surely as a live one.

  Routing reads `conn.path_info` and the action its path parameters, so
  both still carry the credential; `conn.request_path` is what a log line,
  a request-log row, a telemetry span or a crash report names the request
  by, and from this plug on it names `/_s/[REDACTED]/…`. The rewrite is
  made at once and again before the response is sent, so a response the
  pipeline answers before the action — the rate limit's 429 — carries it
  too.

  A credential in a path is visible to every intermediary that logs paths;
  this is the server's own part of keeping it out of logs.
  """

  @behaviour Plug

  @redacted "[REDACTED]"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> scrub()
    |> Plug.Conn.register_before_send(&scrub/1)
  end

  @doc "The connection with its request path redacted (`redact_path/1`)."
  @spec scrub(Plug.Conn.t()) :: Plug.Conn.t()
  def scrub(%Plug.Conn{request_path: path} = conn),
    do: %{conn | request_path: redact_path(path)}

  @doc """
  A request path with the segment after the served-file prefix replaced by
  `[REDACTED]`; any other path unchanged.
  """
  @spec redact_path(String.t()) :: String.t()
  def redact_path(path) when is_binary(path) do
    prefix = Prima.TinctureUrl.asset_prefix()

    case String.split(path, "/", parts: 4) do
      ["", ^prefix, _credential | rest] -> Enum.join(["", prefix, @redacted | rest], "/")
      _other -> path
    end
  end
end
