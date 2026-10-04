# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.ShapeDigestTest do
  use ExUnit.Case, async: true

  alias Sanctum.Consent.ShapeDigest

  doctest Sanctum.Consent.ShapeDigest

  @base %{scope: :versionless, source_ref: "formula:local.daily-report"}

  defp digest!(shape) do
    {:ok, digest} = ShapeDigest.compute(shape)
    digest
  end

  describe "compute/1" do
    test "a minimal shape digests" do
      assert "sha256:" <> _ = digest!(@base)
    end

    test "every shape field changes the digest" do
      variants = [
        %{scope: :pinned, release_identity: "sha256:act"},
        %{source_ref: "formula:local.other"},
        %{needs: [%{name: "source", type: "catalyst:supabase.com.database"}]},
        %{caps: %{"allowed_domains" => ["a.example"]}},
        %{tool_actions: ["storage.read"]},
        %{slots: ["source"]},
        %{tool_policy: %{auto: ["http.get"], ask: ["files.read"]}}
      ]

      for variant <- variants do
        shape = Map.merge(@base, variant)
        assert digest!(@base) != digest!(shape), "#{inspect(variant)} did not affect the digest"
      end
    end

    test "presentation-only differences do not change the digest" do
      # Order carries no meaning in a grant.
      a =
        Map.merge(@base, %{tool_actions: ["storage.read", "component.search"], slots: ["b", "a"]})

      b =
        Map.merge(@base, %{tool_actions: ["component.search", "storage.read"], slots: ["a", "b"]})

      assert digest!(a) == digest!(b)

      assert digest!(
               Map.put(@base, :tool_policy, %{
                 auto: ["http.post", "http.get"],
                 ask: ["files.read"]
               })
             ) ==
               digest!(
                 Map.put(@base, :tool_policy, %{
                   auto: ["http.get", "http.post"],
                   ask: ["files.read"]
                 })
               )

      # Nor does the prose shown to the operator.
      with_reason = %{name: "source", type: "catalyst:local.db", reason: "to read orders"}

      assert {:error, {:invalid_shape, :unknown_field, _}} =
               ShapeDigest.compute(Map.put(@base, :needs, [with_reason]))
    end

    test "duplicate entries collapse" do
      once = Map.put(@base, :tool_actions, ["storage.read"])
      twice = Map.put(@base, :tool_actions, ["storage.read", "storage.read"])

      assert digest!(once) == digest!(twice)
    end
  end

  # Tool-group stability

  describe "tool-group stability" do
    test "a group name is structurally unrepresentable" do
      # Adding an action to a group upstream must not widen an existing
      # consent. The defence is that no input here can name a group at all.
      for not_a_pair <- ["storage", "storage.*", "*", "storage.read.extra", "", "*.read"] do
        assert {:error, {:invalid_shape, :tool_actions, _}} =
                 ShapeDigest.compute(Map.put(@base, :tool_actions, [not_a_pair])),
               "#{inspect(not_a_pair)} was accepted as a capability"
      end
    end

    test "identical expanded lists digest identically regardless of how they were grouped" do
      # Two consents that expand to the same pairs ARE the same capability,
      # whatever grouping produced them upstream.
      from_group = Map.put(@base, :tool_actions, ["storage.read", "storage.write"])
      from_pairs = Map.put(@base, :tool_actions, ["storage.write", "storage.read"])

      assert digest!(from_group) == digest!(from_pairs)
    end

    test "adding an action changes the digest" do
      narrow = Map.put(@base, :tool_actions, ["storage.read"])
      wide = Map.put(@base, :tool_actions, ["storage.read", "storage.delete"])

      assert digest!(narrow) != digest!(wide)
    end
  end

  # ============================================================================
  # Scope / release identity
  # ============================================================================

  describe "scope and release identity" do
    test "pinned requires a release identity; versionless forbids one" do
      assert {:error, {:invalid_shape, :release_identity, message}} =
               ShapeDigest.compute(Map.put(@base, :scope, :pinned))

      assert message =~ "required"

      assert {:error, {:invalid_shape, :release_identity, message}} =
               ShapeDigest.compute(Map.put(@base, :release_identity, "sha256:act"))

      assert message =~ "absent"

      assert {:ok, _} =
               ShapeDigest.compute(
                 %{@base | scope: :pinned}
                 |> Map.put(:release_identity, "sha256:act")
               )
    end

    test "a pinned consent's digest follows its release identity" do
      pinned = fn digest ->
        @base |> Map.merge(%{scope: :pinned, release_identity: digest})
      end

      assert digest!(pinned.("sha256:one")) != digest!(pinned.("sha256:two"))
    end
  end

  # ============================================================================
  # Input validation
  # ============================================================================

  describe "input validation" do
    test "rejects unknown fields, bad scopes and versioned refs" do
      assert {:error, {:invalid_shape, :unknown_field, _}} =
               ShapeDigest.compute(Map.put(@base, :extra, true))

      assert {:error, {:invalid_shape, :scope, _}} =
               ShapeDigest.compute(Map.put(@base, :scope, :forever))

      assert {:error, {:invalid_shape, :source_ref, message}} =
               ShapeDigest.compute(Map.put(@base, :source_ref, "formula:local.x:1.0.0"))

      assert message =~ "name-level"

      assert {:error, {:invalid_shape, :source_ref, _}} =
               ShapeDigest.compute(Map.put(@base, :source_ref, "not a ref"))

      assert {:error, {:invalid_shape, :tool_policy, message}} =
               ShapeDigest.compute(
                 Map.put(@base, :tool_policy, %{auto: ["http.get"], ask: ["http.get"]})
               )

      assert message =~ "disjoint"
    end

    test "rejects loose durations in caps" do
      # Prima.Limits.parse_duration/1 tolerates "5mm"; a digest input
      # must not — one duration, one spelling.
      assert {:error, {:invalid_shape, :caps, message}} =
               ShapeDigest.compute(Map.put(@base, :caps, %{"timeout" => "5mm"}))

      assert message =~ "exact duration"

      assert {:ok, _} = ShapeDigest.compute(Map.put(@base, :caps, %{"timeout" => "5m"}))
      assert {:ok, _} = ShapeDigest.compute(Map.put(@base, :caps, %{"timeout" => "500ms"}))
    end

    test "rejects floats anywhere in caps" do
      assert {:error, {:invalid_shape, :caps, _}} =
               ShapeDigest.compute(Map.put(@base, :caps, %{"max_memory_bytes" => 1.5}))
    end

    test "needs require a name and a type" do
      assert {:error, {:invalid_shape, :name, _}} =
               ShapeDigest.compute(Map.put(@base, :needs, [%{type: "catalyst:local.db"}]))

      assert {:error, {:invalid_shape, :type, _}} =
               ShapeDigest.compute(Map.put(@base, :needs, [%{name: "source"}]))
    end
  end

  describe "how a need attaches, where it goes, and what is provided" do
    @need %{name: "api_key", type: "api_key:openai.com", fields: ["KEY"]}
    @attach %{in: "header", name: "Authorization", template: "Bearer {value}"}
    @provided %{
      "catalyst:local.supabase" => %{
        "database" => %{
          "destination" => %{"hosts" => ["abc.supabase.co"], "scheme" => "https"},
          "values" => %{"anon_key" => "eyJ-public"}
        }
      }
    }

    test "each declared one changes the digest" do
      base = Map.put(@base, :needs, [@need])

      variants = [
        %{needs: [Map.put(@need, :attach, @attach)]},
        %{needs: [Map.put(@need, :hosts, ["api.openai.com"])]},
        %{needs: [Map.put(@need, :paths, ["/v1/"])]},
        %{needs: [Map.put(@need, :disclose, true)]},
        %{provides: @provided},
        %{
          provides:
            put_in(@provided, ["catalyst:local.supabase", "database", "destination", "hosts"], [
              "xyz.supabase.co"
            ])
        },
        %{
          provides:
            put_in(@provided, ["catalyst:local.supabase", "database", "values"], %{
              "anon_key" => "eyJ-other"
            })
        }
      ]

      for variant <- variants do
        assert digest!(base) != digest!(Map.merge(base, variant)),
               "#{inspect(variant)} did not affect the digest"
      end
    end

    test "one not declared is the input it was before they existed" do
      base = Map.put(@base, :needs, [@need])
      {:ok, canonical} = ShapeDigest.normalize(base)

      assert canonical["needs"] == [
               %{
                 "name" => "api_key",
                 "type" => "api_key:openai.com",
                 "fields" => ["KEY"],
                 "scopes" => []
               }
             ]

      refute Map.has_key?(canonical, "provides")

      # A false disclose and empty hosts or paths declare nothing.
      for undeclared <- [%{disclose: false}, %{hosts: []}, %{paths: []}] do
        assert digest!(base) ==
                 digest!(Map.put(@base, :needs, [Map.merge(@need, undeclared)])),
               "#{inspect(undeclared)} moved the digest"
      end
    end

    test "they normalize: sets sorted, the rule's three members, the destination canonical" do
      need =
        @need
        |> Map.put(:attach, @attach)
        |> Map.put(:hosts, ["b.example", "a.example", "a.example"])
        |> Map.put(:disclose, true)

      {:ok, canonical} =
        ShapeDigest.normalize(Map.merge(@base, %{needs: [need], provides: @provided}))

      assert [
               %{
                 "attach" => %{
                   "in" => "header",
                   "name" => "Authorization",
                   "template" => "Bearer {value}"
                 },
                 "hosts" => ["a.example", "b.example"],
                 "disclose" => true
               }
             ] = canonical["needs"]

      assert canonical["provides"] == @provided
    end

    test "a malformed rule, disclose or provided entry is refused" do
      for need <- [
            Map.put(@need, :attach, %{in: "header", name: "x"}),
            Map.put(@need, :attach, "Bearer"),
            Map.put(@need, :disclose, "yes"),
            Map.put(@need, :hosts, "a.example")
          ] do
        assert {:error, {:invalid_shape, _key, _why}} =
                 ShapeDigest.compute(Map.put(@base, :needs, [need])),
               "#{inspect(need)} was accepted"
      end

      for provides <- [
            ["not", "a", "map"],
            %{"catalyst:local.supabase" => %{}},
            put_in(@provided, ["catalyst:local.supabase", "database", "values"], %{"k" => 1}),
            put_in(@provided, ["catalyst:local.supabase", "database", "destination"], %{}),
            put_in(@provided, ["catalyst:local.supabase", "database", "extra"], "x")
          ] do
        assert {:error, {:invalid_shape, _key, _why}} =
                 ShapeDigest.compute(Map.put(@base, :provides, provides)),
               "#{inspect(provides)} was accepted"
      end
    end
  end

  describe "normalize/1" do
    test "exposes exactly what was hashed" do
      {:ok, canonical} = ShapeDigest.normalize(Map.put(@base, :tool_actions, ["b.x", "a.y"]))

      assert canonical["scope"] == "versionless"
      assert canonical["tool_actions"] == ["a.y", "b.x"]
      refute Map.has_key?(canonical, "release_identity")

      {:ok, digest} = Prima.JCS.hash(canonical)
      assert digest == digest!(Map.put(@base, :tool_actions, ["b.x", "a.y"]))
    end
  end
end
