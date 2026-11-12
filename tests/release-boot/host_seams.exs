# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The host's test seams in the running release, evaluated inside it by
# `bin/cyfr rpc` (tests/release-boot/boot.sh): a release is compiled
# without the test permission (`:cyfr, :bootstrap_skip_permitted`), so no
# setting it is given reaches a seam (`Cyfr.seam/2`). The permission, and
# every switch the sandboxed suite turns a timer or a watch off with
# (`config/test.exs`), is set here at runtime, as `sys.config` or
# `ERL_AFLAGS` could set them, and the release must answer as it ships:
#
#   - `Cyfr.seam/2` answers the shipped default and never runs the seam's
#     read;
#   - each switched process, which this release runs, is started again and
#     answers that it already runs: its start never read its switch, which
#     would have answered `:ignore`.
#
# The boot's own reads (the gate, the database checks, the recovery and the
# status watch) are read before anything can be set here: the restores
# case of tests/release-boot/boot.sh boots a release handed the
# database-checks switch, and apps/cyfr/test/cyfr/test_seams_test.exs holds
# every read of a seam's key inside `Cyfr.seam/2`.
#
# Each check raises naming what it found; a release that passes them all
# prints the one line `CYFR_HOST_SEAMS=ok`, and leaves every key as it was.

check = fn
  true, _what -> :ok
  false, what -> raise "a release built without the test permission #{what}"
end

switched = [
  retention_scheduler_enabled: Cyfr.RetentionScheduler,
  external_server_reconciler_enabled: Emissary.External.Reconciler,
  schedule_notes_enabled: Aqua.ScheduleNotes,
  crew_delivery_enabled: Aqua.Crew,
  execution_sweeper_enabled: Opus.Sweeper,
  execution_archive_watch_enabled: Opus.ArchiveWatch,
  worker_watch_enabled: Opus.WorkerWatch,
  cron_scheduler_enabled: Opus.Schedules.Scheduler
]

keys = [:bootstrap_skip_permitted | Keyword.keys(switched)]
saved = for key <- keys, do: {key, Application.fetch_env(:cyfr, key)}

try do
  Application.put_env(:cyfr, :bootstrap_skip_permitted, true)
  for {key, _module} <- switched, do: Application.put_env(:cyfr, key, false)

  check.(
    Cyfr.seam(:shipped, fn -> raise "a release ran a seam's read" end) == :shipped,
    "ran a seam's read"
  )

  for {key, module} <- switched do
    running = Process.whereis(module)
    check.(is_pid(running), "runs no #{inspect(module)}")

    check.(
      module.start_link([]) == {:error, {:already_started, running}},
      "read #{inspect(key)} where #{inspect(module)} starts"
    )
  end
after
  for {key, value} <- saved do
    case value do
      {:ok, value} -> Application.put_env(:cyfr, key, value)
      :error -> Application.delete_env(:cyfr, key)
    end
  end
end

IO.puts("CYFR_HOST_SEAMS=ok")
