# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ControlPlane.ClaimTest do
  use ExUnit.Case, async: false

  alias Cyfr.ControlPlane.Claim

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  test "one boot holds the lease; a second is refused until it lapses" do
    assert {:ok, until, 1} = Claim.claim("boot-a", 60_000)
    assert {:ok, "boot-a", ^until} = Claim.holder()

    assert {:error, {:held, "boot-a", ^until}} = Claim.claim("boot-b", 60_000)
    assert :lost = Claim.renew("boot-b", 60_000)
    assert {:ok, _} = Claim.renew("boot-a", 60_000)

    # The holder re-claims its own row freely (a restart of the same boot id).
    assert {:ok, _, 2} = Claim.claim("boot-a", 60_000)
  end

  test "an expired lease is anybody's, and the old holder then renews nothing" do
    assert {:ok, _, 1} = Claim.claim("boot-a", 1)
    Process.sleep(5)

    assert {:ok, _, 2} = Claim.claim("boot-b", 60_000)
    assert {:ok, "boot-b", _} = Claim.holder()
    assert :lost = Claim.renew("boot-a", 60_000)
  end

  test "a row that does not decode refuses the claim and is left as it is" do
    assert {:ok, :recorded} = Arca.ServerMetaStorage.put_new("control_plane_owner", "garbage")

    assert {:error, :unavailable} = Claim.claim("boot-a", 60_000)
    assert {:error, :unavailable} = Claim.holder()
    assert :lost = Claim.renew("boot-a", 60_000)
    assert {:ok, "garbage"} = Arca.ServerMetaStorage.get("control_plane_owner")
  end

  @tag :capture_log
  test "a store that cannot answer refuses the claim, never a claim at generation 1" do
    assert {:ok, _, 1} = Claim.claim("boot-a", 60_000)
    assert :ok = Claim.release("boot-a")

    Arca.Repo.query!("DROP TABLE server_meta")

    assert {:error, :unavailable} = Claim.claim("boot-b", 60_000)
    assert {:error, :unavailable} = Claim.holder()
    assert :lost = Claim.renew("boot-a", 60_000)
    assert {:error, :database_error} = Claim.release("boot-a")
  end

  test "every claim raises the generation; renewal and release keep it" do
    assert {:ok, _, 1} = Claim.claim("boot-a", 60_000)
    assert {:ok, _} = Claim.renew("boot-a", 60_000)
    assert :ok = Claim.release("boot-a")
    assert {:ok, _, 2} = Claim.claim("boot-b", 60_000)
    assert {:error, {:held, "boot-b", _}} = Claim.claim("boot-a", 60_000)
    assert {:ok, _} = Claim.renew("boot-b", 60_000)
    assert :ok = Claim.release("boot-b")
    assert {:ok, _, 3} = Claim.claim("boot-a", 60_000)
  end

  test "the store's conditional writes are conditional" do
    assert {:ok, :recorded} = Arca.ServerMetaStorage.put_new("k", "v1")
    assert {:error, :exists} = Arca.ServerMetaStorage.put_new("k", "v2")
    assert {:error, :stale} = Arca.ServerMetaStorage.compare_and_put("k", "v0", "v2")
    assert :ok = Arca.ServerMetaStorage.compare_and_put("k", "v1", "v2")
    assert {:ok, "v2"} = Arca.ServerMetaStorage.get("k")
    assert {:error, :not_found} = Arca.ServerMetaStorage.get("missing")
  end
end
