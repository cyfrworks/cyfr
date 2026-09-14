# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.AnnotationsTest do
  use ExUnit.Case, async: true

  alias Cyfr.Ops.Annotations

  @annotation %{
    kind: :write,
    planes: [:external, :in_chain],
    auth: :anonymous,
    permission: :admin,
    consent: :staging,
    scope: :platform
  }
  @actions %{"create" => @annotation, "list" => %{kind: :read, planes: [:external]}}

  @provider_shape %{name: "thing", input_schema: %{}, annotations: %{actions: @actions}}
  @meta_shape %{annotations: %{actions: @actions}, description: "cached"}
  @wire_shape %{"name" => "thing", "inputSchema" => %{}, "annotations" => %{actions: @actions}}

  @sources [@provider_shape, @meta_shape, @wire_shape]

  test "every accessor answers the same across all three source shapes" do
    for source <- @sources do
      assert Annotations.actions_of(source) == @actions
      assert Annotations.annotation(source, "create") == @annotation
      assert Annotations.kind(source, "create") == :write
      assert Annotations.planes(source, "create") == [:external, :in_chain]
      assert Annotations.auth(source, "create") == :anonymous
      assert Annotations.permission(source, "create") == :admin
      assert Annotations.consent(source, "create") == :staging
      assert Annotations.scope(source, "create") == :platform
    end
  end

  test "absence fails closed" do
    for source <- @sources do
      assert Annotations.annotation(source, "missing") == nil
      assert Annotations.annotation(source, nil) == nil
      assert Annotations.kind(source, "missing") == nil
      assert Annotations.planes(source, "missing") == []
      assert Annotations.auth(source, "missing") == :required
      assert Annotations.permission(source, "missing") == nil
      assert Annotations.consent(source, "missing") == nil
      assert Annotations.scope(source, "missing") == nil
    end

    assert Annotations.actions_of(%{}) == %{}
    assert Annotations.actions_of(%{"annotations" => nil}) == %{}
    assert Annotations.actions_of(%{annotations: nil}) == %{}
    assert Annotations.planes(%{}, "x") == []
    assert Annotations.auth(%{"annotations" => nil}, "x") == :required
  end

  test "defaults inside a declared annotation" do
    source = %{annotations: %{actions: %{"list" => %{kind: :read, planes: [:external]}}}}
    assert Annotations.auth(source, "list") == :required
    assert Annotations.permission(source, "list") == nil
    assert Annotations.consent(source, "list") == nil
    assert Annotations.scope(source, "list") == nil
  end

  test "a kind that is not an atom is not a kind" do
    source = %{annotations: %{actions: %{"x" => %{kind: "write"}}}}
    assert Annotations.kind(source, "x") == nil
  end

  test "declared_actions/1 accepts only the provider spelling" do
    assert Annotations.declared_actions(@provider_shape) == @actions
    assert Annotations.declared_actions(%{"annotations" => %{actions: @actions}}) == %{}
    assert Annotations.declared_actions(%{}) == %{}
  end

  # The one codec for a standing declaration, whichever surface it arrives
  # from: the annotation's atom, the wire's string, or nothing.
  test "a standing declaration decodes to one shape and encodes back to the wire" do
    assert Annotations.standing(:thread) == :thread
    assert Annotations.standing("thread") == :thread
    assert Annotations.standing(false) == false
    assert Annotations.standing(nil) == nil
    assert Annotations.standing("anything else") == nil

    assert Annotations.standing_to_wire(:thread) == "thread"
    assert Annotations.standing_to_wire("thread") == "thread"
    assert Annotations.standing_to_wire(false) == false
    assert Annotations.standing_to_wire(nil) == nil
  end

  test "an action the host intercepts says so, and a chain reaches it through the host" do
    tool = %{
      name: "execution",
      annotations: %{
        actions: %{
          "run" => %{kind: :execute, planes: [:external], host: :intercepted},
          "list" => %{kind: :read, planes: [:external, :in_chain]}
        }
      }
    }

    assert Annotations.host_intercepted?(tool, "run")
    refute Annotations.host_intercepted?(tool, "list")
    refute Annotations.host_intercepted?(tool, "nope")
  end
end
