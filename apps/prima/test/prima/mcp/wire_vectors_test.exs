# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.MCP.WireVectorsTest do
  @moduledoc """
  Prima's MCP codec reproduces the shared vectors
  (`tests/fixtures/mcp_wire.json`, which the CLI's client reads too): the
  revision and the `_meta` keys, the routing headers every request case
  carries, every header value encoded to its header and decoded back, each
  refused sentinel refused, the error codes by name, and every consent
  error produced as its whole response and decoded from it. Every case
  is matched whole, so a case of another shape fails rather than going
  unread.
  """

  use ExUnit.Case, async: true

  alias Prima.{ConsentSignal, Refusal}
  alias Prima.MCP.{Message, Protocol}

  @vectors Path.expand("../../../../../tests/fixtures/mcp_wire.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  # A section's cases, each held to its shape: a case missing a member, or
  # carrying a stray one, fails here instead of being skipped by a pattern.
  defp cases!(section, count, required, optional \\ []) do
    cases = Map.fetch!(@vectors, section)
    assert length(cases) == count, "#{section} holds #{length(cases)} cases, not #{count}"

    for vector <- cases do
      assert is_map(vector), "#{section}: #{inspect(vector)} is not a case"
      keys = Map.keys(vector)

      assert required -- keys == [] and keys -- (required ++ optional) == [],
             "#{section}: #{inspect(vector)} is not a case of #{inspect(required)}"

      vector
    end
  end

  test "the revision is the vectors' and the only one supported" do
    version = @vectors["protocol_version"]

    assert Protocol.version() == version
    assert Protocol.supported() == @vectors["supported"]
    assert Protocol.supported?(version)
  end

  test "the _meta keys are the vectors', and a request's declared version is read under its key" do
    meta = @vectors["meta"]

    assert Protocol.meta_protocol_version_key() == meta["protocol_version"]
    assert Protocol.meta_client_info_key() == meta["client_info"]
    assert Protocol.meta_client_capabilities_key() == meta["client_capabilities"]
    assert Protocol.meta_server_info_key() == meta["server_info"]

    request = %{
      "params" => %{"_meta" => %{meta["protocol_version"] => @vectors["protocol_version"]}}
    }

    assert Protocol.declared_version(request) == @vectors["protocol_version"]
  end

  test "every header value encodes to its header and its header decodes back" do
    for vector <- cases!("header_values", 8, ~w(why value header)) do
      %{"why" => why, "value" => value, "header" => header} = vector
      assert Protocol.encode_header_value(value) == header, why
      assert Protocol.decode_header_value(header) == {:ok, value}, why
    end
  end

  test "a sentinel whose payload does not decode is refused" do
    for vector <- cases!("header_refused", 4, ~w(why header)) do
      %{"why" => why, "header" => header} = vector
      assert Protocol.decode_header_value(header) == :error, why
    end
  end

  test "every request carries its case's routing headers" do
    for vector <- cases!("named_subject", 9, ~w(why request headers)) do
      %{"why" => why, "request" => request, "headers" => headers} = vector

      name =
        case Protocol.named_subject(request) do
          nil -> nil
          subject -> Protocol.encode_header_value(subject)
        end

      assert %{"Mcp-Method" => request["method"], "Mcp-Name" => name} == headers, why
    end
  end

  test "every code name answers its code, CYFR's table is exactly the vectors', and an unknown name the fallback" do
    %{"jsonrpc" => jsonrpc, "cyfr" => cyfr, "fallback_code" => fallback} = @vectors["error_codes"]
    assert {map_size(jsonrpc), map_size(cyfr)} == {8, 17}

    for {name, code} <- Map.merge(jsonrpc, cyfr) do
      assert Message.code?(String.to_existing_atom(name)), name
      assert Message.error_code(String.to_existing_atom(name)) == code, name
    end

    assert Map.new(Message.cyfr_error_codes(), fn {name, code} -> {Atom.to_string(name), code} end) ==
             cyfr

    assert Message.error_code(:no_such_code_name) == fallback
    assert Message.encode_error(1, :no_such_code_name, "m")["error"]["code"] == fallback
  end

  test "the consent tags are the five signals, each answered with its own code" do
    tags = @vectors["consent_tags"]
    assert length(tags) == 5

    assert Enum.map(ConsentSignal.tags(), &Atom.to_string/1) == tags

    for tag <- tags do
      assert Message.error_code(String.to_existing_atom(tag)) ==
               @vectors["error_codes"]["cyfr"][tag]
    end
  end

  test "every consent error is produced as its whole response" do
    cases =
      "consent_errors"
      |> cases!(5, ~w(why tag response), ~w(payload data_stripped))
      |> Enum.reject(& &1["data_stripped"])

    # confirmation_required's error is confirmation.json's alone; every
    # other tag is a case here, once.
    assert Enum.map(cases, & &1["tag"]) == @vectors["consent_tags"] -- ["confirmation_required"]

    for vector <- cases do
      %{"why" => why, "tag" => tag, "payload" => payload, "response" => response} = vector
      signal = {String.to_existing_atom(tag), payload}
      assert ConsentSignal.signal?(signal), why

      code = Message.refusal_code(Refusal.classify(signal), :tools_call, nil)
      assert code == elem(signal, 0), why

      assert Message.encode_error(
               response["id"],
               code,
               ConsentSignal.message(signal),
               ConsentSignal.data(signal)
             ) == response,
             why
    end
  end

  test "every consent error response decodes as the error it carries" do
    for vector <- cases!("consent_errors", 5, ~w(why tag response), ~w(payload data_stripped)) do
      %{"why" => why, "response" => response} = vector
      expected = %Message{type: :error, id: response["id"], error: response["error"]}

      assert Message.decode(response) == {:ok, expected}, why
      assert Message.decode_json(Jason.encode!(response)) == {:ok, expected}, why
    end
  end
end
