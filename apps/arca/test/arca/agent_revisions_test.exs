# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AgentRevisionsTest do
  @moduledoc """
  An agent revision is kept once by the digest of its bytes, read back
  verified, and never shared across athanors.
  """

  use ExUnit.Case, async: false

  alias Arca.AgentRevisions

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    :ok
  end

  test "a revision is kept by digest, once, and read back verified" do
    bytes = "---\ntitle: Scout\n---\n\nYou scout.\n"
    digest = Prima.Digest.sha256(bytes)

    assert {:ok, ^digest} = AgentRevisions.put(Prima.Actor.in_athanor("ath_a"), bytes)
    assert {:ok, ^digest} = AgentRevisions.put(Prima.Actor.in_athanor("ath_a"), bytes)
    assert {:ok, ^bytes} = AgentRevisions.get(Prima.Actor.in_athanor("ath_a"), digest)

    # Another athanor never sees it.
    assert {:error, :not_found} = AgentRevisions.get(Prima.Actor.in_athanor("ath_b"), digest)
    assert {:error, :not_found} = AgentRevisions.get(Prima.Actor.in_athanor("ath_a"), "sha256:0")
  end

  test "bytes that no longer hash to their digest are refused" do
    digest = Prima.Digest.sha256("as written")
    {:ok, ^digest} = AgentRevisions.put(Prima.Actor.in_athanor("ath_c"), "as written")

    import Ecto.Query, only: [from: 2]

    {1, _} =
      Arca.Repo.update_all(
        from(r in Arca.Schemas.AgentRevision,
          where: r.athanor_id == "ath_c" and r.digest == ^digest
        ),
        set: [bytes: "altered"]
      )

    assert {:error, :corrupt} = AgentRevisions.get(Prima.Actor.in_athanor("ath_c"), digest)
  end
end
