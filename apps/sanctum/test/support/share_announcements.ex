# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.ShareAnnouncements do
  @moduledoc """
  What a test hears `Sanctum.Shares` announce: every
  `[:cyfr, :sanctum, :share, kind]` event of `Sanctum.Shares.kinds/0`,
  sent to the test process as `{:share_announced, kind, metadata}` until
  the test exits. Other tests announce shares of their own beside it, so
  a case matches on the share ids it made.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Hear every share announcement in the calling test process."
  @spec listen() :: :ok
  def listen do
    test = self()
    handler = "share-announcements-#{System.unique_integer([:positive])}"
    events = for kind <- Sanctum.Shares.kinds(), do: [:cyfr, :sanctum, :share, kind]

    # The handler is the node's, not the test's: its removal is registered
    # before it is attached, so a test killed at its timeout leaves none.
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle/4, test)
  end

  @doc false
  def handle([:cyfr, :sanctum, :share, kind], _measurements, metadata, test),
    do: send(test, {:share_announced, kind, metadata})
end
