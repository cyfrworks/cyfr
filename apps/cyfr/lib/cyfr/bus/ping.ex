# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Ping do
  @moduledoc """
  A health probe's round trip to itself, on `Cyfr.Bus.health_check/1`:
  the prober subscribes and publishes to prove PubSub is alive. No tenant
  data crosses it.
  """

  alias Cyfr.Bus.Payload

  @kinds [:ping]

  @enforce_keys [:kind]
  defstruct [:kind, :nonce]

  @type kind :: :ping
  @type t :: %__MODULE__{kind: kind(), nonce: term()}

  @doc "The closed union: a ping."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The ping for the probe named by `nonce`."
  @spec new(term()) :: t()
  def new(nonce), do: %__MODULE__{kind: Payload.kind!(__MODULE__, :ping, @kinds), nonce: nonce}
end
