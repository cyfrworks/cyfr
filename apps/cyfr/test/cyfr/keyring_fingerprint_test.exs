# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.KeyringFingerprintTest do
  use ExUnit.Case, async: false

  alias Cyfr.KeyringFingerprint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp keyring(label, seed),
    do: %{primary: label, keys: %{label => :crypto.hash(:sha256, seed)}}

  test "first boot records; the same primary passes; a different one refuses" do
    a = keyring("default", "a")
    b = keyring("default", "b")
    fp_a = KeyringFingerprint.compute(a)
    fp_b = KeyringFingerprint.compute(b)

    assert {:recorded, ^fp_a} = KeyringFingerprint.verify(a, nil)
    assert :ok = KeyringFingerprint.verify(a, nil)

    # Same label, different material — the fork the fingerprint exists for.
    assert {:error, message} = KeyringFingerprint.verify(b, nil)
    assert message =~ "FATAL"
    assert message =~ fp_a
    assert message =~ fp_b
    assert message =~ "CYFR_CRYPTO_KEYRING_FINGERPRINT_ACCEPT=#{fp_b}"
    refute message =~ Base.encode64(:crypto.hash(:sha256, "b"))
  end

  test "a decrypt-only secondary is a rotation in progress, not a fork" do
    a = keyring("k1", "a")
    with_secondary = %{primary: "k1", keys: Map.put(a.keys, "k0", :crypto.hash(:sha256, "old"))}

    assert {:recorded, _} = KeyringFingerprint.verify(a, nil)
    assert :ok = KeyringFingerprint.verify(with_secondary, nil)
  end

  test "accepting names exactly the new fingerprint, once" do
    a = keyring("default", "a")
    b = keyring("default", "b")
    fp_a = KeyringFingerprint.compute(a)
    fp_b = KeyringFingerprint.compute(b)

    assert {:recorded, ^fp_a} = KeyringFingerprint.verify(a, nil)

    assert {:error, message} = KeyringFingerprint.verify(b, "not-a-fingerprint")
    assert message =~ "names neither"

    assert {:accepted, ^fp_b, ^fp_a} = KeyringFingerprint.verify(b, fp_b)
    assert :ok = KeyringFingerprint.verify(b, nil)
    assert {:error, _} = KeyringFingerprint.verify(a, nil)
  end
end
