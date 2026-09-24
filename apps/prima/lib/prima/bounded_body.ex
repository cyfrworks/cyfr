# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.BoundedBody do
  @moduledoc """
  A response body bounded while it streams in.

  `collector/1` is a Req `into:` function that aborts the transfer once the
  accumulated body exceeds its ceiling, so a hostile or misconfigured server
  cannot make the host buffer an arbitrarily large binary before a post-hoc
  size check runs. `read/2` answers what it collected. The pinned transport
  (`Sanctum.Egress.pinned_request/5`), the guest HTTP handler and the builder
  client bound their responses through it.

  The collector's state lives in the response's `private` map, so it works
  on any response map carrying one — `Req.Response` among them.
  """

  @typedoc "The response an `into:` function is handed: a map carrying a `private` map."
  @type response :: %{:private => map(), optional(atom()) => term()}

  @doc """
  A Req `into:` collector that aborts the transfer once the accumulated
  body exceeds `max_bytes`.

  Read the result with `read/2`; the response's `body` stays empty.
  """
  @spec collector(pos_integer()) ::
          ({:data, binary()}, {term(), response()} -> {:cont | :halt, {term(), response()}})
  def collector(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    fn {:data, data}, {req, resp} ->
      chunks = [data | resp.private[:bounded_body_chunks] || []]
      size = (resp.private[:bounded_body_size] || 0) + byte_size(data)

      resp =
        resp
        |> put_private(:bounded_body_chunks, chunks)
        |> put_private(:bounded_body_size, size)

      if size > max_bytes do
        {:halt, {req, put_private(resp, :bounded_body_truncated, true)}}
      else
        {:cont, {req, resp}}
      end
    end
  end

  @doc """
  The body a `collector/1` accumulated: `{:ok, binary}` for a complete
  transfer, `{:error, {:response_too_large, size, max_bytes}}` for one
  aborted at the ceiling (`size` is the bytes seen at the abort).
  """
  @spec read(response(), pos_integer()) ::
          {:ok, binary()} | {:error, {:response_too_large, non_neg_integer(), pos_integer()}}
  def read(%{private: private}, max_bytes) when is_map(private) do
    if private[:bounded_body_truncated] do
      {:error, {:response_too_large, private[:bounded_body_size] || 0, max_bytes}}
    else
      {:ok, (private[:bounded_body_chunks] || []) |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp put_private(%{private: private} = resp, key, value),
    do: %{resp | private: Map.put(private, key, value)}
end
