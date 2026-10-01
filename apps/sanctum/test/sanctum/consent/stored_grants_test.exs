# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.StoredGrantsTest do
  @moduledoc """
  The boot check of stored grants: every active head whose policy grants a
  storage path spelled other than the storage door reaches it is listed,
  by athanor, read a page at a time, and each athanor is told once, on its
  tray. Nothing is rewritten.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sanctum.Consent.StoredGrants
  alias Sanctum.Test.ConsentFixtures
  alias Prima.Test.AuthorityFixtures, as: Fixtures

  @notify [:cyfr, :sanctum, :notify]

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

    test = self()
    id = {__MODULE__, :quiet}

    :telemetry.attach(id, @notify, fn _event, _m, meta, _ -> send(test, {:notify, meta}) end, nil)
    on_exit(fn -> :telemetry.detach(id) end)

    assert :ok = StoredGrants.run(listener_wait_ms: 0)
    refute_received {:notify, _}
  end

  test "each athanor is told once, on its tray, and every grant is named in the log" do
    refs = seed_world!()
    test = self()
    id = {__MODULE__, :announced}

    :telemetry.attach(
      id,
      @notify,
      fn _event, _measurements, meta, _ -> send(test, {:notify, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    log = capture_log(fn -> assert :ok = StoredGrants.run(listener_wait_ms: 0, page: 2) end)

    assert_received {:notify,
                     %{
                       athanor_id: "ath_test",
                       kind: :regrant_required,
                       payload: %{references: mine}
                     }}

    assert mine == [refs.doubled]

    assert_received {:notify,
                     %{
                       athanor_id: "ath_sg_other",
                       kind: :regrant_required,
                       payload: %{references: theirs}
                     }}

    assert Enum.sort(theirs) == Enum.sort([refs.trailing, refs.dotted])
    refute_received {:notify, _}

    for ref <- [refs.doubled, refs.trailing, refs.dotted], do: assert(log =~ ref)
    refute log =~ refs.canonical

    # Nothing is rewritten: each grant is as it was stored.
    assert {:ok, %{resolved_policy: policy}} =
             Arca.ConsentStorage.head_consent(Prima.Actor.in_athanor("ath_test"), "sg-b")

    assert policy =~ "data//secrets/"
  end
end
