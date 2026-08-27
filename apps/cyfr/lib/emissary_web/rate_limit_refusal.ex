# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.RateLimitRefusal do
  @moduledoc """
  What a throttled request is told, in one place.

  Four plugs meter four different things — sign-in attempts, MCP calls,
  tincture serving, webhook deliveries — and they stay four plugs, because
  what genuinely differs between them is real: the key topology (an IP, an
  IP plus publisher plus tincture, a webhook slug) and where the budget
  comes from (plug options, app config, a per-slug database column).

  The refusal is not one of those differences. It was written out four
  times, byte for byte, down to the sentence — so a change to the wording,
  the header, or the status had four places to land and three of them would
  have been missed.

  The renderer stays a parameter, the way `EmissaryWeb.ErrorRenderer`
  intends: `/mcp` answers in JSON-RPC, everything else in
  `EmissaryWeb.ApiError`'s HTTP shape, and the decision of which belongs to
  the pipeline rather than to this sentence.
  """

  import Plug.Conn

  @doc """
  Halt with 429, a `retry-after` header, and the one refusal sentence.

  `errors` is an `EmissaryWeb.ErrorRenderer` — `EmissaryWeb.ApiError` for an
  ordinary HTTP route, `EmissaryWeb.MCPError` for JSON-RPC.
  """
  @spec halt(Plug.Conn.t(), non_neg_integer(), module()) :: Plug.Conn.t()
  def halt(%Plug.Conn{} = conn, retry_after, errors) do
    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> errors.halt(429, :rate_limited, message(retry_after))
  end

  @doc "The sentence a throttled caller reads."
  @spec message(non_neg_integer()) :: String.t()
  def message(retry_after), do: "Rate limit exceeded. Try again in #{retry_after} seconds."
end
