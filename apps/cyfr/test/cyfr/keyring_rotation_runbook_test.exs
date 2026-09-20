# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.KeyringRotationRunbookTest do
  @moduledoc """
  The rotation runbook as one flow, not two halves.

  The fingerprint and the re-seal are each tested alone — a mismatch refuses,
  and `reencrypt_all/1` moves rows onto the primary — but the order between
  them is the part an operator gets wrong, and nothing composed it. It is not
  "write, rotate, restart": `reencrypt_all/1` seals onto the keyring's
  CURRENT primary, so running it before the primary moves does nothing at all.

  The real sequence, and what this walks: add the new key and point `primary`
  at it while KEEPING the old label among `keys` → the next boot refuses,
  because the recorded fingerprint is the old primary's → accept once by
  name → re-seal every row onto the new primary → drop the old label, and
  the rows are still readable.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Cyfr.KeyringFingerprint
  alias Sanctum.Cipher
  alias Sanctum.Cipher.Rotation

  @old :crypto.hash(:sha256, "runbook-old")
  @new :crypto.hash(:sha256, "runbook-new")

  @athanor "ath_runbook"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    prev = Application.get_env(:sanctum, :crypto_keyring)
    on_exit(fn -> restore(prev) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:sanctum, :crypto_keyring)
  defp restore(kr), do: Application.put_env(:sanctum, :crypto_keyring, kr)
  defp put(kr), do: Application.put_env(:sanctum, :crypto_keyring, kr)

  defp only_old, do: %{primary: "old", keys: %{"old" => @old}}
  defp both, do: %{primary: "new", keys: %{"new" => @new, "old" => @old}}
  defp only_new, do: %{primary: "new", keys: %{"new" => @new}}

  # A sealed row whose AAD the rotation rebuilds from the row's own columns.
  defp seal_webhook!(name, secret) do
    aad = Sanctum.CipherAAD.webhook_secret(@athanor, name)
    {:ok, ciphertext} = Cipher.encrypt(secret, aad)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.Webhook, [
        %{
          id: Ecto.UUID.generate(),
          name: name,
          slug: "wh_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
          target_ref: "catalyst:local.x:1.0.0",
          secret_encrypted: ciphertext,
          signature_header: "x-cyfr-signature",
          input_template: "{}",
          enabled: true,
          profile_id: "prof_test",
          athanor_id: @athanor,
          inserted_at: now,
          updated_at: now
        }
      ])

    aad
  end

  test "the documented order works, and the order an operator guesses does not" do
    # 1. Running under the old key: rows are sealed, the fingerprint recorded.
    put(only_old())
    aad = seal_webhook!("runbook", "s3cret")
    assert {:recorded, old_fp} = KeyringFingerprint.verify(only_old(), nil)

    # The guess: re-seal before moving the primary. `reencrypt_all/1` targets
    # the CURRENT primary, so there is nothing to move and nothing happens.
    assert {:ok, before} = Rotation.reencrypt_all([])
    assert before.webhooks.rotated == 0

    # 2. Point `primary` at the new key, KEEPING the old label so the rows
    #    stay decryptable. The next boot refuses: the recorded fingerprint is
    #    the old primary's.
    put(both())
    new_fp = KeyringFingerprint.compute(both())
    assert {:error, message} = KeyringFingerprint.verify(both(), nil)
    assert message =~ "CYFR_CRYPTO_KEYRING_FINGERPRINT_ACCEPT=#{new_fp}"
    refute new_fp == old_fp

    # 3. Accept once, by name. Accepting RECORDS the new keyring; it does not
    #    make anything readable that was not already.
    assert {:accepted, ^new_fp, ^old_fp} = KeyringFingerprint.verify(both(), new_fp)
    assert :ok = KeyringFingerprint.verify(both(), nil)

    # 4. Now the re-seal has somewhere to move the rows to.
    assert {:ok, summary} = Rotation.reencrypt_all([])
    assert summary.webhooks.rotated >= 1

    # 5. Drop the old label. The rows are still readable, which is the whole
    #    point of having done step 4 before this one.
    put(only_new())
    assert :ok = KeyringFingerprint.verify(only_new(), nil)

    [ciphertext] =
      Arca.Repo.all(
        from(w in "webhooks",
          where: w.athanor_id == ^@athanor and w.name == "runbook",
          select: w.secret_encrypted
        )
      )

    assert {:ok, "s3cret"} = Cipher.decrypt(ciphertext, aad)
  end

  test "dropping the old label without re-sealing first loses the rows" do
    put(only_old())
    aad = seal_webhook!("skipped", "s3cret")
    assert {:recorded, _} = KeyringFingerprint.verify(only_old(), nil)

    # Straight to the new keyring with no re-seal and no old label: the
    # fingerprint accepts, and the rows do not come back. Accepting a keyring
    # records it; it never restores decryptability.
    put(only_new())
    only_new_fp = KeyringFingerprint.compute(only_new())
    assert {:accepted, ^only_new_fp, _old} = KeyringFingerprint.verify(only_new(), only_new_fp)

    [ciphertext] =
      Arca.Repo.all(
        from(w in "webhooks",
          where: w.athanor_id == ^@athanor and w.name == "skipped",
          select: w.secret_encrypted
        )
      )

    assert {:error, _} = Cipher.decrypt(ciphertext, aad)
  end
end
