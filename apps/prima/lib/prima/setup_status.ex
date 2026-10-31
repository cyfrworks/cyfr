# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.SetupStatus do
  @moduledoc """
  The wire of `POST /api/setup/status`, which tells a program on this
  machine whether setup is still open (`Emissary.Web.SetupStatusController`).

  The request is the JSON object `{"version":1}` and nothing else, its
  body at most `max_body_bytes/0`. The answer is `{"version":1,"state":…}`:
  `open` and `closed` at 200, `unavailable` at 503. Wire version 1 stays
  across independent updates of the command line and the application.

  `tests/fixtures/setup_status.json` holds its vectors, which the
  controller's test and the command line's client
  (`apps/codex/internal/setup/status.go`) both read.
  """

  @version 1
  @max_body_bytes 1024
  @segments ["api", "setup", "status"]

  @type state :: :open | :closed | :unavailable

  @doc "The most bytes a request's body may hold."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc """
  Whether `path_info` is the route's path, each segment decoded as the
  router decodes it, so a segment spelled in percent escapes is the same
  path here as there.
  """
  @spec path?([String.t()]) :: boolean()
  def path?([_, _, _] = path_info) do
    Enum.map(path_info, &URI.decode/1) == @segments
  rescue
    ArgumentError -> false
  end

  def path?(_path_info), do: false

  @doc "Whether the decoded `body` is this wire's request."
  @spec request?(term()) :: boolean()
  def request?(%{"version" => @version} = body), do: map_size(body) == 1
  def request?(_body), do: false

  @doc "The HTTP status and JSON body that say `state`."
  @spec answer(state()) :: {pos_integer(), %{version: pos_integer(), state: String.t()}}
  def answer(:unavailable), do: {503, body(:unavailable)}
  def answer(state) when state in [:open, :closed], do: {200, body(state)}

  defp body(state), do: %{version: @version, state: Atom.to_string(state)}
end
