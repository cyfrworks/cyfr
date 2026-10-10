# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ReleaseTest do
  # The release task sees the same migrations the boot path runs; on a
  # current schema there is nothing pending.
  use ExUnit.Case, async: false

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  test "the test database is current — nothing pending" do
    assert Cyfr.Release.pending() == []
  end

  test "migrate/0 on a current schema is a no-op that returns :ok" do
    assert :ok = Cyfr.Release.migrate()
  end

  # A task runs in `bin/cyfr eval`, where no application start installs the
  # filter: the task installs it, ahead of Logger's translator.
  test "a release task installs the log filter" do
    _ = :logger.remove_primary_filter(:prima_log_filter)
    on_exit(fn -> :ok = Prima.LogFilter.install() end)

    assert Cyfr.Release.pending() == []

    filters = Enum.map(:logger.get_primary_config().filters, &elem(&1, 0))
    assert :prima_log_filter in filters

    assert Enum.find_index(filters, &(&1 == :prima_log_filter)) <
             Enum.find_index(filters, &(&1 == :logger_translator))
  end
end
