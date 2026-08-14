# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.VaultOAuthRefreshTest do
  use ExUnit.Case, async: false

  alias Sanctum.CipherAAD
  alias Sanctum.OAuth.RefreshLock
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  @expired %{
    "access_token" => "tok-expired",
    "refresh_token" => "rt-1",
    "expires_at" => "2020-01-01T00:00:00Z",
    "token_type" => "bearer"
  }

  defp mint_oauth_entry(ctx, oauth, over \\ %{}) do
    id = Emissary.UUID7.generate_id("vlt")
    aad = CipherAAD.vault_entry(ctx.org_id, ctx.project_id, id, "google")

    {:ok, json} = Payload.encode_material(%{}, oauth)
    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

    {:ok, entry} =
      Arca.VaultStorage.put(%{
        id: id,
        org_id: ctx.org_id,
        project_id: ctx.project_id,
        name: "oauth-#{id}",
        provider_hint: "google",
        kind: "oauth",
        oauth_endpoints: Map.get(over, :endpoints, ~s({"token_url":"https://127.0.0.1:1/tok"})),
        sealed_payload: sealed
      })

    {:ok, digest} = VaultReader.binding_digest(entry)
    {entry, %{entry_id: entry.id, binding_digest: digest}}
  end

  defp reseal_valid(ctx, entry, token) do
    aad = CipherAAD.vault_entry(ctx.org_id, ctx.project_id, entry.id, "google")

    {:ok, json} =
      Payload.encode_material(%{}, %{"access_token" => token, "token_type" => "bearer"})

    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)
    {:ok, fresh} = Arca.VaultStorage.get(ctx.org_id, ctx.project_id, entry.id)
    :ok = Arca.VaultStorage.rotate_payload(ctx.org_id, ctx.project_id, entry.id, fresh.payload_rev, sealed)
  end

  defp attach_attempt_counter do
    counter = :counters.new(1, [:atomics])
    handler_id = "vault-oauth-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:cyfr, :vault, :oauth_refresh],
      fn _event, _measure, %{status: status}, _cfg ->
        if status == :attempt, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    counter
  end

  describe "entry-keyed single flight" do
    test "an expired caller joins an in-flight refresh on the entry key and returns its result",
         %{ctx: ctx} do
      {entry, resource} = mint_oauth_entry(ctx, @expired)
      counter = attach_attempt_counter()
      lock_key = {:vault_oauth_refresh, ctx.org_id, entry.id}

      # A "leader" already refreshing this entry: holds the entry lock,
      # writes the refreshed bundle back, returns its token.
      leader =
        Task.async(fn ->
          RefreshLock.run(
            lock_key,
            fn ->
              Process.sleep(200)
              reseal_valid(ctx, entry, "tok-refreshed")
              {:ok, "tok-refreshed"}
            end,
            fn -> :stale end
          )
        end)

      # Let the leader win the Registry race deterministically.
      Process.sleep(50)

      # The reader sees the expired bundle, follows on the same key, and
      # rechecks the row the leader wrote — no provider POST happens.
      assert {:ok, "tok-refreshed"} = VaultReader.oauth_token(ctx, resource, "google")
      assert {:ok, "tok-refreshed"} = Task.await(leader, 5_000)
      assert :counters.get(counter, 1) == 0
    end

    test "the leader re-reads inside the lock — a refresh that already landed is returned, not repeated",
         %{ctx: ctx} do
      {entry, _resource} = mint_oauth_entry(ctx, @expired)
      counter = attach_attempt_counter()

      # The row was refreshed after our caller unsealed its stale copy.
      reseal_valid(ctx, entry, "tok-already-fresh")

      assert {:ok, "tok-already-fresh"} =
               Sanctum.Vault.OAuth.dispense(entry, @expired, "google")

      assert :counters.get(counter, 1) == 0
    end
  end

  describe "refresh preconditions (fail closed, no provider contact)" do
    test "no refresh_token is an authorization_required error", %{ctx: ctx} do
      no_rt = %{"access_token" => "t", "expires_at" => "2020-01-01T00:00:00Z"}
      {_entry, resource} = mint_oauth_entry(ctx, no_rt)
      counter = attach_attempt_counter()

      assert {:error, "authorization_required:" <> _} =
               VaultReader.oauth_token(ctx, resource, "google")

      assert :counters.get(counter, 1) == 0
    end

    test "a plaintext token_url is refused", %{ctx: ctx} do
      {_entry, resource} =
        mint_oauth_entry(ctx, @expired, %{endpoints: ~s({"token_url":"http://127.0.0.1:1/t"})})

      assert {:error, "token_url must use https://"} =
               VaultReader.oauth_token(ctx, resource, "google")
    end

    test "an unreachable provider surfaces as a refresh failure after one attempt",
         %{ctx: ctx} do
      {_entry, resource} = mint_oauth_entry(ctx, @expired)
      counter = attach_attempt_counter()

      :ok = Sanctum.ProviderCredentials.put(ctx, "google", "cid", "csec")

      assert {:error, "authorization_required: refresh failed" <> _} =
               VaultReader.oauth_token(ctx, resource, "google")

      assert :counters.get(counter, 1) >= 1
    end
  end

  describe "Arca.VaultStorage.rotate_payload/4 (the CAS)" do
    test "the loser of a revision race gets payload_conflict", %{ctx: ctx} do
      {entry, _resource} = mint_oauth_entry(ctx, @expired)

      assert :ok = Arca.VaultStorage.rotate_payload(ctx.org_id, ctx.project_id, entry.id, 0, "sealed-a")

      assert {:error, :payload_conflict} =
               Arca.VaultStorage.rotate_payload(ctx.org_id, ctx.project_id, entry.id, 0, "sealed-b")

      {:ok, row} = Arca.VaultStorage.get(ctx.org_id, ctx.project_id, entry.id)
      assert row.payload_rev == 1
      assert row.sealed_payload == "sealed-a"
    end
  end
end
