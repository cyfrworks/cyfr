# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConfirmationTest do
  @moduledoc """
  The pending confirmation as data (`tests/fixtures/confirmation.json`):
  the record reads, writes back and digests over its whole JCS form, the
  protocol, home, RP and preview included, so a record changed in any one
  field digests differently; a preview carrying a secret, a preview of
  another home or operation and an RP that is not the home's are refused;
  and a record's public ref is derived one way from its secret.
  """

  use ExUnit.Case, async: true

  alias Prima.Confirmation
  alias Prima.Confirmation.Preview

  @vectors Path.expand("../../../../tests/fixtures/confirmation.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp tag({:error, reason}), do: tag(reason)
  defp tag({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp tag(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp jcs_digest(map) do
    {:ok, bytes} = Prima.JCS.encode(map)
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  test "the record reads, writes back and digests over its whole JCS form" do
    v = vectors()
    assert v["protocol"] == Confirmation.protocol()
    assert v["record"]["protocol"] == Confirmation.protocol()

    assert {:ok, record} = Confirmation.decode(v["record"])
    assert Confirmation.encode(record) == v["record"]
    assert Confirmation.digest(record) == v["digest"]
    assert jcs_digest(v["record"]) == v["digest"]
  end

  test "a record changed in any one field digests differently" do
    v = vectors()

    for %{"name" => name, "record" => map, "digest" => digest} <- v["variations"] do
      assert {:ok, record} = Confirmation.decode(map), name
      assert Confirmation.digest(record) == digest, name
      assert jcs_digest(map) == digest, name
      refute digest == v["digest"], name
    end

    changed =
      v["variations"]
      |> Enum.flat_map(fn %{"record" => map} ->
        for {field, value} <- map, value != v["record"][field], do: field
      end)
      |> MapSet.new()

    assert MapSet.equal?(
             changed,
             v["record"] |> Map.keys() |> MapSet.new() |> MapSet.delete("protocol")
           )
  end

  test "a record's ref is derived one way from its secret, as the vector pins it" do
    %{"id" => id, "protocol" => protocol, "ref" => ref} = vectors()["ref"]

    assert protocol == "cyfr-confirmation-ref/v1"
    assert Confirmation.ref(id) == ref

    assert ref ==
             "cnr_" <> Base.url_encode64(:crypto.hash(:sha256, protocol <> id), padding: false)

    # The secret is 256 bits spelled cnf_ and 43 base64url characters, a
    # valid id; the ref is spelled apart from it, and a ref's own ref is
    # another name, so presenting a ref as a secret names no record.
    assert "cnf_" <> body = id
    assert {:ok, <<_::256>>} = Base.url_decode64(body, padding: false)
    assert Prima.Identity.Encoding.id?(id) and Prima.Identity.Encoding.id?(ref)
    assert Confirmation.ref?(ref)
    refute Confirmation.ref?(id)
    refute Confirmation.ref(ref) == ref
    refute Confirmation.ref(id <> "x") == ref
  end

  test "every refusal is refused with its reason" do
    for %{"name" => name, "record" => map, "error" => error} <- vectors()["refusals"] do
      assert tag(Confirmation.decode(map)) == error, name
    end
  end

  test "new/1 builds the fixture's record from its fields" do
    map = vectors()["record"]
    {:ok, challenge} = Base.url_decode64(map["challenge"], padding: false)

    attrs = [
      id: map["id"],
      home: map["home"],
      rp_id: map["rp_id"],
      athanor: map["athanor"],
      person: map["person"],
      operation: map["operation"],
      args_digest: map["args_digest"],
      action: map["action"],
      preview: [
        home: map["preview"]["home"],
        athanor: map["preview"]["athanor"],
        operation: map["preview"]["operation"],
        resource: map["preview"]["resource"]
      ],
      challenge: challenge,
      expires_at: map["expires_at"]
    ]

    assert {:ok, record} = Confirmation.new(attrs)
    assert Confirmation.encode(record) == map
    assert Confirmation.digest(record) == vectors()["digest"]
    assert byte_size(record.challenge) == Confirmation.challenge_bytes()

    assert {:ok, %Preview{} = preview} = Preview.decode(map["preview"])
    assert Confirmation.new(Keyword.put(attrs, :preview, preview)) == {:ok, record}

    assert Confirmation.new(Keyword.delete(attrs, :preview)) ==
             {:error, {:missing_field, "preview"}}
  end

  test "a preview's details are public facts, never a secret" do
    preview = vectors()["record"]["preview"]

    assert {:ok,
            %Preview{details: %{"recovery_keys" => ["AAAA"], "genesis_digest" => "sha256:00"}}} =
             Preview.decode(
               Map.put(preview, "details", %{
                 "recovery_keys" => ["AAAA"],
                 "genesis_digest" => "sha256:00"
               })
             )

    for secret <- [
          "recovery_secret",
          "password",
          "api_key",
          "token",
          "private_key",
          "seed_secret"
        ] do
      assert Preview.decode(Map.put(preview, "details", %{secret => "x"})) ==
               {:error, :secret_in_preview},
             secret
    end

    assert Preview.decode(Map.put(preview, "details", %{"Name" => "x"})) ==
             {:error, {:invalid_field, "details"}}

    assert Preview.decode(Map.put(preview, "details", %{"n" => 1})) ==
             {:error, {:invalid_field, "details"}}
  end
end
