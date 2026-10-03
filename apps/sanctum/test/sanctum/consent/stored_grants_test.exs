# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.StoredGrantsTest do
  @moduledoc """
  The boot check of stored grants: every active head whose policy grants a
  storage path spelled other than the storage door reaches it is listed,
  by athanor, read a page at a time, and logged on every member's boot.
  Each athanor is told once for the cell, on its tray: under the
  `regrant_notice` claim, and only when the list differs from the one the
  cell last announced. Nothing is rewritten.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arca.JobClaims
  alias Sanctum.Consent.StoredGrants
  alias Sanctum.Test.ConsentFixtures
  alias Prima.Test.AuthorityFixtures, as: Fixtures

  @notify [:cyfr, :sanctum, :notify]
  @kind "regrant_notice"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp grant!(athanor_id, id, policy_or_paths, status \\ :active) do
    ref = "catalyst:local.#{id}"

    policy =
      case policy_or_paths do
        paths when is_list(paths) ->
          Jason.encode!(%{
            "canonical" => "jcs-1",
            "nodes" => %{
              ref => %{
                "limits" => Fixtures.limits_map(),
                "edges" => %{
                  "@ingress" => %{"storage" => %{"paths" => paths, "actions" => ["read"]}}
                }
              }
            }
          })

        raw when is_binary(raw) ->
          raw
      end

    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor_id}

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{id: id, kind: :owner, source_ref: ref, label: "default", status: status},
        %{
          id: "cons-#{id}",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape-#{id}",
          commit_digest: "sha256:commit-#{id}",
          resolved_policy: policy,
          activation: %{ref => "sha256:act-#{id}"},
          vault_refs: []
        }
      )

    ref
  end

  defp seed_world! do
    %{
      canonical: grant!("ath_test", "sg-a", ["data/notes/", "data/report.md", "*"]),
      doubled: grant!("ath_test", "sg-b", ["data/ok/", "data//secrets/"]),
      revoked: grant!("ath_test", "sg-c", ["data/./x/"], :revoked),
      unparsed: grant!("ath_test", "sg-d", "not a policy"),
      trailing: grant!("ath_sg_other", "sg-e", ["data/notes//"]),
      dotted: grant!("ath_sg_other", "sg-f", ["data/../up/"])
    }
  end

  test "lists each active grant that names a non-canonical path, by athanor, page by page" do
    refs = seed_world!()

    # A page of one row walks every head, one read at a time.
    assert {:ok, found} = StoredGrants.scan(1)

    assert found == %{
             "ath_test" => [%{profile_id: "sg-b", source_ref: refs.doubled, revision: 1}],
             "ath_sg_other" => [
               %{profile_id: "sg-e", source_ref: refs.trailing, revision: 1},
               %{profile_id: "sg-f", source_ref: refs.dotted, revision: 1}
             ]
           }

    assert {:ok, ^found} = StoredGrants.scan(200)
  end

  test "nothing stored, nothing listed and nothing announced" do
    _canonical = grant!("ath_test", "sg-only", ["data/notes/"])
    assert {:ok, %{}} = StoredGrants.scan()

    listen!(:quiet)

    assert :ok = StoredGrants.run(listener_wait_ms: 0, owner: "boot_a")
    assert announced() == []

    # An empty list takes no claim and records nothing.
    assert JobClaims.read(@kind, JobClaims.cell_key()) == {:error, :not_found}
  end

  test "each athanor is told once, on its tray, and every grant is named in the log" do
    refs = seed_world!()
    listen!(:announced)

    log =
      capture_log(fn ->
        assert :ok = StoredGrants.run(listener_wait_ms: 0, page: 2, owner: "boot_a")
      end)

    assert [
             %{athanor_id: "ath_sg_other", payload: %{references: theirs}},
             %{athanor_id: "ath_test", payload: %{references: mine}}
           ] = Enum.sort_by(announced(), & &1.athanor_id)

    assert mine == [refs.doubled]
    assert Enum.sort(theirs) == Enum.sort([refs.trailing, refs.dotted])

    for ref <- [refs.doubled, refs.trailing, refs.dotted], do: assert(log =~ ref)
    refute log =~ refs.canonical

    # Nothing is rewritten: each grant is as it was stored.
    assert {:ok, %{resolved_policy: policy}} =
             Arca.ConsentStorage.head_consent(Prima.Actor.in_athanor("ath_test"), "sg-b")

    assert policy =~ "data//secrets/"

    # The cell's claim records the list it announced, and is given up.
    assert {:ok, found} = StoredGrants.scan()
    assert {:ok, claim} = JobClaims.read(@kind, JobClaims.cell_key())
    assert claim.detail == StoredGrants.digest(found)
    refute JobClaims.live?(claim)
  end

  test "a list's digest is the same whatever order it was read in" do
    a = %{profile_id: "p-a", source_ref: "catalyst:local.a", revision: 1}
    b = %{profile_id: "p-b", source_ref: "catalyst:local.b", revision: 2}

    assert StoredGrants.digest(%{"ath_1" => [a, b], "ath_2" => [b]}) ==
             StoredGrants.digest(%{"ath_2" => [b], "ath_1" => [b, a]})

    refute StoredGrants.digest(%{"ath_1" => [a]}) ==
             StoredGrants.digest(%{"ath_1" => [%{a | revision: 2}]})
  end

  describe "once for the cell" do
    test "the same list is announced once, whichever member boots, and every member logs it" do
      refs = seed_world!()
      listen!(:once)

      assert :ok = StoredGrants.run(listener_wait_ms: 0, owner: "boot_a")

      assert announced() |> Enum.map(& &1.athanor_id) |> Enum.sort() == [
               "ath_sg_other",
               "ath_test"
             ]

      # Another member's boot, or the cell's restart, finds the same list.
      log =
        capture_log(fn ->
          assert :ok = StoredGrants.run(listener_wait_ms: 0, owner: "boot_b")
        end)

      assert announced() == []
      assert log =~ refs.doubled
    end

    test "a live peer holding the claim makes the announcement; this member only logs" do
      refs = seed_world!()
      listen!(:peer)

      key = JobClaims.cell_key()
      assert {:ok, _peer} = JobClaims.claim(@kind, key, "boot_b", 60_000)

      log =
        capture_log(fn ->
          assert :ok = StoredGrants.run(listener_wait_ms: 0, owner: "boot_a")
        end)

      assert announced() == []
      assert log =~ refs.doubled
      assert {:ok, %{owner: "boot_b", detail: nil}} = JobClaims.read(@kind, key)
    end

    test "a changed list is announced again, once" do
      refs = seed_world!()
      listen!(:changed)

      assert :ok = StoredGrants.run(listener_wait_ms: 0, owner: "boot_a")
      assert length(announced()) == 2

      later = grant!("ath_test", "sg-g", ["data/x//"])

      assert :ok = StoredGrants.run(listener_wait_ms: 0, owner: "boot_b")
      again = announced()

      assert %{payload: %{references: mine}} = Enum.find(again, &(&1.athanor_id == "ath_test"))
      assert Enum.sort(mine) == Enum.sort([refs.doubled, later])
      assert Enum.any?(again, &(&1.athanor_id == "ath_sg_other"))

      assert :ok = StoredGrants.run(listener_wait_ms: 0, owner: "boot_c")
      assert announced() == []
    end

    test "with nothing listening nothing is announced or recorded, and a later boot announces" do
      _refs = seed_world!()
      unhook_listeners!()

      log =
        capture_log(fn ->
          assert :ok = StoredGrants.run(listener_wait_ms: 0, owner: "boot_a")
        end)

      assert log =~ "nothing listens to the tray yet"

      assert {:ok, %{detail: nil} = claim} = JobClaims.read(@kind, JobClaims.cell_key())
      refute JobClaims.live?(claim)

      listen!(:later)
      assert :ok = StoredGrants.run(listener_wait_ms: 0, owner: "boot_b")
      assert length(announced()) == 2
    end
  end

  # A tray listener for this test: each announcement arrives as a message.
  defp listen!(name) do
    test = self()
    id = {__MODULE__, name}

    :telemetry.attach(
      id,
      @notify,
      fn _event, _measurements, meta, _ -> send(test, {:notify, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # The announcements received so far, each once.
  defp announced(acc \\ []) do
    receive do
      {:notify, meta} -> announced([meta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Whatever else listens to the tray's event (the host's bridge, when the
  # host runs in this VM) is detached for the test and attached again after.
  defp unhook_listeners! do
    handlers = Enum.filter(:telemetry.list_handlers(@notify), &(&1.event_name == @notify))
    Enum.each(handlers, &:telemetry.detach(&1.id))

    on_exit(fn ->
      for h <- handlers, do: :telemetry.attach(h.id, h.event_name, h.function, h.config)
    end)
  end
end
