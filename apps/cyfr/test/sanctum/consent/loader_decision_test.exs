# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Loader.DecisionTest do
  use ExUnit.Case, async: true

  alias Sanctum.Consent.Loader.Decision

  @granted "sha256:granted"
  @node "formula:local.app"

  defp live(digest, opts \\ []) do
    graph = Keyword.get(opts, :graph, %{@node => digest})

    nodes =
      Keyword.get(
        opts,
        :nodes,
        Map.new(graph, fn {k, d} -> {k, %{release_digest: d, integrity: :ok}} end)
      )

    {:ok, %{digest: digest, graph: graph, nodes: nodes}}
  end

  describe "unresolvable live graph" do
    test "refuses as setup_required under both scopes" do
      for scope <- [:versionless, :pinned] do
        assert {:setup_required, :missing_release_digest} =
                 Decision.evaluate(
                   scope,
                   @granted,
                   {:error, {:incomplete, :missing_release_digest}},
                   :match,
                   false
                 )
      end
    end
  end

  describe "tampering" do
    test "a tampered node alarms even when the activation digests are equal" do
      tampered =
        live(@granted,
          nodes: %{@node => %{release_digest: @granted, integrity: :mismatch}}
        )

      assert {:integrity_alarm, [@node]} =
               Decision.evaluate(:versionless, @granted, tampered, :match, false)
    end

    test "alarm lists every tampered node, sorted" do
      nodes = %{
        "formula:local.b" => %{release_digest: "sha256:x", integrity: :mismatch},
        "formula:local.a" => %{release_digest: "sha256:y", integrity: :mismatch},
        "formula:local.c" => %{release_digest: "sha256:z", integrity: :ok}
      }

      l = {:ok, %{digest: "sha256:other", graph: %{}, nodes: nodes}}

      assert {:integrity_alarm, ["formula:local.a", "formula:local.b"]} =
               Decision.evaluate(:pinned, @granted, l, :differ, true)
    end
  end

  describe "digest equality" do
    test "allows under both scopes regardless of the shape comparison" do
      for scope <- [:versionless, :pinned], shape <- [:match, :differ, :unknown] do
        assert :allow = Decision.evaluate(scope, @granted, live(@granted), shape, false)
      end
    end
  end

  describe "pinned drift" do
    test "a local source re-pins instead of alarming (D7)" do
      assert :needs_consent_repin =
               Decision.evaluate(:pinned, @granted, live("sha256:new"), :match, true)
    end

    test "a remote source needs fresh consent" do
      assert :needs_consent =
               Decision.evaluate(:pinned, @granted, live("sha256:new"), :match, false)
    end
  end

  describe "versionless drift" do
    test "an unchanged shape records the new activation" do
      graph = %{@node => "sha256:new"}

      assert {:allow_record, %{digest: "sha256:new", graph: ^graph}} =
               Decision.evaluate(:versionless, @granted, live("sha256:new"), :match, false)
    end

    test "a changed shape needs fresh consent" do
      assert :needs_consent =
               Decision.evaluate(:versionless, @granted, live("sha256:new"), :differ, false)
    end

    test "an unknown live shape fails closed to fresh consent" do
      assert :needs_consent =
               Decision.evaluate(:versionless, @granted, live("sha256:new"), :unknown, false)
    end
  end
end
