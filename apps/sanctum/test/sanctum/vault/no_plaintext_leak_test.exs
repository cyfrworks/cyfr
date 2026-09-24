# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.NoPlaintextLeakTest do
  @moduledoc """
  Plaintext credentials never reach a log line, an error term or anything
  `Arca.VaultStorage` takes or answers.

  The secret is 32 characters of random base64url, which nothing else in a
  log line or a rendered term is: a three-letter needle matched an
  unrelated element id once, and a refutation is worth nothing unless the
  needle could only have come from the credential. Each run draws a fresh
  one, so a value that leaked into a fixture cannot make the test pass.

  What is proved is the credential boundary itself. `Arca.VaultStorage`
  sits below it — Apache-2.0, no keyring, no AAD — so the one thing it
  must never hold is a decrypted value. Every term it answers is swept,
  on the success path and on every refusal, together with everything the
  vault verbs log while they succeed and while they fail. The last
  assertion reads the material back, because a test that refutes a secret
  nothing ever stored proves nothing at all.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sanctum.Context
  alias Sanctum.Vault
  alias Sanctum.VaultReader

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp secret, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp contains?(term, needle) when is_binary(term), do: String.contains?(term, needle)
  defp contains?(term, needle), do: String.contains?(inspect(term, limit: :infinity), needle)

  test "no vault verb puts a credential in a log or an error", %{ctx: ctx} do
    value = secret()
    refresh = secret()
    actor = Context.actor(ctx)

    log =
      capture_log(fn ->
        {:ok, view} =
          Vault.create(ctx, %{
            name: "leaky",
            kind: "api_key",
            fields: %{"token" => value},
            oauth: %{"access_token" => value, "refresh_token" => refresh}
          })

        # Everything the facade answers, on the success path.
        {:ok, stored} = Arca.VaultStorage.get(actor, view.id)
        refute contains?(stored, value)
        refute contains?(stored, refresh)
        refute contains?(view, value)

        {:ok, listed} = Vault.list(ctx)
        refute contains?(listed, value)

        {:ok, rows} = Arca.VaultStorage.list(actor)
        refute contains?(rows, value)

        # And on every refusal, which is where a term gets inspected into
        # a crash report or a 500.
        refusals = [
          Vault.create(ctx, %{name: "leaky", kind: "api_key", fields: %{"token" => value}}),
          Vault.rotate(ctx, %{
            id: view.id,
            fields: %{"token" => value},
            expected_payload_rev: 99
          }),
          Vault.rotate(ctx, %{
            id: view.id,
            fields: %{"other" => value},
            expected_payload_rev: 0
          }),
          Vault.rotate(ctx, %{id: "vlt_missing", fields: %{}, expected_payload_rev: 0}),
          Arca.VaultStorage.rotate_payload(actor, view.id, 99, stored.sealed_payload),
          Arca.VaultStorage.commit_payload(actor, view.id, %{
            expected_rev: 99,
            sealed_payload: stored.sealed_payload,
            status: "active",
            rebind: nil
          }),
          Arca.VaultStorage.move_binding(
            actor,
            view.id,
            "sha256:stale",
            %{oauth_scopes: ~s(["x"])},
            Vault.blocked_profile_status()
          ),
          Arca.VaultStorage.get(%Prima.Actor{athanor_id: "ath_other"}, view.id),
          VaultReader.fetch(ctx, %{entry_id: view.id, binding_digest: "sha256:wrong"}),
          VaultReader.fetch(%{ctx | anonymous: true}, %{
            entry_id: view.id,
            binding_digest: "sha256:wrong"
          }),
          VaultReader.oauth_token(
            ctx,
            %{entry_id: view.id, binding_digest: "sha256:wrong"},
            "google"
          )
        ]

        for refusal <- refusals do
          refute contains?(refusal, value),
                 "a refusal carried the credential: #{inspect(refusal)}"

          refute contains?(refusal, refresh)
        end

        # The material is genuinely there — a test that refutes a secret
        # nothing ever stored proves nothing at all.
        {:ok, digest} = VaultReader.binding_digest(stored)

        assert {:ok, %{"token" => ^value}} =
                 VaultReader.fetch(ctx, %{entry_id: view.id, binding_digest: digest})
      end)

    refute String.contains?(log, value), "the credential reached a log line"
    refute String.contains?(log, refresh), "the refresh token reached a log line"
  end

  test "a payload the facade cannot store is refused without quoting it", %{ctx: ctx} do
    value = secret()
    actor = Context.actor(ctx)

    # A tampered payload: the decode refusal names the shape it rejected
    # and never the material inside it.
    id = Prima.UUID7.generate_id("vlt")
    aad = Sanctum.CipherAAD.vault_entry(ctx.athanor_id, id, "")
    {:ok, sealed} = Sanctum.Cipher.encrypt(~s({"v":2,"fields":{},"extra":"#{value}"}), aad)

    log =
      capture_log(fn ->
        {:ok, entry} =
          Arca.VaultStorage.put(actor, %{
            id: id,
            name: "tampered",
            kind: "api_key",
            sealed_payload: sealed
          })

        {:ok, digest} = VaultReader.binding_digest(entry)
        result = VaultReader.fetch(ctx, %{entry_id: id, binding_digest: digest})

        assert {:error, {:invalid_payload, {:unknown_keys, ["extra"]}}} = result
        refute contains?(result, value)
      end)

    refute String.contains?(log, value)
  end
end
