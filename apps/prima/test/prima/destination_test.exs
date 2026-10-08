# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.DestinationTest do
  @moduledoc """
  Where a credential's material may go: hosts in the egress domain
  grammar, the scheme, the port, the methods and the path prefixes. A
  destination reads to one canonical spelling and back, refuses each
  malformed member with its own reason, and admits a request only inside
  every bound it names, its path compared segment by segment after the
  path grammar refused what an upstream could normalize elsewhere.
  """

  use ExUnit.Case, async: true

  alias Prima.Destination

  defp new!(map, required \\ false) do
    {:ok, destination} = Destination.new(map, required)
    destination
  end

  defp refused(map, required \\ false) do
    assert {:error, {:invalid_destination, reason}} = Destination.new(map, required)
    reason
  end

  describe "new/2 and the canonical form" do
    test "normalizes hosts, scheme, methods and paths, and round-trips" do
      destination =
        new!(%{
          "hosts" => ["API.openai.com", "api.openai.com", "*.Googleapis.com"],
          "methods" => ["post", "GET", "POST"],
          "paths" => ["/v1/models", "/v1/chat/completions", "/v1/models"],
          "port" => 8443
        })

      assert destination == %Destination{
               hosts: ["*.googleapis.com", "api.openai.com"],
               scheme: "https",
               port: 8443,
               methods: ["GET", "POST"],
               paths: ["/v1/chat/completions", "/v1/models"]
             }

      map = Destination.to_map(destination)

      assert map == %{
               "hosts" => ["*.googleapis.com", "api.openai.com"],
               "scheme" => "https",
               "port" => 8443,
               "methods" => ["GET", "POST"],
               "paths" => ["/v1/chat/completions", "/v1/models"]
             }

      assert Destination.from_map(map) == {:ok, destination}
    end

    test "writes the scheme always and the optional members only when present" do
      destination = new!(%{"hosts" => ["api.example.com"]})

      assert Destination.to_map(destination) == %{
               "hosts" => ["api.example.com"],
               "scheme" => "https"
             }

      assert Destination.from_map(Destination.to_map(destination)) == {:ok, destination}

      assert new!(%{"hosts" => ["localhost"], "scheme" => "HTTP", "port" => nil}).scheme == "http"
    end

    test "its canonical bytes are the JCS of its map" do
      destination = new!(%{"hosts" => ["b.example.com", "a.example.com"], "paths" => ["/x"]})

      assert Destination.canonical(destination) ==
               ~s({"hosts":["a.example.com","b.example.com"],"paths":["/x"],"scheme":"https"})
    end
  end

  describe "refusals" do
    test "a destination with no host" do
      assert refused(%{}) == :hosts_required
      assert refused(%{"hosts" => []}) == :hosts_required
      assert refused(%{"hosts" => "api.example.com"}) == {:invalid_list, "hosts"}
    end

    test "a bare wildcard, a host with a scheme, a port or a path, and other non-hosts" do
      for host <- [
            "*",
            "*.",
            "*.com",
            "https://api.example.com",
            "api.example.com:443",
            "api.example.com/v1",
            "api.example.com.",
            "api..example.com",
            "-api.example.com",
            "api example.com",
            "[::1]",
            "",
            7
          ] do
        assert refused(%{"hosts" => [host]}) == {:invalid_host, host}, inspect(host)
      end
    end

    test "a scheme other than http or https" do
      for scheme <- ["ftp", "wss", "", 443] do
        assert refused(%{"hosts" => ["a.example.com"], "scheme" => scheme}) ==
                 {:invalid_scheme, scheme}
      end
    end

    test "a port outside 1..65535" do
      for port <- [0, 65_536, -1, "443", 443.0] do
        assert refused(%{"hosts" => ["a.example.com"], "port" => port}) == {:invalid_port, port}
      end
    end

    test "a method outside the vocabulary, and an empty list" do
      assert refused(%{"hosts" => ["a.example.com"], "methods" => ["TRACE"]}) ==
               {:invalid_method, "TRACE"}

      assert refused(%{"hosts" => ["a.example.com"], "methods" => []}) == {:empty, "methods"}
      assert refused(%{"hosts" => ["a.example.com"], "paths" => []}) == {:empty, "paths"}
    end

    test "a path not beginning with /, or an encoded dot or separator, or a dot or empty segment" do
      for path <- [
            "v1/models",
            "",
            "/v1//models",
            "/v1/./models",
            "/v1/../admin",
            "/..",
            "/v1/%2e%2e/admin",
            "/v1/%2E/x",
            "/v1%2fadmin",
            "/v1%5Cadmin",
            "/v1\\admin",
            "/v1?x=1",
            "/v1#frag",
            "/v1/%zz",
            "/v1 models",
            "//",
            "/v1/models/..;/files",
            "/v1;jsessionid=1",
            ";",
            "/v1/%3b/x",
            "/v1/%3B",
            "/v1/models%3Bx",
            "/v1/%252e",
            "/v1/%252e%252e/x",
            "/v1/%253b",
            "/v1/%c0%ae",
            "/v1/%C0%AE%C0%AE/x",
            "/v1/%C1",
            "/v1/%c1%9c"
          ] do
        assert refused(%{"hosts" => ["a.example.com"], "paths" => [path]}) ==
                 {:invalid_path, path},
               inspect(path)
      end
    end

    test "a host, method or path that is no string, wherever it stands" do
      for hosts <- [[nil], [nil, "*"], ["a.example.com", nil, "b.example.com"]] do
        assert refused(%{"hosts" => hosts}) == {:invalid_host, nil}, inspect(hosts)
      end

      for paths <- [[nil], [nil, "/v1/../admin"], ["/v1/a", nil, "/v1/b"]] do
        assert refused(%{"hosts" => ["a.example.com"], "paths" => paths}) == {:invalid_path, nil},
               inspect(paths)
      end

      for methods <- [[nil], [nil, "BREW"], ["GET", nil, "POST"]] do
        assert refused(%{"hosts" => ["a.example.com"], "methods" => methods}) ==
                 {:invalid_method, nil},
               inspect(methods)
      end
    end

    test "more than 32 hosts or 32 paths" do
      hosts = Enum.map(1..33, &"h#{&1}.example.com")
      paths = Enum.map(1..33, &"/p#{&1}")

      assert refused(%{"hosts" => hosts}) == {:too_many, "hosts"}
      assert refused(%{"hosts" => ["a.example.com"], "paths" => paths}) == {:too_many, "paths"}

      assert {:ok, %Destination{hosts: kept}} =
               Destination.new(%{"hosts" => Enum.take(hosts, 32)}, false)

      assert length(kept) == 32

      assert {:ok, %Destination{paths: kept}} =
               Destination.new(
                 %{"hosts" => ["a.example.com"], "paths" => Enum.take(paths, 32)},
                 false
               )

      assert length(kept) == 32
    end

    test "an instance destination without methods or paths" do
      host = %{"hosts" => ["a.example.com"]}
      assert refused(host, true) == {:required, "methods"}
      assert refused(Map.put(host, "methods", ["GET"]), true) == {:required, "paths"}

      assert {:ok, _} =
               Destination.new(Map.merge(host, %{"methods" => ["GET"], "paths" => ["/"]}), true)

      assert {:ok, _} = Destination.new(host, false)
    end

    test "an unknown member, and a value that is no map" do
      assert refused(%{"hosts" => ["a.example.com"], "query" => "x"}) == {:unknown_key, "query"}
      assert refused("api.example.com") == :not_a_map
      assert refused(nil) == :not_a_map
    end
  end

  describe "matches?/3" do
    setup do
      %{
        inference:
          new!(
            %{
              "hosts" => ["api.openai.com"],
              "methods" => ["GET", "POST"],
              "paths" => ["/v1/chat/completions", "/v1/models"]
            },
            true
          )
      }
    end

    test "admits a request inside every bound", %{inference: d} do
      assert Destination.matches?(d, URI.parse("https://api.openai.com/v1/models"), "GET")
      assert Destination.matches?(d, URI.parse("https://api.openai.com/v1/models/gpt-5"), "get")

      assert Destination.matches?(
               d,
               URI.parse("https://API.openai.com:443/v1/chat/completions?stream=1"),
               "POST"
             )

      assert Destination.matches?(d, URI.parse("https://api.openai.com/v1/models/"), "GET")
    end

    test "refuses another path, scheme, port, host or method", %{inference: d} do
      for {url, method} <- [
            {"https://api.openai.com/v1/files", "GET"},
            {"https://api.openai.com/v1/models-x", "GET"},
            {"https://api.openai.com/v1", "GET"},
            {"https://api.openai.com/", "GET"},
            {"https://api.openai.com", "GET"},
            {"http://api.openai.com/v1/models", "GET"},
            {"https://api.openai.com:8443/v1/models", "GET"},
            {"https://evil.openai.com/v1/models", "GET"},
            {"https://api.openai.com.evil.test/v1/models", "GET"},
            {"https://api.openai.com/v1/models", "DELETE"},
            {"https://api.openai.com/v1/models", "TRACE"},
            {"https://user:pw@api.openai.com/v1/models", "GET"}
          ] do
        refute Destination.matches?(d, URI.parse(url), method), "#{method} #{url}"
      end

      refute Destination.matches?(d, URI.parse("https://api.openai.com/v1/models"), nil)
    end

    test "refuses a request path that fails the path grammar", %{inference: d} do
      for path <- [
            "/v1/models/../files",
            "/v1/models/./x",
            "/v1/models//x",
            "/v1/models/%2e%2e/files",
            "/v1/models%2F..%2Ffiles",
            "/v1/models/%5c..",
            "/v1/models/%zz",
            "/v1/models/..;/files",
            "/v1/models;jsessionid=1",
            "/v1/models/%3Bx",
            "/v1/models/%3bx",
            "/v1/models/%252e",
            "/v1/models/%252e%252e/files",
            "/v1/models%253bx",
            "/v1/models/%c0%ae",
            "/v1/models/%C1"
          ] do
        refute Destination.matches?(d, URI.parse("https://api.openai.com" <> path), "GET"), path
      end
    end

    test "with no methods or paths admits any of them, and a wildcard host the names below it" do
      d = new!(%{"hosts" => ["*.googleapis.com"], "scheme" => "https"})

      assert Destination.matches?(d, URI.parse("https://www.googleapis.com/any/path"), "DELETE")
      assert Destination.matches?(d, URI.parse("https://a.b.googleapis.com"), "PATCH")
      refute Destination.matches?(d, URI.parse("https://googleapis.com/"), "GET")
      refute Destination.matches?(d, URI.parse("https://www.googleapis.com/a/../b"), "GET")

      for path <- ["/a/%252e%252e/b", "/a/%253b", "/a/%c0%ae", "/a/%C1"] do
        refute Destination.matches?(d, URI.parse("https://www.googleapis.com" <> path), "GET"),
               path
      end

      root = new!(%{"hosts" => ["h.example.com"], "paths" => ["/"]})
      assert Destination.matches?(root, URI.parse("https://h.example.com/anything/at/all"), "GET")
    end

    test "an explicit port and the http scheme's default" do
      d = new!(%{"hosts" => ["127.0.0.1"], "scheme" => "http", "port" => 8443})
      assert Destination.matches?(d, URI.parse("http://127.0.0.1:8443/x"), "GET")
      refute Destination.matches?(d, URI.parse("http://127.0.0.1/x"), "GET")

      default = new!(%{"hosts" => ["127.0.0.1"], "scheme" => "http"})
      assert Destination.matches?(default, URI.parse("http://127.0.0.1/x"), "GET")
      assert Destination.matches?(default, URI.parse("http://127.0.0.1:80/x"), "GET")
      refute Destination.matches?(default, URI.parse("https://127.0.0.1/x"), "GET")
    end
  end

  describe "the grammar's predicates" do
    test "valid_host? and valid_path? answer the grammar new/2 holds" do
      assert Destination.valid_host?("api.example.com")
      assert Destination.valid_host?("*.example.com")
      refute Destination.valid_host?("API.example.com")
      refute Destination.valid_host?("*")

      assert Destination.valid_path?("/")
      assert Destination.valid_path?("/v1/models/")
      refute Destination.valid_path?("/v1/%2E%2E")
      refute Destination.valid_path?(nil)
    end

    test "the method vocabulary" do
      assert Destination.methods() == ~w(DELETE GET HEAD OPTIONS PATCH POST PUT)
    end
  end
end
