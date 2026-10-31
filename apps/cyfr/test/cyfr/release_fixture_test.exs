# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ReleaseFixtureTest do
  @moduledoc """
  The release proofs' fixture (`tests/release-boot/fixture.exs`), evaluated
  as `bin/cyfr rpc` evaluates it inside a release: its `person` command
  makes the installation's first person by the setup admission, their
  enrollment finished with no network and their name recorded, and every
  later one with the rows an open admission writes, held to the open
  admission's caps.
  """

  # The setup token the fixture puts for its call, the pinned directory,
  # the door and the caps are process-wide.
  use ExUnit.Case, async: false

  alias Arca.Schemas.{IdentityAttempt, PersonIdentity, User}
  alias Sanctum.Auth.Identity

  @fixture Path.expand("../../../../tests/release-boot/fixture.exs", __DIR__)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Sanctum.Test.Newcomers.directory!()

    # The installation holds no person inside this test's transaction,
    # whatever the suite committed: the fixture's first person is setup's.
    Arca.Repo.delete_all(User)

    {fixture, _bindings} = Code.eval_file(@fixture)
    %{fixture: fixture}
  end

  defp person!(fixture, email, sub) do
    "FIXTURE=" <> json = fixture.(["person", email, sub])
    Jason.decode!(json)
  end

  test "person makes the first person by setup, and a later one with an open admission's rows",
       %{fixture: fixture} do
    first = person!(fixture, "first@example.com", "fixture-first")
    assert Sanctum.Tenancy.platform_admin?(first["user_id"])

    # Finished: registered as the directory's acceptance records it, the
    # code saved and the name recorded, with nothing sent.
    assert %IdentityAttempt{phase: "completed", kit_seed_sealed: nil, name: "release-proof"} =
             attempt = Arca.Repo.get_by!(IdentityAttempt, user_id: first["user_id"])

    assert %PersonIdentity{enrollment: "enrolled", identifier: identifier} =
             Arca.Repo.get_by!(PersonIdentity, user_id: first["user_id"])

    assert identifier == attempt.identifier
    assert {:ok, %{namespace: "release-proof"}} = Sanctum.Tenancy.Users.get(first["user_id"])

    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
    second = person!(fixture, "second@example.com", "fixture-second")

    refute second["user_id"] == first["user_id"]
    assert {:ok, %{admission: "open"}} = Sanctum.Tenancy.Users.get(second["user_id"])
    refute Sanctum.Tenancy.platform_admin?(second["user_id"])

    assert {:ok, %{kind: "person", owner_user_id: owner}} =
             Sanctum.Tenancy.Athanors.get(second["athanor_id"])

    assert owner == second["user_id"]

    # Signed in again, the identity names the person made first.
    assert person!(fixture, "second@example.com", "fixture-second")["user_id"] ==
             second["user_id"]
  end

  test "a later person is held to the open admission's cap, and none is made past it",
       %{fixture: fixture} do
    _first = person!(fixture, "first@example.com", "fixture-first")
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
    Cyfr.Test.Settings.put("max_athanors", 1)

    assert_raise MatchError, ~r/limit_reached/, fn ->
      fixture.(["person", "capped@example.com", "fixture-capped"])
    end

    assert {:error, :not_found} =
             Sanctum.Tenancy.Users.get_by_identity(
               Identity.builtin_key(:github, "fixture-capped")
             )

    assert Arca.Repo.aggregate(User, :count) == 1
  end
end
