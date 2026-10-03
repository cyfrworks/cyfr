# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.NetworkPureTest do
  use ExUnit.Case, async: true

  alias Prima.Network

  test "URL parsing refuses invalid destinations without resolution" do
    for {url, message} <- [
          {"//example.test/x", "missing URL scheme"},
          {"file:///etc/passwd", "blocked URL scheme: file"},
          {"https:///x", "missing hostname"}
        ] do
      assert {:error, :invalid_url, ^message} = Network.parse_url(url)
    end
  end

  test "pinning uses the supplied address and retains URL and TLS identity" do
    {:ok, uri} = Network.parse_url("https://example.test:8443/path?q=1")
    ip = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

    assert {:ok, %{uri: ^uri, ip_tuple: ^ip, req_opts: opts}} =
             Network.pin(uri, ip,
               receive_timeout: 71,
               protocols: [:http1],
               transport_opts: [verify: :verify_peer]
             )

    assert opts[:url] == "https://[2001:db8::1]:8443/path?q=1"
    assert opts[:connect_options][:hostname] == "example.test"
    assert opts[:connect_options][:protocols] == [:http1]
    assert opts[:connect_options][:transport_opts] == [verify: :verify_peer]

    assert opts[:receive_timeout] == 71

    for option <- [:redirect, :retry, :compressed, :decode_body],
        do: assert(opts[option] == false)
  end

  test "private addresses need an explicit policy and match only explicit targets" do
    {:ok, uri} = Network.parse_url("http://service.internal/")
    ip = {10, 1, 2, 3}
    assert {:error, :private_ip_blocked, _} = Network.pin(uri, ip, [])
    assert {:error, :private_ip_blocked, _} = Network.pin(uri, ip, private_policy: :operator)

    for policy <- [
          :allow_all,
          {:allowlist, ["SERVICE.internal"]},
          {:allowlist, ["10.0.0.0/8"]},
          {:fun, fn address -> address == ip end}
        ] do
      assert {:ok, _} = Network.pin(uri, ip, private_policy: policy)
    end

    refute Network.private_allowed?(uri.host, ip, [])
    refute Network.private_allowed?(uri.host, ip, ["service.internal.evil", "192.168.0.0/16"])
    assert Network.private_allowed?(nil, ip, ["10.1.2.3"])
  end

  test "metadata refusals precede every override, including embedded IPv4" do
    {:ok, uri} = Network.parse_url("https://metadata.test/")

    for literal <- [
          "169.254.169.254",
          "100.100.100.200",
          "fd00:ec2::254",
          "64:ff9b::a9fe:a9fe",
          "2002:a9fe:a9fe::1"
        ] do
      {:ok, ip} = Prima.Cidr.parse_ip(literal)

      for policy <- [
            :allow_all,
            {:allowlist, ["metadata.test", "0.0.0.0/0", "::/0"]},
            {:fun, fn _ -> flunk("metadata reached the policy override") end}
          ] do
        assert {:error, :private_ip_blocked, message} =
                 Network.pin(uri, ip, private_policy: policy)

        assert message =~ "metadata IP"
      end
    end
  end

  describe "same_origin?/2" do
    test "compares scheme and host case-folded, and the effective port" do
      for {a, b} <- [
            {"https://api.example.test/a", "https://api.example.test/b?q=1"},
            {"HTTPS://API.Example.TEST/a", "https://api.example.test/b"},
            {"https://api.example.test./a", "https://api.example.test/b"},
            {"https://api.example.test/a", "https://api.example.test:443/b"},
            {"http://api.example.test/a", "http://api.example.test:80/b"},
            {"http://[::1]/a", "http://[0:0:0:0:0:0:0:1]:80/b"},
            {"http://[2001:DB8::20]:8080/", "http://[2001:0db8:0:0:0:0:0:20]:8080/"},
            {URI.parse("https://api.example.test/a"), "https://api.example.test/b"},
            {%URI{scheme: "HTTP", host: "[::1]"}, "http://[::1]/"},
            {"ftp://files.example.test:2121/a", "ftp://files.example.test:2121/b"}
          ] do
        assert Network.same_origin?(a, b), inspect({a, b})
        assert Network.same_origin?(b, a), inspect({b, a})
      end
    end

    test "tells another scheme, host or port apart" do
      for {a, b} <- [
            {"https://api.example.test/", "https://api.example.test:8443/"},
            {"https://api.example.test/", "http://api.example.test/"},
            {"http://api.example.test:443/", "https://api.example.test/"},
            {"https://api.example.test/", "https://login.example.test/"},
            {"https://api.example.test/", "https://api.example.test../"},
            {"https://example.test/", "https://aexample.test/"},
            {"http://[::1]/", "http://[::2]/"},
            {"http://127.0.0.1/", "http://[::ffff:127.0.0.1]/"}
          ] do
        refute Network.same_origin?(a, b), inspect({a, b})
      end
    end

    test "answers false for anything malformed, even against itself" do
      for url <- [
            "not a url",
            "//api.example.test/x",
            "http://",
            "http://[::1",
            "http://[fe80::1%25eth0]/",
            "http://api.example.test:0/",
            "https://api.example.test:99999/",
            "ftp://files.example.test/",
            "http://./",
            %URI{scheme: "http", host: nil},
            %URI{scheme: nil, host: "api.example.test", port: 80},
            %URI{scheme: "gopher", host: "api.example.test"},
            %URI{scheme: "http", host: "not:an:address"},
            nil,
            42
          ] do
        refute Network.same_origin?(url, url), inspect(url)
        refute Network.same_origin?(url, "http://api.example.test/"), inspect(url)
      end
    end
  end

  describe "credential headers" do
    test "are the fixed roster and any name ending -token, -key or -secret, in any case" do
      assert Network.credential_headers() ==
               ~w(authorization cookie proxy-authorization x-api-key x-auth-token
                  x-access-token x-csrf-token)

      for name <-
            Network.credential_headers() ++
              ~w(Authorization COOKIE Proxy-Authorization X-API-Key X-CSRF-Token
                 x-session-token X-Signing-KEY X-Client-Secret -token) do
        assert Network.credential_header?(name), name
      end

      for name <-
            ~w(accept user-agent x-monkey x-tokenizer x-secrets x-keys keyboard token key
               secret x-token-id content-type) ++ [nil, :authorization, 42] do
        refute Network.credential_header?(name), inspect(name)
      end
    end

    test "are stripped from a header list, the rest kept in order" do
      headers = [
        {"Accept", "application/json"},
        {"Authorization", "Bearer vector"},
        {"X-Monkey", "kept"},
        {"cookie", "session=vector"},
        {"X-API-KEY", "vector"},
        {"User-Agent", "cyfr-vector"},
        {"X-Refresh-Token", "vector"},
        {:authorization, "not a header name"},
        :not_a_pair
      ]

      assert Network.strip_credentials(headers) == [
               {"Accept", "application/json"},
               {"X-Monkey", "kept"},
               {"User-Agent", "cyfr-vector"},
               {:authorization, "not a header name"},
               :not_a_pair
             ]

      assert Network.strip_credentials([]) == []
    end
  end

  describe "domain_allowed?/2" do
    test "matches *, a whole-label wildcard or the exact name, case-folded" do
      for {host, patterns} <- [
            {"api.example.test", ["*"]},
            {"api.example.test", ["api.example.test"]},
            {"API.Example.Test", ["api.example.test"]},
            {"api.example.test", ["API.EXAMPLE.TEST"]},
            {"api.example.test.", ["api.example.test"]},
            {"api.example.test", ["api.example.test."]},
            {"a.example.test", ["*.example.test"]},
            {"a.b.example.test", ["*.example.test"]},
            {"A.Example.TEST.", ["*.EXAMPLE.test"]},
            {"a.example.test", ["*.example.test."]},
            {"a.example.test", ["other.test", "*.example.test"]},
            {"2001:db8::20", ["2001:DB8::20"]}
          ] do
        assert Network.domain_allowed?(host, patterns), inspect({host, patterns})
      end
    end

    test "matches no partial label, no parent, no empty host and no empty list" do
      for {host, patterns} <- [
            {"example.test", ["*.example.test"]},
            {"aexample.test", ["*.example.test"]},
            {"example.test.evil", ["*.example.test"]},
            {"api.example.test", ["example.test"]},
            {"api.example.test", ["*example.test"]},
            {"api.example.test", ["*."]},
            {"api.example.test", ["", "*.", "api.*.test"]},
            {"api.example.test", []},
            {"api.example.test..", ["api.example.test"]},
            {"", ["*"]},
            {".", ["*"]},
            {nil, ["*"]},
            {"api.example.test", nil}
          ] do
        refute Network.domain_allowed?(host, patterns), inspect({host, patterns})
      end
    end
  end
end
