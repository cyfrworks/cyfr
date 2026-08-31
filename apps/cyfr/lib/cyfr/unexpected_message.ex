# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.UnexpectedMessage do
  @moduledoc """
  The one log line for a GenServer's unexpected-message catch-all.

  The identical warning line was once spelled verbatim in every GenServer
  across cyfr and opus (in two prefix styles besides). The
  clause itself stays per-server — a catch-all must be that server's LAST
  `handle_info/2` — but the sentence, its prefix shape and its inspect
  bounds are owned here, so a mailbox flooded with large terms cannot
  balloon a log line and the spelling cannot fork again.

  ## Level

  Defaults to `:warning`: a supervised server receiving a message it does
  not understand is a wiring fault worth seeing.

  Console LiveViews pass `:debug` instead, and that is a real distinction
  rather than a weaker version of the same thing. A LiveView subscribes to
  tenant-wide PubSub topics and is *expected* to receive broadcasts it has
  no clause for — the ones meant for its siblings. At `:warning` every
  such message would be an alarm about normal operation.

  What the twenty-odd LiveViews did not get by rolling their own line was
  the inspect bounds, and they are the processes that most needed them:
  execution-event and conversation payloads are exactly the large terms an
  unbounded `inspect/1` turns into an unbounded log line.
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
