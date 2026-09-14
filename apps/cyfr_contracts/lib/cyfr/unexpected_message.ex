# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.UnexpectedMessage do
  @moduledoc """
  The one log line for a GenServer's unexpected-message catch-all.

  Formats a bounded warning for unexpected GenServer messages. Each server
  must keep its own final `handle_info/2` catch-all.

  ## Level

  Defaults to `:warning`: a supervised server receiving a message it does
  not understand is a wiring fault worth seeing.

  Console LiveViews pass `:debug` instead, and that is a real distinction
  rather than a weaker version of the same thing. A LiveView subscribes to
  tenant-wide PubSub topics and is *expected* to receive broadcasts it has
  no clause for — the ones meant for its siblings. At `:warning` every
  such message would be an alarm about normal operation.

  Bounds inspection of unexpected messages, including large execution
  and thread payloads.
  """

  require Logger

  @levels [:debug, :info, :warning, :error]

  @spec log(module(), term(), :debug | :info | :warning | :error) :: :ok
  def log(module, msg, level \\ :warning) when level in @levels do
    Logger.log(
      level,
      "[#{inspect(module)}] unexpected message: " <>
        inspect(msg, limit: 20, printable_limit: 200)
    )
  end
end
