# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.ScrubTinctureCredentials do
  @moduledoc """
  Redacts the asset credential a path carries from `conn.request_path`:
  a private tincture's served files' (`/_s/<credential>/…`,
  `Prima.TinctureUrl`) and a canvas's page's
  (`/_c/v1/<credential>/<frame id>`, `Prima.TinctureWire`). It redacts by
  shape: the segment after the prefix is replaced whatever it holds, so a
  malformed or refused credential is redacted as surely as a live one.

  Routing reads `conn.path_info` and the action its path parameters, so
  both still carry the credential; `conn.request_path` is what a log line,
  a request-log row, a telemetry span or a crash report names the request
  by, and from this plug on it names `/_s/[REDACTED]/…` or
  `/_c/v1/[REDACTED]/…`. The rewrite is made at once and again before the
  response is sent, so a response the pipeline answers before the action
  — the rate limit's 429 — carries it too.

  Segments are counted and read as routing counts and reads them: empty
  ones skipped (`//_s//<credential>/…` routes as `/_s/<credential>/…`
  does), and each percent-decoded before it is compared with a prefix
  (`/%5Fc/%76%31/<credential>/…` routes as `/_c/v1/<credential>/…` does),
  so the segment redacted is the one the route reads as the credential. A
  segment whose escape does not decode is compared as it is written.

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
  A request path with the segment after the served-file prefix or the
  canvas page prefix replaced by `[REDACTED]`; any other path unchanged.
  """
  @spec redact_path(String.t()) :: String.t()
  def redact_path(path) when is_binary(path) do
    segments = String.split(path, "/")

    case credential_at(segments) do
      nil -> path
      index -> segments |> List.replace_at(index, @redacted) |> Enum.join("/")
    end
  end

  # Where among `segments` the credential stands: the first non-empty
  # segment after a prefix's own, when the path's non-empty segments,
  # decoded as the router decodes them, begin with that prefix's.
  defp credential_at(segments) do
    routed =
      for {segment, index} <- Enum.with_index(segments),
          segment != "",
          do: {decoded(segment), index}

    Enum.find_value(prefixes(), fn prefix ->
      case Enum.split(routed, length(prefix)) do
        {head, [{_credential, index} | _rest]} ->
          if Enum.map(head, &elem(&1, 0)) == prefix, do: index

        {_head, []} ->
          nil
      end
    end)
  end

  # A segment as the router matches it (`URI.decode/1`, which the router
  # applies to each segment); one whose escape does not decode is left as
  # it is written.
  defp decoded(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end

  # Each prefix as the segments routing reads, from the module that builds
  # its paths.
  defp prefixes do
    [
      [Prima.TinctureUrl.asset_prefix()],
      String.split(Prima.TinctureWire.page_prefix(), "/", trim: true)
    ]
  end
end
