# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.OAuthTokenCallTest do
  @moduledoc """
  What CYFR answers a guest's token request, the `oauth_token` host call
  of its execution's attached attempt: a dispensed token is the answer,
  and every refusal by the edge's vault state as it stands when the token
  is asked for, or by a tampered payload, is a guest error whose message is
  a bounded sentence naming the shape of the failure, never the material
  involved. An attempt that is no longer open is answered no token.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Cyfr.Test.{AttemptFixtures, HostCaller, RuntimeService}

  @token "tok-live"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local(:api)}
  end

  # The token request of a guest whose attempt is attached with `opts`
  # (`Cyfr.Test.AttemptFixtures.attached!/1`), and that attempt.
  defp token_fn(opts) do
    attempt =
      AttemptFixtures.attached!(Keyword.put_new(opts, :ctx, Sanctum.TestContext.local(:api)))

    {fun_of(attempt), attempt}
  end

  # CYFR's answer to the attempt's `oauth_token` for a provider: the token,
  # or the message of the guest error it refused with.
  defp fun_of(attempt) do
    fn provider ->
      case HostCaller.call(attempt, RuntimeService.host_url(), :oauth_token, %{
             "provider" => provider
           }) do
        {:ok, token} -> {:ok, token}
        {:error, "guest_error", %{"message" => message}} -> {:error, message}
        other -> other
      end
    end
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
    {:ok, sealed} = Sanctum.Cipher.encrypt(~s({"v":3,"fields":{},"cyfr_live_leak":1}), aad)
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

  test "an attempt that is no longer open is answered no token" do
    {fun, attempt} = token_fn(vault: oauth())
    ref = Process.monitor(attempt.pid)
    Process.exit(attempt.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    assert {:error, "lost", _fields} = fun.("google")
  end
end
