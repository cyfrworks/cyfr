# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.NeedsTest do
  @moduledoc """
  A credential need names how its value is attached (`attach`), where it
  is sent (`hosts`, `paths`) and whether the component reads it itself
  (`disclose`). A need without `attach` is disclose-only, OAuth included;
  an OAuth need whose rule names no template takes the bearer header; a
  rule's template holds `{value}` once and its header name is a token; a
  component-typed need takes none of the four.
  """

  use ExUnit.Case, async: true

  alias Prima.Manifest.Needs

  defp manifest(entry), do: %{"needs" => %{"api_key" => entry}}

  defp need(extra \\ %{}),
    do: Map.merge(%{"type" => "api_key:openai.com", "reason" => "to call OpenAI"}, extra)

  defp normalized(entry) do
    [need] = Needs.from_manifest(manifest(entry))
    need
  end

  defp refused(entry) do
    assert {:error, {:invalid_needs, reason}} = Needs.validate(manifest(entry))
    reason
  end

  describe "attach" do
    test "a header rule, a query rule, and a need that both attaches and discloses" do
      header = %{"in" => "header", "name" => "x-api-key", "template" => "{value}"}

      assert normalized(need(%{"attach" => header})).attach ==
               %{in: "header", name: "x-api-key", template: "{value}"}

      query = %{"in" => "query", "name" => "key", "template" => "{value}"}
      assert normalized(need(%{"attach" => query})).attach.in == "query"

      both = normalized(need(%{"attach" => header, "disclose" => true}))
      assert both.disclose and not Needs.disclose_only?(both)
    end

    test "a need without attach is disclose-only, OAuth included" do
      plain = normalized(need())
      assert plain.attach == nil and Needs.disclose_only?(plain)
      assert plain.disclose == false

      oauth = normalized(%{"type" => "oauth:google", "reason" => "r", "scopes" => ["a"]})
      assert oauth.attach == nil and Needs.disclose_only?(oauth)

      assert normalized(need(%{"attach" => nil})).attach == nil
    end

    test "an OAuth need's rule without a template takes the bearer header" do
      bearer = %{in: "header", name: "Authorization", template: "Bearer {value}"}
      oauth = %{"type" => "oauth:google", "reason" => "r"}

      assert normalized(Map.put(oauth, "attach", %{})).attach == bearer

      assert normalized(Map.put(oauth, "attach", %{"in" => "header", "name" => "Authorization"})).attach ==
               bearer

      assert {:invalid_attach, "api_key", :template_required} =
               refused(Map.put(oauth, "attach", %{"in" => "query", "name" => "access_token"}))

      # Only an OAuth need's template defaults.
      assert {:invalid_attach, "api_key", :malformed_attach} = refused(need(%{"attach" => %{}}))
    end

    test "a template without {value}, with it twice, or with a control character is refused" do
      for template <- [
            "Bearer",
            "{value}{value}",
            "{value} and {value}",
            "Bearer {value}\r\nX: y",
            ""
          ] do
        rule = %{"in" => "header", "name" => "Authorization", "template" => template}

        assert {:invalid_attach, "api_key", {:invalid_template, ^template}} =
                 refused(need(%{"attach" => rule})),
               inspect(template)
      end
    end

    test "a header name that is not a token, a query key outside the unreserved set" do
      for name <- ["x api key", "x-api-key:", "", "x\nkey", "é"] do
        rule = %{"in" => "header", "name" => name, "template" => "{value}"}

        assert {:invalid_attach, "api_key", {:invalid_name, ^name}} =
                 refused(need(%{"attach" => rule}))
      end

      for name <- ["a&b", "a=b", "a b", ""] do
        rule = %{"in" => "query", "name" => name, "template" => "{value}"}

        assert {:invalid_attach, "api_key", {:invalid_name, ^name}} =
                 refused(need(%{"attach" => rule}))
      end
    end

    test "a header that routes or frames a request is no rule's header, in any case" do
      for name <- [
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
          ],
          spelled <- [name, String.downcase(name), String.upcase(name)] do
        rule = %{"in" => "header", "name" => spelled, "template" => "{value}"}

        assert {:invalid_attach, "api_key", {:reserved_header, ^spelled}} =
                 refused(need(%{"attach" => rule})),
               spelled
      end

      # A query key of that spelling is no header.
      rule = %{"in" => "query", "name" => "host", "template" => "{value}"}
      assert %{attach: %{in: "query", name: "host"}} = normalized(need(%{"attach" => rule}))
    end

    test "a method, target or forwarded-origin override is no rule's header, in any case" do
      for name <- [
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
          ],
          spelled <- [name, String.downcase(name), String.upcase(name)] do
        rule = %{"in" => "header", "name" => spelled, "template" => "{value}"}

        assert {:invalid_attach, "api_key", {:reserved_header, ^spelled}} =
                 refused(need(%{"attach" => rule})),
               spelled
      end
    end

    test "an unknown place, an unknown member and a rule that is no object" do
      rule = %{"in" => "body", "name" => "k", "template" => "{value}"}

      assert {:invalid_attach, "api_key", {:invalid_in, "body"}} =
               refused(need(%{"attach" => rule}))

      extra = %{"in" => "header", "name" => "k", "template" => "{value}", "prefix" => "x"}

      assert {:invalid_attach, "api_key", {:unknown_keys, ["prefix"]}} =
               refused(need(%{"attach" => extra}))

      assert {:invalid_attach, "api_key", :malformed_attach} =
               refused(need(%{"attach" => "Authorization: Bearer {value}"}))
    end

    test "render_attach places the value where the template holds {value}" do
      rule = %{in: "header", name: "Authorization", template: "Bearer {value}"}
      assert Needs.render_attach(rule, "sk-1") == "Bearer sk-1"
      assert Needs.render_attach(%{rule | template: "{value}"}, "{value}") == "{value}"
    end

    test "read_attach reads a wire rule whole, with no default" do
      wire = %{"in" => "header", "name" => "Authorization", "template" => "Bearer {value}"}
      assert {:ok, rule} = Needs.read_attach(wire)
      assert Needs.attach_to_map(rule) == wire
      assert {:error, :malformed_attach} = Needs.read_attach(Map.delete(wire, "template"))
      assert {:error, :malformed_attach} = Needs.read_attach(nil)
      assert {:error, {:invalid_template, "x"}} = Needs.read_attach(%{wire | "template" => "x"})
    end
  end

  describe "hosts, paths and disclose" do
    test "are read, the lists de-duplicated and sorted" do
      read =
        normalized(
          need(%{
            "hosts" => ["b.example.com", "*.example.com", "b.example.com"],
            "paths" => ["/v1/b", "/v1/a"],
            "disclose" => true
          })
        )

      assert read.hosts == ["*.example.com", "b.example.com"]
      assert read.paths == ["/v1/a", "/v1/b"]
      assert read.disclose
      assert normalized(need()).hosts == [] and normalized(need()).paths == []
    end

    test "a host or a path outside the destination grammar is refused" do
      for host <- ["*", "https://api.example.com", "api.example.com/v1", "API.example.com"] do
        assert {:invalid_host, "api_key", ^host} = refused(need(%{"hosts" => [host]}))
      end

      for path <- [
            "v1",
            "/v1/../x",
            "/v1//x",
            "/v1/%2e%2e",
            "/v1/%2F",
            "/v1/./x",
            "/v1/models/..;/files",
            "/v1;x",
            "/v1/%3b",
            "/v1/%3B/x",
            "/v1/%252e",
            "/v1/%253b",
            "/v1/%c0%ae",
            "/v1/%C1"
          ] do
        assert {:invalid_path, "api_key", ^path} = refused(need(%{"paths" => [path]}))
      end

      assert {:invalid_list, "api_key", :hosts} = refused(need(%{"hosts" => []}))
      assert {:invalid_list, "api_key", :paths} = refused(need(%{"paths" => "/v1"}))
      assert {:invalid_disclose, "api_key", "yes"} = refused(need(%{"disclose" => "yes"}))
    end

    test "a host or a path that is no string is refused as itself, wherever it stands" do
      for {hosts, bad} <- [
            {[nil], nil},
            {[nil, "API.example.com"], nil},
            {["a.example.com", nil, "b.example.com"], nil},
            {["a.example.com", false], false},
            {["a.example.com", 1], 1}
          ] do
        entry = need(%{"hosts" => hosts})
        assert {:invalid_host, "api_key", ^bad} = refused(entry), inspect(hosts)
        assert Needs.from_manifest(manifest(entry)) == nil
      end

      for {paths, bad} <- [
            {[nil], nil},
            {[nil, "/v1/../admin"], nil},
            {["/v1/a", nil, "/v1/b"], nil},
            {["/v1/a", false], false},
            {[:"/v1"], :"/v1"}
          ] do
        entry = need(%{"paths" => paths})
        assert {:invalid_path, "api_key", ^bad} = refused(entry), inspect(paths)
        assert Needs.from_manifest(manifest(entry)) == nil
      end
    end

    test "more than 32 distinct hosts or 32 distinct paths, a destination's own bound" do
      hosts = Enum.map(1..33, &"h#{&1}.example.com")
      paths = Enum.map(1..33, &"/p#{&1}")

      assert {:too_many, "api_key", :hosts} = refused(need(%{"hosts" => hosts}))
      assert {:too_many, "api_key", :paths} = refused(need(%{"paths" => paths}))

      # 32 distinct entries, spelled once each or with a repeat, are read.
      for {hosts, paths} <- [
            {Enum.take(hosts, 32), Enum.take(paths, 32)},
            {Enum.take(hosts, 32) ++ ["h1.example.com"], Enum.take(paths, 32) ++ ["/p1"]}
          ] do
        read = normalized(need(%{"hosts" => hosts, "paths" => paths}))
        assert length(read.hosts) == 32 and length(read.paths) == 32

        assert {:ok, %Prima.Destination{}} =
                 Prima.Destination.new(%{"hosts" => read.hosts, "paths" => read.paths}, false)
      end

      assert Prima.Destination.max_entries() == 32
    end

    test "a component-typed need takes none of the credential members" do
      for key <- ["attach", "hosts", "paths", "disclose"] do
        entry = %{"type" => "catalyst:local.files", "reason" => "r", key => nil}
        assert {:not_a_credential, "api_key", [^key]} = refused(entry)
      end
    end
  end
end
