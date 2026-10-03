# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.AttachedRequestTest do
  @moduledoc """
  An attached request as the worker service posts it: a canonical call id,
  a need name, a method, an absolute http or https URL, header pairs with
  no credential header, an optional base64 body within the wire's bound
  and a purpose. Each member outside its grammar is refused by name; a
  credential header, in any case, is refused as one; and what reads writes
  back to the same args.
  """

  use ExUnit.Case, async: true

  alias Prima.{AttachedRequest, HostAPI, Network}

  @call_id "AAECAwQFBgcICQoLDA0ODw"

  defp args(extra \\ %{}) do
    Map.merge(
      %{
        "call_id" => @call_id,
        "connection" => "api_key",
        "method" => "POST",
        "url" => "https://api.openai.com/v1/chat/completions",
        "headers" => [["content-type", "application/json"], ["accept", "text/event-stream"]],
        "body" => Base.encode64(~s({"model":"gpt-5"})),
        "body_encoding" => "base64",
        "purpose" => "stream"
      },
      extra
    )
  end

  test "reads to the request and writes back to the same args" do
    assert {:ok, request} = AttachedRequest.read(args())

    assert request == %AttachedRequest{
             call_id: @call_id,
             connection: "api_key",
             method: "POST",
             url: "https://api.openai.com/v1/chat/completions",
             headers: [{"content-type", "application/json"}, {"accept", "text/event-stream"}],
             body: ~s({"model":"gpt-5"}),
             purpose: :stream
           }

    assert AttachedRequest.to_args(request) == args()
  end

  test "an empty body is absent, with its encoding" do
    empty = args() |> Map.drop(["body", "body_encoding"]) |> Map.put("purpose", "fetch")

    assert {:ok, %AttachedRequest{body: "", purpose: :fetch} = request} =
             AttachedRequest.read(empty)

    assert AttachedRequest.to_args(request) == empty
  end

  test "headers keep their order and repeats" do
    headers = [["x-b", "1"], ["x-a", "2"], ["x-b", "3"]]
    assert {:ok, request} = AttachedRequest.read(args(%{"headers" => headers}))
    assert request.headers == [{"x-b", "1"}, {"x-a", "2"}, {"x-b", "3"}]
  end

  test "a header of the credential roster is refused by shape, in any case" do
    names =
      ["Authorization", "Cookie", "Proxy-Authorization", "authorization", "COOKIE"] ++
        Network.credential_headers() ++ Enum.map(Network.credential_headers(), &String.upcase/1)

    for name <- names do
      headers = [["content-type", "application/json"], [name, "Bearer sk-live"]]

      assert AttachedRequest.read(args(%{"headers" => headers})) ==
               {:error, :credential_header_refused},
             name

      assert Network.strip_credentials([{name, "v"}]) == [], name
    end
  end

  test "a header named only like a credential is the guest's own: the roster alone is refused" do
    for name <- ["Idempotency-Key", "X-Client-Secret", "X-Session-Token", "x-goog-api-key"] do
      headers = [["content-type", "application/json"], [name, "v"]]
      assert {:ok, request} = AttachedRequest.read(args(%{"headers" => headers})), name
      assert {name, "v"} in request.headers
    end
  end

  test "a header that routes or frames the request is refused by shape, naming it, in any case" do
    framing = [
      "Host",
      "Content-Length",
      "Transfer-Encoding",
      "Connection",
      "Keep-Alive",
      "TE",
      "Trailer",
      "Upgrade",
      "Proxy-Connection",
      "Expect"
    ]

    assert Enum.sort(Network.framing_headers()) ==
             Enum.sort(Enum.map(framing, &String.downcase/1))

    for header <- framing, name <- [header, String.downcase(header), String.upcase(header)] do
      headers = [["accept", "*/*"], [name, "evil.example"]]

      assert AttachedRequest.read(args(%{"headers" => headers})) ==
               {:error, {:invalid_request, name}},
             name
    end
  end

  test "a method, target or forwarded-origin override is refused, named, in any case" do
    override = [
      "X-HTTP-Method-Override",
      "X-HTTP-Method",
      "X-Method-Override",
      "X-Original-URL",
      "X-Rewrite-URL",
      "X-Original-Host",
      "X-Host",
      "X-Forwarded-Host",
      "X-Forwarded-Proto",
      "X-Forwarded-Port",
      "X-Forwarded-Prefix",
      "X-Forwarded-Server",
      "Forwarded"
    ]

    assert Enum.sort(Network.override_headers()) ==
             Enum.sort(Enum.map(override, &String.downcase/1))

    for header <- override, name <- [header, String.downcase(header), String.upcase(header)] do
      headers = [["accept", "*/*"], [name, "v1"]]

      assert AttachedRequest.read(args(%{"headers" => headers})) ==
               {:error, {:invalid_request, name}},
             name
    end
  end

  test "a header that is no pair of strings is refused, wherever it stands, and so is a method" do
    for headers <- [
          nil,
          [nil],
          [nil, ["Host", "evil.example"]],
          [nil, ["Authorization", "Bearer sk"]],
          [["accept", "*/*"], nil, ["x-a", "1"]],
          [["accept", nil]],
          [[nil, "v"]],
          [["accept", "*/*", "x"]]
        ] do
      assert AttachedRequest.read(args(%{"headers" => headers})) ==
               {:error, {:invalid_field, "headers"}},
             inspect(headers)
    end

    for method <- [nil, ["GET"], :GET] do
      assert AttachedRequest.read(args(%{"method" => method})) ==
               {:error, {:invalid_field, "method"}},
             inspect(method)
    end
  end

  test "an unknown purpose, a body past the wire's bound and a connection that is no need name" do
    for purpose <- ["redirect", "attached", "FETCH", nil, 1] do
      assert AttachedRequest.read(args(%{"purpose" => purpose})) ==
               {:error, {:invalid_field, "purpose"}},
             inspect(purpose)
    end

    over = Base.encode64(String.duplicate("a", HostAPI.max_body_bytes() + 1))
    assert AttachedRequest.read(args(%{"body" => over})) == {:error, :body_too_large}

    at_bound = Base.encode64(String.duplicate("a", HostAPI.max_body_bytes()))
    assert {:ok, _request} = AttachedRequest.read(args(%{"body" => at_bound}))

    for connection <- [
          "Api_Key",
          "1key",
          "",
          "api key",
          "@ingress",
          String.duplicate("a", 33),
          nil
        ] do
      assert AttachedRequest.read(args(%{"connection" => connection})) ==
               {:error, {:invalid_field, "connection"}},
             inspect(connection)
    end
  end

  test "a call id is 16 bytes as canonical unpadded base64url" do
    assert AttachedRequest.valid_call_id?(@call_id)
    assert AttachedRequest.call_id(:binary.list_to_bin(Enum.to_list(0..15))) == @call_id

    for bad <- [
          "AAECAwQFBgcICQoLDA0OD",
          "AAECAwQFBgcICQoLDA0ODw==",
          "AAECAwQFBgcICQoLDA0ODx",
          "AAECAwQFBgcICQoLDA0OD/",
          "AAECAwQFBgcICQoLDA0ODwAA",
          "",
          nil
        ] do
      refute AttachedRequest.valid_call_id?(bad), inspect(bad)

      assert AttachedRequest.read(args(%{"call_id" => bad})) ==
               {:error, {:invalid_field, "call_id"}}
    end
  end

  test "a method, a URL, headers and a body encoding outside their grammar" do
    for method <- ["TRACE", "get", "CONNECT"] do
      assert {:error, {:invalid_field, "method"}} =
               AttachedRequest.read(args(%{"method" => method}))
    end

    for url <- [
          "ftp://api.openai.com/",
          "/v1/chat",
          "https:///x",
          "https://api.openai.com/a b",
          "https://ok.test/\n"
        ] do
      assert {:error, {:invalid_field, "url"}} = AttachedRequest.read(args(%{"url" => url})), url
    end

    for headers <- [
          [["bad name", "v"]],
          [["x", "a\nb"]],
          [["x"]],
          [%{"x" => "v"}],
          %{"x" => "v"},
          Enum.map(1..129, &["x-#{&1}", "v"])
        ] do
      assert {:error, {:invalid_field, "headers"}} =
               AttachedRequest.read(args(%{"headers" => headers}))
    end

    assert {:error, {:invalid_field, "body_encoding"}} =
             AttachedRequest.read(args(%{"body_encoding" => "utf8"}))

    assert {:error, {:missing_field, "body_encoding"}} =
             AttachedRequest.read(Map.delete(args(), "body_encoding"))

    assert {:error, {:invalid_field, "body"}} = AttachedRequest.read(args(%{"body" => "!!"}))
    assert {:error, {:invalid_field, "body"}} = AttachedRequest.read(args(%{"body" => ""}))
  end

  test "a member missing, or one it does not carry, is refused by name" do
    for member <- ~w(call_id connection method url headers purpose) do
      assert AttachedRequest.read(Map.delete(args(), member)) ==
               {:error, {:missing_field, member}}
    end

    assert AttachedRequest.read(args(%{"pin" => "pin_1"})) == {:error, {:unknown_field, "pin"}}
    assert AttachedRequest.read("args") == {:error, :not_a_map}
  end

  test "an attached request's own pin is recorded as its own kind, which no runner asks for" do
    refute :attached in Prima.PinnedTarget.purposes()

    assert Prima.PinnedTarget.read_request(%{"url" => "https://x.test/", "purpose" => "attached"}) ==
             {:error, :malformed}
  end
end
