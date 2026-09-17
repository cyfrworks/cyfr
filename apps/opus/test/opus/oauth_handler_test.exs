# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.OAuthHandlerTest do
  @moduledoc """
  The `cyfr:oauth/token` host boundary.

  A guest's token request is an `oauth_token` host call of its execution's
  attached attempt: a dispensed token crosses as the token, and every
  refusal — the edge's vault state as it stands when the token is asked
  for, a tampered payload, an attempt that is no longer open — crosses the
  WIT result<string, string> boundary as a bounded string that names the
  shape of the failure, never the material involved.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Cyfr.Test.AttemptFixtures

  @token "tok-live"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # The import of a guest whose attempt is attached with `opts`
  # (`Cyfr.Test.AttemptFixtures.attached!/1`), and that attempt.
  defp token_fn(opts) do
    attempt = AttemptFixtures.attached!(opts)
    {fun_of(Opus.HostClient.new(attempt.keys, attempt.runner, attempt.boot)), attempt}
  end

  defp fun_of(host) do
    imports = Opus.OAuthHandler.build_oauth_imports(host)
    {:fn, fun} = imports["cyfr:oauth/token@0.1.0"]["get-access-token"]
    fun
  end

  defp oauth(attrs \\ %{}),
    do: Map.merge(%{kind: "oauth", oauth: %{"access_token" => @token}}, attrs)

  defp set_entry!(entry, fields) do
    {1, _} =
      Arca.Repo.update_all(from(e in Arca.Schemas.VaultEntry, where: e.id == ^entry.id),
        set: fields
      )

    :ok
  end

  test "a dispensed token crosses as the token" do
    {fun, _attempt} = token_fn(vault: oauth())
    assert {:ok, @token} = fun.("google")
  end

  test "every refusal crosses as a string", %{ctx: ctx} do
    {no_edge, _} = token_fn([])
    assert {:error, "no vault resource granted on this edge"} = no_edge.("github")

    {google, _} = token_fn(vault: oauth(%{provider_hint: "google"}))
    assert {:error, "this credential is not for github"} = google.("github")

    {api_key, _} = token_fn(vault: %{kind: "api_key", fields: %{"KEY" => "k"}})
    assert {:error, "this credential carries no OAuth material"} = api_key.("github")

    {rebound, %{entry: rebound_entry}} = token_fn(vault: oauth())
    :ok = set_entry!(rebound_entry, provider_hint: "rebound")
    assert {:error, "the credential no longer matches its consent"} = rebound.("github")

    {revoked, %{entry: revoked_entry}} = token_fn(vault: oauth())
    {:ok, _} = Sanctum.Vault.revoke(ctx, revoked_entry.id)
    assert {:error, "the credential is revoked"} = revoked.("github")
  end

  test "an anonymous caller's attempt is refused at attach, before any token is asked for", %{
    ctx: ctx
  } do
    {authority, _entry} = AttemptFixtures.vault_authority!(ctx, oauth())

    attempt =
      AttemptFixtures.attached!(
        ctx: %{ctx | anonymous: true},
        authority: authority,
        attach: false
      )

    assert %{"error" => "setup_required", "payload" => %{"reason" => "anonymous_denied"}} =
             AttemptFixtures.call(attempt, "attach", %{"assignment" => attempt.assignment})
  end

  test "a refusal does not carry the payload it refused", %{ctx: ctx} do
    # The reason names the material it could not decode; the guest gets the
    # shape of the failure, not its contents.
    {fun, %{entry: entry}} = token_fn(vault: oauth())
    aad = Sanctum.CipherAAD.vault_entry(ctx.athanor_id, entry.id, entry.provider_hint)
    {:ok, sealed} = Sanctum.Cipher.encrypt(~s({"v":2,"fields":{},"cyfr_live_leak":1}), aad)
    :ok = set_entry!(entry, sealed_payload: sealed)

    assert {:error, message} = fun.("google")
    assert is_binary(message)
    refute message =~ "cyfr_live_leak"
  end

  test "the guest-supplied provider name is bounded" do
    {fun, _attempt} = token_fn(vault: oauth(%{provider_hint: "google"}))

    assert {:error, message} = fun.(String.duplicate("x", 10_000))
    assert byte_size(message) < 1_000
  end

  test "an attempt that is no longer open is refused as a string" do
    {fun, attempt} = token_fn(vault: oauth())
    ref = Process.monitor(attempt.pid)
    Process.exit(attempt.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    assert {:error, "the credential store is unavailable"} = fun.("google")
  end
end
