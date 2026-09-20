# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CipherRotationTest do
  @moduledoc """
  The rows a key rotation walks: who may ask for them, that the walk stays
  paged, and that a write lands only while the ciphertext it read is still
  in the row.

  Ciphertext here is opaque bytes. Nothing in this module knows a key or a
  plaintext, and neither does the facade under test.
  """
  # async: false — one case drops a table inside its transaction.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.CipherRotation, as: Rotation

  @athanor "ath_rotation"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, actor: Cyfr.Actor.system()}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  # Opaque bytes standing in for a sealed envelope: this layer never reads
  # one, so nothing here has to be a real cipher envelope.
  defp bytes(tag), do: "sealed:" <> tag

  defp put_token(id, ct) do
    Arca.Repo.insert_all(Arca.Schemas.RegistryToken, [
      %{
        id: id,
        user_id: "user_1",
        registry: "registry.test",
        namespace_slug: "ns-#{id}",
        credential_ciphertext: ct,
        issued_at: now(),
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp put_webhook(id, secret, previous) do
    Arca.Repo.insert_all(Arca.Schemas.Webhook, [
      %{
        id: id,
        name: "hook-#{id}",
        slug: "wh_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
        target_ref: "catalyst:local.x:1.0.0",
        secret_encrypted: secret,
        previous_secret_encrypted: previous,
        signature_header: "x-cyfr-signature",
        input_template: "{}",
        enabled: true,
        profile_id: "prof_test",
        athanor_id: @athanor,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp put_vault(id, sealed) do
    Arca.Repo.insert_all(Arca.Schemas.VaultEntry, [
      %{
        id: id,
        athanor_id: @athanor,
        name: "entry-#{id}",
        provider_hint: "legacy",
        kind: "bundle",
        status: if(sealed, do: "active", else: "tombstoned"),
        payload_rev: 0,
        sealed_payload: sealed,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp column(table, id, field) do
    Arca.Repo.one(from(r in table, where: r.id == ^id, select: field(r, ^field)))
  end

  describe "who may ask" do
    @tag :capture_log
    test "an athanor-scoped actor is refused, before any query", %{actor: system} do
      tenant = %Cyfr.Actor{athanor_id: @athanor}
      put_token("rt_probe", bytes("k1"))

      # With the table gone, a facade that queried first would answer
      # `:database_error`. Every refusal below is the scope check, decided
      # before the query it would have run.
      Arca.Repo.query!("DROP TABLE registry_tokens")

      assert {:error, :not_platform} = Rotation.page(tenant, :registry_tokens, nil, 10)
      assert {:error, :not_platform} = Rotation.ciphertext_page(tenant, :registry_tokens, nil, 10)

      assert {:error, :not_platform} =
               Rotation.swap(tenant, :registry_tokens, "rt_probe", bytes("k1"), %{
                 credential_ciphertext: bytes("k2")
               })

      assert {:error, :database_error} = Rotation.page(system, :registry_tokens, nil, 10)
    end

    test "a context or a bare id is not an actor and raises", %{actor: actor} do
      ctx = Sanctum.TestContext.local()

      assert_raise FunctionClauseError, fn -> Rotation.page(ctx, :vault_entries, nil, 10) end
      # Through apply/3: an argument of the wrong shape in the first
      # position is the mistake under test, and spelling it as a literal
      # call would only make the type checker complain instead of the
      # facade.
      assert_raise FunctionClauseError, fn ->
        apply(Rotation, :page, [@athanor, :vault_entries, nil, 10])
      end

      assert_raise FunctionClauseError, fn ->
        apply(Rotation, :swap, [
          nil,
          :vault_entries,
          "vlt_1",
          bytes("k1"),
          %{sealed_payload: bytes("k2")}
        ])
      end

      assert {:ok, []} = Rotation.page(actor, :vault_entries, nil, 10)
    end

    test "an unresolved id or token is refused, never answered as a lost race", %{actor: actor} do
      put_vault("vlt_1", bytes("k1"))

      # `:stale` means a concurrent write beat this one. An empty id or an
      # empty token matches no row, so a looser guard would answer `:stale`
      # for a row nobody touched — the rotation would count it skipped and
      # leave it unrotated with nothing saying why.
      assert_raise FunctionClauseError, fn ->
        Rotation.swap(actor, :vault_entries, "", bytes("k1"), %{sealed_payload: bytes("k2")})
      end

      assert_raise FunctionClauseError, fn ->
        Rotation.swap(actor, :vault_entries, "vlt_1", "", %{sealed_payload: bytes("k2")})
      end

      assert column("vault_entries", "vlt_1", :sealed_payload) == bytes("k1")
    end

    test "an empty cursor is not a cursor", %{actor: actor} do
      put_token("rt_1", bytes("k1"))

      # `nil` is the first page. An empty string would compare greater than
      # nothing and silently behave as the beginning, so a resume point
      # that came back empty would restart the walk instead of failing.
      assert_raise FunctionClauseError, fn -> Rotation.page(actor, :registry_tokens, "", 10) end

      assert_raise FunctionClauseError, fn ->
        Rotation.ciphertext_page(actor, :registry_tokens, "", 10)
      end

      assert {:ok, [_]} = Rotation.page(actor, :registry_tokens, nil, 10)
    end

    test "a table this module does not know is refused, not guessed", %{actor: actor} do
      assert {:error, {:unknown_table, :users}} = Rotation.page(actor, :users, nil, 10)

      assert {:error, {:unknown_table, :users}} =
               Rotation.ciphertext_page(actor, :users, nil, 10)

      assert {:error, {:unknown_table, :users}} =
               Rotation.swap(actor, :users, "u_1", bytes("k1"), %{secret_encrypted: bytes("k2")})
    end
  end

  describe "the roster" do
    test "names every credential table, each with its CAS column" do
      assert Enum.sort(Rotation.tables()) ==
               [:oauth_provider_credentials, :registry_tokens, :vault_entries, :webhooks]

      assert Rotation.cas_column(:webhooks) == :secret_encrypted
      assert Rotation.cas_column(:vault_entries) == :sealed_payload
      assert Rotation.cas_column(:registry_tokens) == :credential_ciphertext
      assert Rotation.cas_column(:oauth_provider_credentials) == :payload_ciphertext
    end
  end

  describe "paging" do
    test "is keyset by id: every row once, in order, bounded by the limit", %{actor: actor} do
      ids = for n <- 1..5, do: put_token("rt_#{n}", bytes("k1-#{n}"))

      walked = walk(actor, :registry_tokens, nil, 2, [])

      assert Enum.map(walked, & &1.id) == Enum.sort(ids)

      # The limit is honoured, so the walk is bounded however large the
      # table is — an unpaged read would answer all five at once.
      assert {:ok, first} = Rotation.page(actor, :registry_tokens, nil, 2)
      assert length(first) == 2

      assert {:ok, rest} = Rotation.page(actor, :registry_tokens, "rt_2", 10)
      assert Enum.map(rest, & &1.id) == ["rt_3", "rt_4", "rt_5"]
    end

    test "a row with nothing sealed in it is not a row to walk", %{actor: actor} do
      live = put_vault("vlt_live", bytes("k1"))
      put_vault("vlt_tombstoned", nil)

      assert {:ok, [row]} = Rotation.page(actor, :vault_entries, nil, 10)
      assert row.id == live

      assert {:ok, [audited]} = Rotation.ciphertext_page(actor, :vault_entries, nil, 10)
      assert audited.id == live
    end

    test "a row carries its binding columns and its ciphertexts, CAS first", %{actor: actor} do
      put_webhook("wh_1", bytes("current"), bytes("previous"))

      assert {:ok, [row]} = Rotation.page(actor, :webhooks, nil, 10)

      assert row.athanor_id == @athanor
      assert row.name == "hook-wh_1"

      # Order is the contract: the head is what a swap compares against,
      # and `previous_secret_encrypted` is nullable — a map keyed by column
      # would sort it to the front and make a nullable column the token.
      assert row.ciphertexts == [
               {:secret_encrypted, bytes("current")},
               {:previous_secret_encrypted, bytes("previous")}
             ]

      put_webhook("wh_2", bytes("only"), nil)

      assert {:ok, [_, second]} = Rotation.page(actor, :webhooks, nil, 10)
      assert second.ciphertexts == [{:secret_encrypted, bytes("only")}]
    end
  end

  describe "the compare-and-set" do
    test "writes while the ciphertext it read is still there", %{actor: actor} do
      put_vault("vlt_1", bytes("k1"))

      assert {:ok, :swapped} =
               Rotation.swap(actor, :vault_entries, "vlt_1", bytes("k1"), %{
                 sealed_payload: bytes("k2")
               })

      assert column("vault_entries", "vlt_1", :sealed_payload) == bytes("k2")
    end

    test "writes nothing when the row moved under it", %{actor: actor} do
      put_vault("vlt_1", bytes("k1"))

      # Somebody else re-sealed the row after the page read it.
      {1, _} =
        Arca.Repo.update_all(from(r in Arca.Schemas.VaultEntry, where: r.id == "vlt_1"),
          set: [sealed_payload: bytes("theirs")]
        )

      assert {:ok, :stale} =
               Rotation.swap(actor, :vault_entries, "vlt_1", bytes("k1"), %{
                 sealed_payload: bytes("k2")
               })

      assert column("vault_entries", "vlt_1", :sealed_payload) == bytes("theirs")
    end

    test "leaves every other column of the row alone", %{actor: actor} do
      put_vault("vlt_1", bytes("k1"))

      assert {:ok, :swapped} =
               Rotation.swap(actor, :vault_entries, "vlt_1", bytes("k1"), %{
                 sealed_payload: bytes("k2")
               })

      # `payload_rev` is the material CAS token of the entry's own writer;
      # a re-seal of unchanged material must not move it.
      assert column("vault_entries", "vlt_1", :payload_rev) == 0
      assert column("vault_entries", "vlt_1", :status) == "active"
    end

    test "both of a webhook's secrets move together, keyed on the primary one", %{actor: actor} do
      put_webhook("wh_1", bytes("current"), bytes("previous"))

      assert {:ok, :swapped} =
               Rotation.swap(actor, :webhooks, "wh_1", bytes("current"), %{
                 secret_encrypted: bytes("new-current"),
                 previous_secret_encrypted: bytes("new-previous")
               })

      assert column("webhooks", "wh_1", :secret_encrypted) == bytes("new-current")
      assert column("webhooks", "wh_1", :previous_secret_encrypted) == bytes("new-previous")
    end

    test "a column the table does not seal is refused and writes nothing", %{actor: actor} do
      put_vault("vlt_1", bytes("k1"))

      assert {:error, :unknown_column} =
               Rotation.swap(actor, :vault_entries, "vlt_1", bytes("k1"), %{status: "tombstoned"})

      assert column("vault_entries", "vlt_1", :status) == "active"
      assert column("vault_entries", "vlt_1", :sealed_payload) == bytes("k1")
    end
  end

  defp walk(actor, table, cursor, limit, acc) do
    case Rotation.page(actor, table, cursor, limit) do
      {:ok, []} -> acc
      {:ok, rows} -> walk(actor, table, List.last(rows).id, limit, acc ++ rows)
    end
  end
end
