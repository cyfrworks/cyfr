# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.RegrantNoticeTest do
  @moduledoc """
  The boot check of stored grants on two real members.

  Every member's boot reads the grants that name a storage path the
  grammar no longer admits, and the cell announces each athanor's list on
  its tray once, under the `regrant_notice` claim: the same list found by
  the other member's boot, or by a member's next boot, says nothing, and a
  changed list is announced once more.

  Each member runs the check as its boot runs it
  (`Sanctum.Consent.StoredGrants.run/1` with the boot's defaults: this
  boot's id as the claim's owner, the cell's key, the host's bridge as the
  listener), after the cell has formed, so a tray watcher on either member
  hears whatever either member announces.
  """

  use Cyfr.Cluster.Case, async: false

  alias Cyfr.Cluster.Boot

  defp boot_check(id), do: assert(Cell.call(id, Sanctum.Consent.StoredGrants, :run, [[]]) == :ok)

  defp heard(id), do: Cell.call(id, Boot, :tray_heard, [])

  test "a list is announced once for the cell, whichever member boots, and a changed list once more" do
    athanor = Cell.call(:a, Fixtures, :athanor!, ["regrant"])
    first = Cell.call(:a, Fixtures, :noncanonical_grant!, [athanor.id, "one"])

    on_exit(fn ->
      # The cluster database outlives the run: the grants leave every list
      # a later run's boot check reads.
      Cell.heal!()

      for label <- ["one", "two"],
          do: Cell.call(:a, Fixtures, :noncanonical_grant!, [athanor.id, label, :revoked])
    end)

    for id <- [:a, :b], do: assert(Cell.call(id, Boot, :watch_tray!, [athanor.id]) == :ok)

    # The first member's boot announces the list, once, and both members'
    # watchers hear it.
    boot_check(:a)

    for id <- [:a, :b] do
      Wait.until!(
        fn -> heard(id) == [[first]] end,
        "member #{id} did not hear the list announced"
      )
    end

    # The other member's boot finds the same list and says nothing.
    boot_check(:b)

    # The first member stops and boots again, under a new boot id, and its
    # check finds the same list: nothing is said.
    boot_before = Cell.call(:a, Prima.Boot, :id, [])
    :ok = Cell.stop(:a)
    Cell.start(:a)
    refute Cell.call(:a, Prima.Boot, :id, []) == boot_before
    assert Cell.call(:a, Boot, :watch_tray!, [athanor.id]) == :ok
    boot_check(:a)

    # A changed list is announced once more, by whichever member's boot
    # finds it first, and not again by the other's.
    second = Cell.call(:b, Fixtures, :noncanonical_grant!, [athanor.id, "two"])
    changed = Enum.sort([first, second])
    boot_check(:b)
    boot_check(:a)

    # Each watcher heard every announcement since it subscribed, and
    # nothing else: the changed list is the sentinel that every earlier
    # delivery has arrived.
    Wait.until!(
      fn -> heard(:b) == [[first], changed] end,
      "member b did not hear exactly the first list and the changed one"
    )

    Wait.until!(
      fn -> heard(:a) == [changed] end,
      "the restarted member did not hear exactly the changed list"
    )
  end
end
