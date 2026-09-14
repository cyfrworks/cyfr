# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SchemaFingerprintTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.SchemaFingerprint
  alias Arca.Schemas.ServerMeta

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    :ok
  end

  test "the baseline records the fingerprint of the migrations this release carries" do
    assert {:ok, SchemaFingerprint.current()} ==
             Arca.ServerMetaStorage.get(SchemaFingerprint.key())

    assert :ok = SchemaFingerprint.verify()
  end

  test "a database built from a different schema is refused, naming the recreate" do
    {1, _} = Arca.Repo.update_all(fingerprint_row(), set: [value: "an-older-schema"])

    assert {:error, message} = SchemaFingerprint.verify()
    assert message =~ "was built from a different schema (an-older-schema)"
    assert message =~ "There is no upgrade path"
    assert_raise RuntimeError, ~r/different schema/, fn -> SchemaFingerprint.verify!() end
  end

  test "the boot step refuses a database built from a different schema" do
    assert :ignore = SchemaFingerprint.Check.init([])

    {1, _} = Arca.Repo.update_all(fingerprint_row(), set: [value: "an-older-schema"])
    assert_raise RuntimeError, ~r/different schema/, fn -> SchemaFingerprint.Check.init([]) end
  end

  test "a database that records no fingerprint is refused" do
    {1, _} = Arca.Repo.delete_all(fingerprint_row())

    assert {:error, message} = SchemaFingerprint.verify()
    assert message =~ "records no schema fingerprint"
  end

  defp fingerprint_row, do: from(m in ServerMeta, where: m.key == ^SchemaFingerprint.key())
end
