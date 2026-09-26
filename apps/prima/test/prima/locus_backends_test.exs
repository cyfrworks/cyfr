# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusBackendsTest do
  @moduledoc """
  The backends wire reproduces every shared vector
  (`tests/fixtures/locus_backends.json`): the protocol's data and bounds,
  the keys derived over the service label, each control message's and the
  invoke's canonical string, MAC and header, every control body and answer
  read to its members and written back to its bytes, the sealed
  environment, every accepted and malformed header, every valid and invalid
  field, every invalid message refused with its error and answered with its
  refusal, every rejected header refused at its instant, every fence
  vector's messages signed and its refusal of the roster, the refusal roster
  and the masking rule. Beyond the vectors: header-first verification
  refuses exactly what the one-step verifier refuses, the bounds on a
  control body and a status answer hold, and a body at another version is
  refused before its type is read.
  """
  use ExUnit.Case, async: true

  alias Prima.{KeeperProtocol, LocusBackends, MacEnvelope}
  alias Prima.MCP.Protocol, as: MCPProtocol

  @vectors Path.expand("../../../../tests/fixtures/locus_backends.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @control_types ~w(hello reconcile sync renew release status)

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp unhex(text), do: Base.decode16!(text, case: :lower)
  defp key, do: unhex(@vectors["key_hex"])
  defp tag(error) when is_tuple(error), do: elem(error, 0)
  defp tag(error) when is_atom(error), do: error

  defp atom_keys(map),
    do: Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp owner, do: atom_keys(@vectors["owner"])

  describe "the shared vectors" do
    test "the protocol's data is what the vectors say" do
      v = @vectors

      assert LocusBackends.version() == v["version"]
      assert LocusBackends.domain() == v["domain"]
      assert LocusBackends.service() == v["service"]
      assert LocusBackends.label() == v["label"]
      assert v["label"] == v["domain"] <> "/" <> v["service"]
      assert LocusBackends.domain() == Prima.BuilderProtocol.domain()
      assert LocusBackends.auth_header() == v["auth_header"]
      assert LocusBackends.auth_header() == Prima.BuilderProtocol.auth_header()
      assert LocusBackends.boot_header() == v["boot_header"]
      assert LocusBackends.window_ms() == v["window_ms"]
      assert LocusBackends.window_ms() == Prima.BuilderProtocol.window_ms()

      assert LocusBackends.routes() == atom_keys(v["routes"])

      for {operation, route} <- LocusBackends.routes() do
        assert LocusBackends.route(operation) == route
        assert LocusBackends.operation(route) == {:ok, operation}
      end

      assert LocusBackends.operation("/locus/v1/builds/build") == :error

      assert Map.new(LocusBackends.classes(), &{Atom.to_string(&1), LocusBackends.status(&1)}) ==
               v["statuses"]
    end

    test "every bound is what the vectors say, each through its own accessor" do
      v = @vectors
      bounds = Map.put(v["bounds"], "literal_env_names", v["literal_env_names"])

      assert LocusBackends.bounds() == atom_keys(bounds)

      for {name, bound} <- bounds do
        assert apply(LocusBackends, String.to_existing_atom(name), []) == bound, name
      end

      assert LocusBackends.nonce_window_ms() == LocusBackends.window_ms()
      assert LocusBackends.max_status_answer_bytes() == LocusBackends.max_control_bytes()
    end

    test "the reserved variables are the keeper's, and the vectors name them" do
      assert LocusBackends.reserved_env_names() == KeeperProtocol.reserved_env_names()
      assert LocusBackends.reserved_env_prefixes() == KeeperProtocol.reserved_env_prefixes()
      assert LocusBackends.reserved_env_prefixes() == @vectors["reserved_env_prefixes"]
    end

    test "the MCP names an invoke carries through are Prima.MCP.Protocol's" do
      assert LocusBackends.mcp_headers() == MCPProtocol.request_headers()

      assert LocusBackends.mcp_meta_keys() == [
               MCPProtocol.meta_protocol_version_key(),
               MCPProtocol.meta_client_capabilities_key()
             ]
    end

    test "the keys derive from the service key over the label, and the key text decodes" do
      v = @vectors

      assert hex(LocusBackends.control_key(key())) == v["control_key_hex"]
      assert hex(LocusBackends.seal_key(key())) == v["seal_key_hex"]
      assert {:ok, owner_key} = LocusBackends.owner_key(key(), owner())
      assert hex(owner_key) == v["owner_key_hex"]

      assert LocusBackends.control_key(key()) ==
               MacEnvelope.derive(key(), v["label"] <> "/control")

      for text <- v["key_text"]["valid"] do
        assert {:ok, decoded} = LocusBackends.decode_key(text)
        assert decoded == key()
      end

      for text <- v["key_text"]["invalid"],
          do: assert(:error = LocusBackends.decode_key(text), inspect(text))

      assert :error = LocusBackends.decode_key(nil)
    end

    test "each control message signs, reads and writes back as the vectors say" do
      control_key = LocusBackends.control_key(key())

      for type <- @control_types do
        v = @vectors[type]
        fields = atom_keys(v["fields"])
        answer_type = String.to_existing_atom(type)

        assert fields.ts == v["ts"], type
        assert {:ok, v["canonical"]} == LocusBackends.canonical(:control, fields, v["body"]), type

        assert {:ok, v["header"]} == LocusBackends.control_header(control_key, fields, v["body"]),
               type

        [_signed, mac] = String.split(v["header"], " mac=")
        assert mac == v["mac"], type

        assert Base.url_encode64(:crypto.mac(:hmac, :sha256, control_key, v["canonical"]),
                 padding: false
               ) == mac

        assert v["canonical"] |> String.split("\n") |> List.first() ==
                 @vectors["label"] <> "/control"

        assert {:ok, ^fields} =
                 LocusBackends.verify(:control, key(), v["header"], v["body"], v["ts"])

        assert {:ok, message} = LocusBackends.read_control(v["body"]), type
        assert message.type == answer_type
        assert {:ok, v["body"]} == LocusBackends.encode_control(message), type

        assert {:ok, answer} = LocusBackends.read_answer(answer_type, v["answer"]), type
        assert {:ok, v["answer"]} == LocusBackends.encode_answer(answer_type, answer), type
      end
    end

    test "a hello names no lifetime yet, and a sync carries the sealed environment" do
      assert @vectors["hello"]["fields"]["boot"] == "-"

      assert {:ok, %{type: :sync, sealed: sealed, owner: owner_ref, e: e}} =
               LocusBackends.read_control(@vectors["sync"]["body"])

      assert sealed == @vectors["seal"]["sealed"]
      assert %{athanor: owner().athanor, server: owner().server} == owner_ref
      assert e == owner().epoch
    end

    test "the invoke signs under the owner's key and carries an MCP body as the vectors say" do
      v = @vectors["invoke"]
      fields = atom_keys(v["fields"])
      {:ok, owner_key} = LocusBackends.owner_key(key(), owner())

      assert Map.take(fields, Map.keys(owner())) == owner()
      assert {:ok, v["canonical"]} == LocusBackends.canonical(:invoke, fields, v["body"])
      assert {:ok, v["header"]} == LocusBackends.invoke_header(owner_key, fields, v["body"])
      [_signed, mac] = String.split(v["header"], " mac=")
      assert mac == v["mac"]
      assert v["header"] =~ " gen=#{owner().generation} "

      assert {:ok, ^fields} =
               LocusBackends.verify(:invoke, key(), v["header"], v["body"], fields.ts)

      body = Jason.decode!(v["body"])
      assert body["method"] == "tools/list"
      meta = body["params"]["_meta"]
      assert Enum.sort(Map.keys(meta)) == Enum.sort(LocusBackends.mcp_meta_keys())
      assert meta[MCPProtocol.meta_protocol_version_key()] == MCPProtocol.version()

      answer = Jason.decode!(v["answer"])
      assert answer["id"] == body["id"]
      assert %{"tools" => [_ | _]} = answer["result"]
    end

    test "the sealed environment matches, and opens for its owner and lifetime only" do
      v = @vectors["seal"]
      key = LocusBackends.seal_key(key())
      iv = unhex(v["iv_hex"])

      assert {:ok, v["sealed"]} == LocusBackends.seal(key, owner(), v["boot"], v["plaintext"], iv)
      assert {:ok, v["plaintext"]} == LocusBackends.open(key, owner(), v["boot"], v["sealed"])
      assert {:error, :unsealable} = LocusBackends.open(key, owner(), "bb_other", v["sealed"])

      assert {:error, :unsealable} =
               LocusBackends.open(key, %{owner() | epoch: 8}, v["boot"], v["sealed"])

      assert {:error, :unsealable} =
               LocusBackends.open(
                 LocusBackends.control_key(key()),
                 owner(),
                 v["boot"],
                 v["sealed"]
               )

      assert {:error, :unsealable} = LocusBackends.open(key, owner(), v["boot"], "not-sealed")
    end

    test "every accepted header parses as its kind to its fields, body hash and MAC" do
      for %{
            "kind" => kind,
            "header" => header,
            "fields" => fields,
            "body_hash" => hash,
            "mac" => mac
          } <-
            @vectors["header_parse"]["accepted"] do
        expected = fields |> atom_keys() |> Map.put(:body_hash, hash)

        assert {:ok, ^expected, ^mac} =
                 LocusBackends.parse_header(String.to_existing_atom(kind), header),
               header
      end
    end

    test "every malformed header is refused as its kind" do
      for %{"kind" => kind, "header" => header} <- @vectors["header_parse"]["malformed"] do
        assert {:error, :malformed} =
                 LocusBackends.parse_header(String.to_existing_atom(kind), header),
               inspect(header)
      end
    end

    test "every valid field is accepted and every invalid field is refused" do
      invoke = Map.merge(owner(), %{boot: "bb", ts: 1, nonce: "n"})

      for %{"field" => field, "value" => value} <- @vectors["valid_fields"] do
        name = String.to_existing_atom(field)

        assert {:ok, _canonical} =
                 LocusBackends.canonical(:invoke, Map.put(invoke, name, value), "{}")
      end

      for %{"field" => field, "value" => value} <- @vectors["invalid_fields"] do
        name = String.to_existing_atom(field)

        assert {:error, {:invalid_field, ^name}} =
                 LocusBackends.canonical(:invoke, Map.put(invoke, name, value), "{}")
      end
    end

    test "every invalid message is refused with its error, answered with its refusal, and described" do
      for %{"name" => name, "body" => body, "error" => error, "refusal" => refusal} <-
            @vectors["invalid_messages"] do
        assert {:error, err} = LocusBackends.read_control(body), name
        assert Atom.to_string(tag(err)) == error, "#{name}: #{inspect(err)}"
        assert Atom.to_string(LocusBackends.code(LocusBackends.refusal_for(err))) == refusal, name
        assert is_binary(LocusBackends.describe(err))
      end

      names = Enum.map(@vectors["invalid_messages"], & &1["name"])

      for name <- ~w(wrong_version no_version unknown_type bad_owner_ref too_many_owners
                     oversize_lease oversize_idle bad_backend_definition vault_command
                     env_name_form reserved_env_name) do
        assert name in names, name
      end
    end

    test "every rejected header is refused at its instant, one-step and header-first" do
      for %{
            "name" => name,
            "kind" => kind,
            "header" => header,
            "body" => body,
            "now" => now,
            "refusal" => refusal
          } <- @vectors["auth_rejected"] do
        kind = String.to_existing_atom(kind)
        expected = String.to_existing_atom(refusal)

        assert {:error, ^expected} = LocusBackends.verify(kind, key(), header, body, now), name

        case LocusBackends.verify_header(kind, key(), header, now) do
          {:ok, _fields, hash} ->
            assert name == "tampered_body"
            assert {:error, :bad_mac} = LocusBackends.verify_body(kind, hash, body)

          {:error, why} ->
            assert why == expected, name
        end
      end

      names = Enum.map(@vectors["auth_rejected"], & &1["name"])
      assert "builds_label" in names and "builds_key" in names
    end

    test "every fence vector is a sequence of signed messages refused with a code of the roster" do
      fences = @vectors["fence_rejected"]
      refusals = Map.new(@vectors["refusals"], &{&1["code"], &1})

      for code <- ~w(stale_boot stale_control stale_epoch epoch_ahead conflict lapsed
                     unknown_owner replay capacity unavailable too_many_owners
                     status_too_large nonce_cache_full) do
        assert code in Enum.map(fences, & &1["refusal"]), code
      end

      for %{"name" => name, "sequence" => sequence, "refusal" => refusal} = vector <- fences do
        assert vector |> Map.keys() |> Kernel.--(["given"]) |> Enum.sort() ==
                 ~w(name refusal sequence),
               name

        # The refusal is the roster's, at its status, as its body.
        code = String.to_existing_atom(refusal)
        assert LocusBackends.status(code) == refusals[refusal]["status"], name
        assert LocusBackends.encode_refusal(code) == refusals[refusal]["body"], name

        messages = Enum.filter(sequence, &Map.has_key?(&1, "route"))
        refused = Enum.find(messages, & &1["hold"]) || List.last(messages)
        assert is_boolean(refused["read_body"]), name

        for step <- sequence -- messages do
          assert [{"advance_ms", ms}] = Map.to_list(step), name
          assert ms > 0, name
        end

        # Each message is signed as its route's kind, at its instant, over
        # its body.
        for message <- messages do
          {kind, route} =
            case message["route"] do
              "control" -> {:control, LocusBackends.route(:control)}
              "mcp" -> {:invoke, LocusBackends.route(:mcp)}
            end

          assert @vectors["routes"][message["route"]] == route
          assert {:ok, fields, _mac} = LocusBackends.parse_header(kind, message["header"]), name
          assert fields.ts == message["now"], name
          assert fields.body_hash == Prima.Digest.sha256_hex(message["body"]), name

          # An invoke carries the MCP conformance headers beside its signature.
          assert message
                 |> Map.get("headers", %{})
                 |> Map.keys()
                 |> Kernel.--(LocusBackends.mcp_headers()) == [],
                 name

          if message != refused,
            do: assert(message["status"] in [200, LocusBackends.status(:lapsed)], name)
        end
      end
    end

    test "every refusal is answered at its status as its body, and reads back" do
      assert Enum.map(@vectors["refusals"], & &1["code"]) ==
               Enum.map(LocusBackends.classes(), &Atom.to_string/1)

      for %{"code" => code, "status" => status, "body" => body} <- @vectors["refusals"] do
        code = String.to_existing_atom(code)
        assert LocusBackends.status(code) == status
        assert LocusBackends.encode_refusal(code) == body
        assert {:ok, ^code} = LocusBackends.read_refusal(body)
      end

      for code <- ~w(stale_boot stale_control stale_epoch epoch_ahead replay) do
        assert code in Enum.map(@vectors["refusals"], & &1["code"])
      end
    end

    test "the masking rule turns the input into the output" do
      m = @vectors["masking"]
      assert LocusBackends.mask(m["input"], m["secrets"]) == m["output"]
    end
  end

  describe "beyond the vectors" do
    test "header-first verification refuses exactly what one-step verification refuses" do
      v = @vectors["status"]
      hash = Prima.Digest.sha256_hex(v["body"])
      fields = atom_keys(v["fields"])

      assert {:ok, ^fields, ^hash} =
               LocusBackends.verify_header(:control, key(), v["header"], v["ts"])

      assert :ok = LocusBackends.verify_body(:control, hash, v["body"])
      assert {:error, :bad_mac} = LocusBackends.verify_body(:control, hash, v["body"] <> " ")

      i = @vectors["invoke"]

      {:ok, _fields, ihash} =
        LocusBackends.verify_header(:invoke, key(), i["header"], i["fields"]["ts"])

      assert :ok = LocusBackends.verify_body(:invoke, ihash, i["body"])
    end

    test "neither kind verifies as the other, nor under the builds key" do
      c = @vectors["status"]
      i = @vectors["invoke"]
      builds_key = unhex(@vectors["builds_key_hex"])

      assert {:error, :malformed} =
               LocusBackends.verify(:invoke, key(), c["header"], c["body"], c["ts"])

      assert {:error, :bad_mac} =
               LocusBackends.verify(:control, builds_key, c["header"], c["body"], c["ts"])

      assert {:error, :bad_mac} =
               LocusBackends.verify(
                 :invoke,
                 builds_key,
                 i["header"],
                 i["body"],
                 i["fields"]["ts"]
               )
    end

    test "a control body and a status answer are bounded before they are parsed" do
      max = LocusBackends.max_control_bytes()
      big = :binary.copy(" ", max + 1)

      assert {:error, {:too_large, :control, bytes, ^max}} = LocusBackends.read_control(big)
      assert bytes == max + 1
      assert :too_large = LocusBackends.refusal_for({:too_large, :control, bytes, max})
      assert LocusBackends.status(:too_large) == 413

      status_max = LocusBackends.max_status_answer_bytes()

      assert {:error, {:too_large, :status_answer, _bytes, ^status_max}} =
               LocusBackends.read_answer(:status, :binary.copy(" ", status_max + 1))

      assert :status_too_large =
               LocusBackends.refusal_for({:too_large, :status_answer, status_max + 1, status_max})
    end

    test "a status answer the encoder would send past its bound is refused whole" do
      {:ok, answer} = LocusBackends.read_answer(:status, @vectors["status"]["answer"])
      [owner] = answer.owners
      [backend] = owner.backends
      tail = String.duplicate("x", LocusBackends.stderr_tail_bytes())

      backends =
        for i <- 1..LocusBackends.max_backends(),
            do: %{backend | name: "b#{i}", stderr_tail: tail}

      owner = %{owner | backends: backends}

      assert {:error, {:too_large, :status_answer, _bytes, _max}} =
               LocusBackends.encode_answer(:status, %{owners: [owner]})
    end

    test "a body at another version is refused before its type is read, and maps to the version refusal" do
      assert {:error, {:version, 2}} = LocusBackends.read_control(~s({"version":2,"type":"nope"}))
      assert {:error, {:version, nil}} = LocusBackends.read_control(~s({"type":"hello"}))
      assert {:protocol_mismatch, 1, 2} = LocusBackends.refusal_for({:version, 2})
      assert {:protocol_mismatch, 1, nil} = LocusBackends.refusal_for({:version, "1"})

      assert LocusBackends.encode_refusal({:protocol_mismatch, 1, 2}) ==
               ~s({"error":"version","version":1})

      assert LocusBackends.status({:protocol_mismatch, 1, nil}) == 409

      assert {:error, {:version, 2}} =
               LocusBackends.read_answer(
                 :hello,
                 ~s({"version":2,"boot":"bb","pool":{"size":1,"free":1}})
               )
    end

    test "an answer that is not of its type's shape is refused" do
      assert {:error, {:unknown_field, "released"}} =
               LocusBackends.read_answer(:sync, @vectors["release"]["answer"])

      assert {:error, {:invalid_field, "owners[0].state"}} =
               @vectors["status"]["answer"]
               |> Jason.decode!()
               |> put_in(["owners", Access.at(0), "state"], "gone")
               |> Jason.encode!()
               |> then(&LocusBackends.read_answer(:status, &1))
    end

    test "the encoder refuses what the reader refuses" do
      {:ok, message} = LocusBackends.read_control(@vectors["sync"]["body"])

      assert {:error, {:out_of_range, "lease_ms", _, _}} =
               LocusBackends.encode_control(%{
                 message
                 | lease_ms: LocusBackends.max_lease_ms() + 1
               })

      assert {:error, {:unknown_field, "extra"}} =
               LocusBackends.encode_control(Map.put(message, :extra, 1))
    end

    test "masking leaves every value alone when there is nothing to mask" do
      value = %{"a" => ["short", 1, nil]}
      assert LocusBackends.mask(value, []) == value
      assert LocusBackends.mask(value, ["short"]) == value
    end
  end
end
