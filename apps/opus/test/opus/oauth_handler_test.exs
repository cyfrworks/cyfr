# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.OAuthHandlerTest do
  @moduledoc """
  The `cyfr:oauth/token` host boundary.

  A guest's token request is answered by its execution's attempt: a
  dispensed token crosses as the token, and every refusal — the edge's
  vault state, a tampered payload, an execution with no open attempt —
  crosses the WIT result<string, string> boundary as a bounded string that
  names the shape of the failure, never the material involved.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge

  @token "tok-live"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # The import of a guest whose attempt runs under `authority`.
  defp token_fn(ctx, authority) do
    execution_id = "exec_oauth_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Cyfr.Execution.Attempt.open(
        execution_id: execution_id,
        ctx: ctx,
        authority: authority,
        component_ref: "catalyst:local.probe:0.1.0"
      )

    fun_of(execution_id)
  end

  defp fun_of(execution_id) do
    imports = Opus.OAuthHandler.build_oauth_imports(execution_id)
    {:fn, fun} = imports["cyfr:oauth/token@0.1.0"]["get-access-token"]
    fun
  end

  defp vault_entry!(ctx, attrs) do
    {:ok, view} =
      Sanctum.Vault.create(
        ctx,
        Map.merge(%{name: "oauth-#{System.unique_integer([:positive])}", kind: "oauth"}, attrs)
      )

    {:ok, entry} = Arca.VaultStorage.get(ctx.athanor_id, view.id)
    entry
  end

  defp bound(entry, digest \\ nil) do
    {:ok, derived} = Sanctum.VaultReader.binding_digest(entry)
    vault = %{entry_id: entry.id, binding_digest: digest || derived, projection: nil}
    %{Authority.zero() | resources: %Edge{vault: vault}}
  end

  test "a dispensed token crosses as the token", %{ctx: ctx} do
    entry = vault_entry!(ctx, %{oauth: %{"access_token" => @token}})

    assert {:ok, @token} = token_fn(ctx, bound(entry)).("google")
  end

  test "every refusal crosses as a string", %{ctx: ctx} do
    google = vault_entry!(ctx, %{provider_hint: "google", oauth: %{"access_token" => @token}})
    api_key = vault_entry!(ctx, %{kind: "api_key", fields: %{"KEY" => "k"}})
    revoked = vault_entry!(ctx, %{oauth: %{"access_token" => @token}})
    {:ok, _} = Sanctum.Vault.revoke(ctx, revoked.id)

    refusals = [
      {ctx, Authority.zero(), "no vault resource granted on this edge"},
      {ctx, bound(google), "this credential is not for github"},
      {ctx, bound(api_key), "this credential carries no OAuth material"},
      {ctx, bound(google, "sha256:rebound"), "the credential no longer matches its consent"},
      {ctx, bound(revoked), "the credential is revoked"},
      {%{ctx | anonymous: true}, bound(google), "anonymous callers may not dispense tokens"}
    ]

    for {ctx, authority, expected} <- refusals do
      assert {:error, ^expected} = token_fn(ctx, authority).("github")
    end
  end

  test "a refusal does not carry the payload it refused", %{ctx: ctx} do
    # The reason names the material it could not decode; the guest gets the
    # shape of the failure, not its contents.
    id = Cyfr.UUID7.generate_id("vlt")
    aad = Sanctum.CipherAAD.vault_entry(ctx.athanor_id, id, "")
    json = ~s({"v":2,"fields":{},"cyfr_live_leak":1})
    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

    {:ok, entry} =
      Arca.VaultStorage.put(%{
        id: id,
        athanor_id: ctx.athanor_id,
        name: "tampered",
        provider_hint: "",
        kind: "oauth",
        sealed_payload: sealed
      })

    assert {:error, message} = token_fn(ctx, bound(entry)).("google")
    assert is_binary(message)
    refute message =~ "cyfr_live_leak"
  end

  test "the guest-supplied provider name is bounded", %{ctx: ctx} do
    entry = vault_entry!(ctx, %{provider_hint: "google", oauth: %{"access_token" => @token}})

    assert {:error, message} = token_fn(ctx, bound(entry)).(String.duplicate("x", 10_000))
    assert byte_size(message) < 1_000
  end

  test "an execution with no open attempt is refused as a string" do
    assert {:error, message} = fun_of("exec_oauth_unopened").("google")
    assert is_binary(message)
  end
end
