# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.RouterTest do
  # The route map (`test/support/route_map.exs`) against the compiled route
  # table and each provider's source: a route, posture, LiveView, pipeline
  # or plug that moves or vanishes fails here until the map moves with it.
  use ExUnit.Case, async: true

  alias Cyfr.Boundaries
  alias Cyfr.Test.RouterSource

  @root Path.expand("../../../..", __DIR__)
  {map, _binding} = Code.eval_file(Path.join(@root, "apps/cyfr/test/support/route_map.exs"))
  @providers map.providers

  defp sections, do: @providers

  defp all_rows, do: Enum.flat_map(sections(), fn {_name, section} -> section.routes end)

  defp source(section), do: Path.join(@root, section.file)

  defp label(%{verb: verb, path: path}), do: "#{verb} #{path}"

  defp sorted(rows), do: Enum.sort_by(rows, &{&1.path, &1.verb})

  # A row of the compiled table, stringified as the map records it.
  defp table_row(route) do
    live_view =
      case route.metadata[:phoenix_live_view] do
        {view, _action, _opts, _session} -> inspect(view)
        nil -> nil
      end

    %{
      verb: route.verb |> Atom.to_string() |> String.upcase(),
      path: route.path,
      plug: inspect(route.plug),
      plug_opts: inspect(route.plug_opts),
      auth: route.metadata |> Map.fetch!(:auth) |> Atom.to_string(),
      live_view: live_view
    }
  end

  defp facts(row), do: Map.delete(row, :pipe_through)

  # Every section that declares the pipeline `name`, with its plugs.
  defp declared(name) do
    for {provider, section} <- sections(),
        plugs = section.pipelines[name],
        plugs != nil,
        do: {provider, plugs}
  end

  describe "the total table" do
    test "the compiled table is exactly the map's rows, every section together" do
      table = Boundaries.routes() |> Enum.map(&table_row/1) |> sorted()
      mapped = all_rows() |> Enum.map(&facts/1) |> sorted()

      unmapped = table -- mapped
      stale = mapped -- table

      assert unmapped == [] and stale == [],
             """
             The route map and the compiled table disagree.

             In the table, not the map (added or changed):
             #{Enum.map_join(unmapped, "\n", &"  #{label(&1)}: #{inspect(&1)}")}

             In the map, not the table (removed or changed):
             #{Enum.map_join(stale, "\n", &"  #{label(&1)}: #{inspect(&1)}")}
             """

      twice =
        all_rows()
        |> Enum.frequencies_by(&label/1)
        |> Enum.filter(fn {_label, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))

      assert twice == [], "rows the map records more than once: #{inspect(twice)}"
    end

    test "the map's rows are sorted by path, then verb" do
      for {provider, section} <- sections() do
        assert section.routes == sorted(section.routes),
               "the #{provider} section's rows are not sorted by path, then verb"
      end
    end
  end

  describe "each provider" do
    test "declares exactly its section's routes, each under its section's pipelines" do
      for {provider, section} <- sections() do
        declared = RouterSource.routes(source(section))
        from_source = Map.new(declared, &{label(&1), &1.pipe_through})
        from_map = Map.new(section.routes, &{label(&1), &1.pipe_through})

        assert map_size(from_source) == length(declared),
               "#{section.file} declares a route twice"

        undeclared = Map.keys(from_map) -- Map.keys(from_source)
        unrecorded = Map.keys(from_source) -- Map.keys(from_map)

        assert undeclared == [] and unrecorded == [],
               """
               The #{provider} section and #{section.file} disagree on which routes it declares.
               In the section, not the file: #{inspect(undeclared)}
               In the file, not the section: #{inspect(unrecorded)}
               """

        moved =
          for {label, pipes} <- from_map,
              from_source[label] != pipes,
              do:
                "#{label}: the map says #{inspect(pipes)}, the file #{inspect(from_source[label])}"

        assert moved == [], "routes whose pipelines changed:\n#{Enum.join(moved, "\n")}"
      end
    end

    test "declares exactly its section's pipelines, and every row's pipeline is its section's" do
      for {provider, section} <- sections() do
        source = RouterSource.pipelines(source(section))

        changed =
          for name <- Enum.uniq(Map.keys(source) ++ Map.keys(section.pipelines)),
              source[name] != section.pipelines[name],
              do:
                "#{name}: the map says #{inspect(section.pipelines[name])}, " <>
                  "#{section.file} #{inspect(source[name])}"

        assert changed == [],
               "the #{provider} section's pipelines differ:\n#{Enum.join(changed, "\n")}"

        foreign =
          for row <- section.routes,
              pipe <- row.pipe_through,
              not Map.has_key?(section.pipelines, pipe),
              do: "#{label(row)} pipes through #{pipe}, which #{provider} does not declare"

        assert foreign == [], Enum.join(foreign, "\n")
      end
    end

    # A pattern path resolves to itself: a literal `:athanor` binds as a
    # parameter value and a literal `*path` as the glob, so every row is
    # checked against the router, not only the parameter-free ones.
    test "the source walk agrees with the router on every route" do
      router = Boundaries.router()

      for row <- all_rows() do
        assert %{route: route, pipe_through: pipes} =
                 Phoenix.Router.route_info(router, row.verb, row.path, "example.com"),
               "#{label(row)} is served by no route"

        assert route == row.path, "#{label(row)} is served by #{route}"

        assert Enum.map(pipes, &Atom.to_string/1) == row.pipe_through,
               "#{label(row)} pipes through #{inspect(pipes)}; the map says #{inspect(row.pipe_through)}"
      end
    end
  end

  describe "the roster" do
    test "the map's sections are the modules the root's table comes from" do
      # C2 rewrites this assertion when the first provider other than the root appears.
      assert Map.keys(@providers) == [inspect(Boundaries.router())]
    end
  end

  describe "the invariants the map must keep" do
    test "a state-changing browser post pipes through the forgery guard" do
      for label <- [
            "POST /auth/logout",
            "POST /claim-namespace/submit",
            "POST /legal/accept/submit"
          ] do
        found =
          for {_provider, section} <- sections(),
              row <- section.routes,
              label(row) == label,
              do: {section, row}

        assert [{section, row}] = found, "the map records #{label} #{length(found)} times"

        assert Enum.any?(row.pipe_through, &(":protect_from_forgery" in section.pipelines[&1])),
               "#{label} pipes through #{inspect(row.pipe_through)}, none of which " <>
                 "carries :protect_from_forgery"
      end
    end

    test "the MCP and authenticated API pipelines check the origin; tincture invoke does not" do
      for name <- ["mcp", "authenticated_api"] do
        assert declared(name) != [], "no section declares the #{name} pipeline"

        for {provider, plugs} <- declared(name) do
          assert "CyfrWeb.Plugs.MCPOrigin" in plugs,
                 "#{provider}'s #{name} pipeline does not check the origin: #{inspect(plugs)}"
        end
      end

      assert declared("tincture_invoke") != [], "no section declares tincture_invoke"

      for {provider, plugs} <- declared("tincture_invoke") do
        refute "CyfrWeb.Plugs.MCPOrigin" in plugs,
               "#{provider}'s tincture_invoke pipeline checks the origin; a public " <>
                 "tincture is cross-origin by design"
      end
    end

    test "every page pipeline refuses a headless node first" do
      pages = Enum.flat_map(["browser", "attachment"], &declared/1)
      assert pages != [], "no section declares a browser or attachment pipeline"

      for name <- ["browser", "attachment"], {provider, plugs} <- declared(name) do
        assert List.first(plugs) == "CyfrWeb.Plugs.Headless",
               "#{provider}'s #{name} pipeline does not begin with the headless refusal: " <>
                 inspect(plugs)
      end
    end

    test "every tincture pipeline scrubs the credential before it rate-limits" do
      tinctures =
        for {provider, section} <- sections(),
            {name, plugs} <- section.pipelines,
            String.starts_with?(name, "tincture"),
            do: {provider, name, plugs}

      assert tinctures != [], "no section declares a tincture pipeline"

      for {provider, name, plugs} <- tinctures do
        scrub = Enum.find_index(plugs, &(&1 == "CyfrWeb.Plugs.ScrubTinctureCredentials"))
        limit = Enum.find_index(plugs, &(&1 == "CyfrWeb.Plugs.TinctureRateLimit"))

        assert scrub != nil and limit != nil and scrub < limit,
               "#{provider}'s #{name} pipeline must scrub the credential before it " <>
                 "rate-limits: #{inspect(plugs)}"
      end
    end
  end
end
