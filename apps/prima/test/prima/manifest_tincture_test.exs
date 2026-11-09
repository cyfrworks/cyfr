# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ManifestTinctureTest do
  @moduledoc """
  The frame, streams, actions and desktop blocks: their shapes, read into
  `Prima.Manifest.Tincture`, refused at every manifest write when wrong,
  and their digest — the same for two declarations that mean the same
  thing, and moved by a declaration that asks for more; the frame's size
  hint, held to its bounds, left out of the digest and declaring nothing
  on its own; the desktop block's bounds, and its prefs and chrome left
  out of the digest; and an app's subjects.
  """

  use ExUnit.Case, async: true

  alias Prima.Manifest
  alias Prima.Manifest.Tincture
  alias Prima.Manifest.Tincture.Frame
  alias Prima.Manifest.Tincture.Size

  @size %{
    "min" => %{"w" => 320, "h" => 480},
    "preferred" => %{"w" => 400, "h" => 640},
    "aspect" => %{"w" => 9, "h" => 16},
    "tile" => "right"
  }

  @declared %{
    "frame" => %{"capabilities" => ["pointer_lock", "fullscreen"]},
    "actions" => ["execution.list", "records.get"],
    "streams" => [%{"name" => "executions.deltas", "subject" => "*"}]
  }

  defp manifest(tincture), do: %{"type" => "tincture", "tincture" => tincture}

  defp refused(tincture) do
    assert {:error, {:invalid_tincture, sentence}} = Tincture.from_manifest(manifest(tincture))
    assert is_binary(sentence)

    assert {:error, {:invalid_manifest, [{:invalid_tincture, ^sentence}]}} =
             Manifest.validate(manifest(tincture), fn _ -> true end)

    sentence
  end

  test "a declaration reads into the struct" do
    assert {:ok, %Tincture{} = decl} = Tincture.from_manifest(manifest(@declared))

    assert decl.frame == %Frame{
             capabilities: ["pointer_lock", "fullscreen"],
             background: false,
             size: nil
           }

    assert decl.desktop == nil
    assert decl.subjects == []

    assert decl.actions == ["execution.list", "records.get"]
    assert [%Tincture.Stream{name: "executions.deltas", subject: "*"}] = decl.streams

    assert Manifest.validate(manifest(@declared), fn _ -> true end) == :ok
  end

  test "a manifest that declares none of the blocks reads as the empty declaration, and is not declared" do
    assert {:ok, %Tincture{frame: %Frame{capabilities: []}, streams: [], actions: []}} =
             Tincture.from_manifest(manifest(%{"entry" => "index.html"}))

    assert {:ok, %Tincture{}} = Tincture.from_manifest(%{"type" => "catalyst"})
    refute Tincture.declared?(manifest(%{"entry" => "index.html"}))
    refute Tincture.declared?(%{})
    assert Tincture.declared?(manifest(%{"actions" => []}))
  end

  # The seed's immutable versions still declare `window` hints, which
  # nothing reads: an extra of any shape, never a refusal.
  test "a declared window is an ignored extra, whatever its shape" do
    for window <- [%{"width" => 800, "height" => 600}, "800x600", 800, ["w"], true] do
      tincture = Map.put(@declared, "window", window)

      assert Manifest.validate(manifest(tincture), fn _ -> true end) == :ok, inspect(window)

      assert Tincture.from_manifest(manifest(tincture)) ==
               Tincture.from_manifest(manifest(@declared)),
             inspect(window)
    end
  end

  test "each malformed block is refused at every manifest write, with a sentence" do
    refused(%{"frame" => "yes"})
    refused(%{"frame" => %{"capabilities" => "pointer_lock"}})
    refused(%{"frame" => %{"capabilities" => ["Pointer Lock"]}})
    refused(%{"frame" => %{"background" => "yes"}})
    refused(%{"frame" => %{"sandbox" => "allow-same-origin"}})
    refused(%{"actions" => ["list"]})
    refused(%{"actions" => "execution.list"})
    refused(%{"streams" => [%{"name" => "deltas"}]})
    refused(%{"streams" => [%{"name" => "executions.deltas", "subject" => "a b"}]})
    refused(%{"streams" => [%{"name" => "executions.deltas", "topic" => "x"}]})
    refused(%{"desktop" => "yes"})
    refused(%{"desktop" => %{"wallpaper" => "x.png"}})
    refused(%{"subjects" => "run"})
  end

  test "frame.placement is no part of the grammar: a declaration naming it is refused" do
    for placement <- ["canvas", "desktop", nil] do
      assert refused(%{"frame" => %{"placement" => placement}}) ==
               "tincture.frame declares unknown key(s): placement"
    end
  end

  test "the digest is the same for declarations that mean the same thing" do
    {:ok, one} = Tincture.from_manifest(manifest(@declared))

    reordered =
      @declared
      |> put_in(["frame", "capabilities"], ["fullscreen", "pointer_lock", "fullscreen"])
      |> Map.put("actions", ["records.get", "execution.list"])

    {:ok, two} = Tincture.from_manifest(manifest(reordered))

    assert Tincture.digest(one) == Tincture.digest(two)
    assert "sha256:" <> hex = Tincture.digest(one)
    assert byte_size(hex) == 64

    # Background defaults to false: absent and false are one declaration.
    {:ok, explicit} =
      Tincture.from_manifest(manifest(put_in(@declared, ["frame", "background"], false)))

    assert Tincture.digest(explicit) == Tincture.digest(one)
  end

  test "a declaration that asks for more moves the digest" do
    {:ok, base} = Tincture.from_manifest(manifest(@declared))
    digest = Tincture.digest(base)

    for more <- [
          put_in(@declared, ["frame", "capabilities"], ["pointer_lock", "fullscreen", "gamepad"]),
          put_in(@declared, ["frame", "background"], true),
          Map.update!(@declared, "actions", &["records.delete" | &1]),
          Map.update!(@declared, "streams", &[%{"name" => "builds.progress"} | &1]),
          put_in(@declared, ["streams"], [%{"name" => "executions.deltas", "subject" => "exec_1"}])
        ] do
      {:ok, wider} = Tincture.from_manifest(manifest(more))
      refute Tincture.digest(wider) == digest
    end
  end

  test "the canonical form is what the digest is taken over" do
    {:ok, decl} = Tincture.from_manifest(manifest(@declared))
    canonical = Tincture.canonical(decl)

    assert canonical["frame"]["capabilities"] == ["fullscreen", "pointer_lock"]
    assert canonical["actions"] == ["execution.list", "records.get"]
    assert {:ok, Tincture.digest(decl)} == Prima.JCS.hash(canonical)
  end

  describe "the size hint" do
    test "reads into the struct, every part optional" do
      sized = put_in(@declared, ["frame", "size"], @size)
      assert {:ok, %Tincture{frame: %Frame{size: size}}} = Tincture.from_manifest(manifest(sized))

      assert size == %Size{
               min: %{w: 320, h: 480},
               preferred: %{w: 400, h: 640},
               aspect: %{w: 9, h: 16},
               tile: "right"
             }

      assert Manifest.validate(manifest(sized), fn _ -> true end) == :ok

      for {part, expected} <- [
            {%{}, %Size{}},
            {%{"tile" => "left"}, %Size{tile: "left"}},
            {%{"preferred" => %{"w" => 100, "h" => 4000}}, %Size{preferred: %{w: 100, h: 4000}}},
            {%{"aspect" => %{"w" => 1, "h" => 100}}, %Size{aspect: %{w: 1, h: 100}}}
          ] do
        assert {:ok, %Tincture{frame: %Frame{size: ^expected}}} =
                 Tincture.from_manifest(manifest(%{"frame" => %{"size" => part}})),
               inspect(part)
      end
    end

    test "is refused at every manifest write outside its bounds or its shape, with a sentence" do
      size = fn part -> %{"frame" => %{"size" => part}} end

      assert refused(size.(%{"min" => %{"w" => 99, "h" => 480}})) =~ "100 to 4000"
      assert refused(size.(%{"preferred" => %{"w" => 400, "h" => 4001}})) =~ "100 to 4000"
      assert refused(size.(%{"aspect" => %{"w" => 0, "h" => 16}})) =~ "1 to 100"
      assert refused(size.(%{"aspect" => %{"w" => 9, "h" => 101}})) =~ "1 to 100"
      assert refused(size.(%{"tile" => "top"})) =~ "left or right"

      assert refused(
               size.(%{
                 "min" => %{"w" => 400, "h" => 640},
                 "preferred" => %{"w" => 400, "h" => 639}
               })
             ) =~
               "at least its min"

      refused(size.("400x640"))
      refused(size.(%{"max" => %{"w" => 800, "h" => 600}}))
      refused(size.(%{"min" => %{"w" => 400}}))
      refused(size.(%{"min" => %{"w" => 400, "h" => 640, "d" => 1}}))
      refused(size.(%{"min" => %{"w" => 400.5, "h" => 640}}))
      refused(size.(%{"min" => %{"w" => "400", "h" => 640}}))
    end

    test "is left out of the digest, and a frame block holding only it declares nothing" do
      {:ok, plain} = Tincture.from_manifest(manifest(@declared))
      {:ok, sized} = Tincture.from_manifest(manifest(put_in(@declared, ["frame", "size"], @size)))

      assert Tincture.digest(sized) == Tincture.digest(plain)
      refute Map.has_key?(Tincture.canonical(sized)["frame"], "size")

      # A frame block declares only what names reach: a capability or
      # background true.
      for frame <- [
            %{},
            %{"size" => @size},
            %{"size" => %{}},
            %{"capabilities" => []},
            %{"background" => false, "size" => @size}
          ] do
        refute Tincture.declared?(manifest(%{"entry" => "index.html", "frame" => frame})),
               inspect(frame)
      end

      for frame <- [
            %{"capabilities" => ["pointer_lock"]},
            %{"background" => true, "size" => @size}
          ] do
        assert Tincture.declared?(manifest(%{"frame" => frame})), inspect(frame)
      end

      assert Tincture.declared?(manifest(%{"frame" => %{"size" => @size}, "actions" => []}))
    end
  end

  describe "the blocks" do
    test "the blocks are frame, streams, actions and desktop" do
      assert Tincture.blocks() == ~w(frame streams actions desktop)
      assert Tincture.desktop_keys() == ~w(data feeds controls prefs chrome)
    end

    # An app's canonical form is exactly its frame, streams and actions, as
    # it was before the desktop block: the digest below is the one main's
    # module took of this declaration before the block existed, so a grant
    # bound to an app's digest holds across the change, and holds with a
    # size hint added.
    test "an app's canonical form is its frame, streams and actions, and nothing else" do
      {:ok, decl} = Tincture.from_manifest(manifest(@declared))

      assert Tincture.canonical(decl) == %{
               "frame" => %{
                 "capabilities" => ["fullscreen", "pointer_lock"],
                 "background" => false
               },
               "streams" => [%{"name" => "executions.deltas", "subject" => "*"}],
               "actions" => ["execution.list", "records.get"]
             }

      assert Tincture.digest(decl) ==
               "sha256:5e0be972903648502f627474d4d0eec0639b3c7964eb95140396a51244a31b78"

      {:ok, sized} = Tincture.from_manifest(manifest(put_in(@declared, ["frame", "size"], @size)))
      assert Tincture.digest(sized) == Tincture.digest(decl)
      refute Tincture.canvas?(decl)
    end
  end

  describe "the desktop block" do
    # The plan's example, its pick's field spelled as the RFC 6901 pointer
    # the grammar reads.
    @desktop %{
      "data" => ["runs.changes", "schedules.changes", "attention.changes"],
      "feeds" => ["weather", "vpn"],
      "controls" => [
        %{
          "id" => "pause-digest",
          "label" => "Pause",
          "operation" => "schedule.pause",
          "args" => %{"schedule_id" => "sch_1"}
        },
        %{
          "id" => "vpn-connect",
          "label" => "Connect",
          "operation" => "feed.press",
          "args" => %{"binding" => "fb_1", "action" => "connect"},
          "pick" => %{
            "stream" => "feed.results",
            "subject" => "vpn",
            "field" => "/result/servers",
            "arg" => "server"
          }
        }
      ],
      "prefs" => %{
        "widgets" => %{
          "weather" => %{"fields" => %{"units" => %{"type" => "enum", "values" => ["c", "f"]}}}
        },
        "desktop" => %{"fields" => %{"compact" => %{"type" => "boolean"}}}
      },
      "chrome" => "chrome.css"
    }

    defp desktop(block), do: %{"desktop" => block}

    defp desktop_digest(block),
      do:
        block
        |> desktop()
        |> manifest()
        |> Tincture.from_manifest()
        |> then(fn {:ok, d} -> Tincture.digest(d) end)

    test "reads into the struct, its data and feeds becoming its streams" do
      assert {:ok, %Tincture{} = decl} = Tincture.from_manifest(manifest(desktop(@desktop)))
      assert Tincture.canvas?(decl)
      assert Manifest.validate(manifest(desktop(@desktop)), fn _ -> true end) == :ok

      assert %Tincture.Desktop{data: data, feeds: ["weather", "vpn"], chrome: "chrome.css"} =
               decl.desktop

      assert data == ["runs.changes", "schedules.changes", "attention.changes"]

      assert decl.streams == [
               %Tincture.Stream{name: "runs.changes"},
               %Tincture.Stream{name: "schedules.changes"},
               %Tincture.Stream{name: "attention.changes"},
               %Tincture.Stream{name: "feed.results", subject: "weather"},
               %Tincture.Stream{name: "feed.results", subject: "vpn"}
             ]

      assert [
               %Tincture.Control{id: "pause-digest", operation: "schedule.pause", pick: nil},
               %Tincture.Control{
                 id: "vpn-connect",
                 label: "Connect",
                 args: %{"binding" => "fb_1", "action" => "connect"},
                 pick: %Tincture.Pick{
                   stream: "feed.results",
                   subject: "vpn",
                   field: "/result/servers",
                   arg: "server"
                 }
               }
             ] = decl.desktop.controls

      assert decl.desktop.prefs == %{
               widgets: %{"weather" => %{"units" => %{"type" => "enum", "values" => ["c", "f"]}}},
               desktop: %{"compact" => %{"type" => "boolean"}}
             }
    end

    test "every key is optional: a bare block is a desktop that reads nothing and offers nothing" do
      assert {:ok, decl} = Tincture.from_manifest(manifest(desktop(%{})))
      assert Tincture.canvas?(decl)
      assert decl.streams == []
      assert decl.desktop == %Tincture.Desktop{}
      assert Tincture.declared?(manifest(desktop(%{})))
      assert Tincture.canonical(decl)["desktop"] == %{"controls" => []}

      # Each key alone.
      for key <- Tincture.desktop_keys() do
        assert {:ok, _} = Tincture.from_manifest(manifest(desktop(Map.take(@desktop, [key])))),
               key
      end
    end

    test "a desktop lists no streams of its own" do
      for streams <- [[], [%{"name" => "runs.changes"}]] do
        assert refused(%{"desktop" => %{}, "streams" => streams}) ==
                 "a tincture.desktop lists no tincture.streams: its data and feeds are the streams it reads"
      end
    end

    test "the digest covers data, feeds and controls, and not prefs or chrome" do
      base = desktop_digest(@desktop)
      [pause, press] = @desktop["controls"]

      for wider <- [
            Map.update!(@desktop, "data", &(["runs.changes" | tl(&1)] ++ ["threads.changes"])),
            Map.put(@desktop, "data", ["runs.changes"]),
            Map.update!(@desktop, "feeds", &["markets" | &1]),
            Map.put(@desktop, "feeds", ["weather"]),
            Map.put(@desktop, "controls", [pause]),
            Map.put(@desktop, "controls", [%{pause | "label" => "Hold"}, press]),
            Map.put(@desktop, "controls", [%{pause | "operation" => "schedule.resume"}, press]),
            Map.put(@desktop, "controls", [
              %{pause | "args" => %{"schedule_id" => "sch_2"}},
              press
            ]),
            Map.put(@desktop, "controls", [
              pause,
              put_in(press, ["pick", "field"], "/result/zones")
            ])
          ] do
        refute desktop_digest(wider) == base, inspect(wider)
      end

      for same <- [
            Map.delete(@desktop, "prefs"),
            put_in(@desktop, ["prefs", "desktop", "fields", "dense"], %{"type" => "boolean"}),
            Map.delete(@desktop, "chrome"),
            Map.put(@desktop, "chrome", "themes/night.css"),
            Map.put(@desktop, "controls", Enum.reverse(@desktop["controls"]))
          ] do
        assert desktop_digest(same) == base, inspect(same)
      end

      # Becoming a desktop asks again, whatever the block holds.
      {:ok, app} = Tincture.from_manifest(manifest(%{"actions" => []}))
      refute desktop_digest(%{}) == Tincture.digest(app)
    end

    test "data and feeds are each at most 32 names in their grammars, each once" do
      names = for i <- 1..32, do: "s#{i}.changes"
      feeds = for i <- 1..32, do: "f#{i}"

      assert {:ok, _} =
               Tincture.from_manifest(manifest(desktop(%{"data" => names, "feeds" => feeds})))

      assert refused(desktop(%{"data" => ["s0.changes" | names]})) ==
               "tincture.desktop.data names at most 32"

      assert refused(desktop(%{"feeds" => ["f0" | feeds]})) ==
               "tincture.desktop.feeds names at most 32"

      assert refused(desktop(%{"data" => ["runs"]})) =~ "each a dotted stream name"
      assert refused(desktop(%{"feeds" => ["Weather"]})) =~ "each a feed's name"
      assert refused(desktop(%{"data" => ["runs.changes", "runs.changes"]})) =~ "names each once"
      assert refused(desktop(%{"feeds" => ["vpn", "vpn"]})) =~ "names each once"
      assert refused(desktop(%{"data" => "runs.changes"})) =~ "must be a list of names"
    end

    test "controls are at most 32, each with an id once, a short label, an operation and object args" do
      control = fn id -> %{"id" => id, "label" => "Go", "operation" => "schedule.pause"} end
      controls = for i <- 1..32, do: control.("c#{i}")
      assert {:ok, _} = Tincture.from_manifest(manifest(desktop(%{"controls" => controls})))

      assert refused(desktop(%{"controls" => [control.("c0") | controls]})) =~
               "at most 32 controls"

      assert refused(desktop(%{"controls" => [control.("c1"), control.("c1")]})) =~ "each id once"
      assert refused(desktop(%{"controls" => [control.("Pause")]})) =~ "id must be an identifier"

      assert refused(desktop(%{"controls" => [Map.delete(control.("c1"), "id")]})) =~
               "got nothing"

      assert refused(desktop(%{"controls" => [Map.put(control.("c1"), "icon", "x")]})) =~
               "unknown key(s): icon"

      label = fn text -> %{control.("c1") | "label" => text} end

      assert {:ok, _} =
               Tincture.from_manifest(
                 manifest(desktop(%{"controls" => [label.(String.duplicate("é", 32))]}))
               )

      assert refused(desktop(%{"controls" => [label.(String.duplicate("é", 33))]})) =~
               "1 to 32 code points"

      assert refused(desktop(%{"controls" => [label.("")]})) =~ "1 to 32 code points"
      assert refused(desktop(%{"controls" => [label.("Go\nnow")]})) =~ "no control character"

      assert refused(desktop(%{"controls" => [%{control.("c1") | "operation" => "pause"}]})) =~
               "operation name (tool.action)"

      assert refused(desktop(%{"controls" => [Map.put(control.("c1"), "args", ["x"])]})) =~
               "args must be an object"
    end

    test "a pick names a stream, a feed as its subject, an RFC 6901 pointer and an argument" do
      pick = fn fields ->
        %{"id" => "c1", "label" => "Go", "operation" => "feed.press", "pick" => fields}
      end

      ok = %{
        "stream" => "feed.results",
        "subject" => "vpn",
        "field" => "/result/a~1b~0c",
        "arg" => "server"
      }

      assert {:ok, _} = Tincture.from_manifest(manifest(desktop(%{"controls" => [pick.(ok)]})))

      assert refused(desktop(%{"controls" => [pick.(Map.put(ok, "values", []))]})) =~
               "unknown key(s): values"

      assert refused(desktop(%{"controls" => [pick.(%{ok | "stream" => "feed"})]})) =~
               "dotted stream name"

      assert refused(desktop(%{"controls" => [pick.(%{ok | "subject" => "*"})]})) =~
               "a feed's name"

      for field <- ["result.servers", "", "result/servers", "/result/~2", "/a~"] do
        assert refused(desktop(%{"controls" => [pick.(%{ok | "field" => field})]})) =~
                 "RFC 6901 pointer",
               field
      end

      assert refused(desktop(%{"controls" => [pick.(%{ok | "arg" => "Server"})]})) =~
               "must name an argument"

      assert refused(desktop(%{"controls" => [pick.("server")]})) =~ "the pick must be an object"
    end

    test "prefs are at most 32 widgets of at most 16 typed fields, and a desktop section" do
      widgets = Map.new(1..32, &{"w#{&1}", %{}})
      fields = Map.new(1..16, &{"f#{&1}", %{"type" => "boolean"}})

      assert {:ok, decl} =
               Tincture.from_manifest(
                 manifest(
                   desktop(%{
                     "prefs" => %{"widgets" => Map.put(widgets, "w1", %{"fields" => fields})}
                   })
                 )
               )

      assert decl.desktop.prefs.widgets["w1"] == fields
      assert decl.desktop.prefs.widgets["w2"] == %{}

      prefs = fn prefs -> desktop(%{"prefs" => prefs}) end
      widget = fn fields -> prefs.(%{"widgets" => %{"weather" => %{"fields" => fields}}}) end

      assert refused(prefs.(%{"widgets" => Map.put(widgets, "w0", %{})})) =~ "at most 32 widgets"

      assert refused(widget.(Map.put(fields, "f0", %{"type" => "boolean"}))) =~
               "at most 16 fields"

      assert refused(prefs.(%{"widgets" => %{"Weather" => %{}}})) =~
               "a widget id is an identifier"

      assert refused(prefs.(%{"layout" => %{}})) =~ "unknown key(s): layout"

      assert refused(prefs.(%{"widgets" => %{"weather" => %{"fields" => %{}, "x" => 1}}})) =~
               "unknown key(s): x"

      for fixed <- Tincture.widget_fixed_fields() do
        assert refused(widget.(%{fixed => %{"type" => "boolean"}})) =~
                 "which every widget carries already"
      end

      # The desktop's own section has no fixed fields.
      assert {:ok, _} =
               Tincture.from_manifest(
                 manifest(
                   prefs.(%{"desktop" => %{"fields" => %{"on" => %{"type" => "boolean"}}}})
                 )
               )

      assert {:ok, typed} =
               Tincture.from_manifest(
                 manifest(
                   widget.(%{
                     "a" => %{"type" => "integer"},
                     "b" => %{"type" => "number"},
                     "c" => %{"type" => "string"},
                     "d" => %{"type" => "string", "max" => 1},
                     "e" => %{"type" => "enum", "values" => Enum.map(1..64, &"v#{&1}")}
                   })
                 )
               )

      assert typed.desktop.prefs.widgets["weather"]["c"] == %{"type" => "string", "max" => 256}

      assert refused(widget.(%{"c" => %{"type" => "string", "max" => 257}})) =~
               "max is a whole number 1 to 256"

      assert refused(widget.(%{"c" => %{"type" => "string", "max" => 0}})) =~
               "max is a whole number 1 to 256"

      assert refused(widget.(%{"e" => %{"type" => "enum", "values" => []}})) =~ "1 to 64 strings"

      assert refused(
               widget.(%{"e" => %{"type" => "enum", "values" => Enum.map(0..64, &"v#{&1}")}})
             ) =~ "1 to 64 strings"

      assert refused(widget.(%{"e" => %{"type" => "enum", "values" => ["c", "c"]}})) =~
               "are distinct"

      assert refused(widget.(%{"e" => %{"type" => "enum", "values" => [""]}})) =~
               "1 to 256 code points"

      assert refused(widget.(%{"e" => %{"type" => "enum"}})) =~ "1 to 64 strings"

      assert refused(widget.(%{"t" => %{"type" => "time"}})) =~
               "type is one of boolean, integer, number, string, enum"

      assert refused(widget.(%{"b" => %{"type" => "boolean", "max" => 1}})) =~
               "unknown key(s): max"
    end

    test "chrome is the relative path of a .css file in the version" do
      for path <- ["chrome.css", "themes/night.css"] do
        assert {:ok, %{desktop: %{chrome: ^path}}} =
                 Tincture.from_manifest(manifest(desktop(%{"chrome" => path})))
      end

      for path <- [
            "../chrome.css",
            "/chrome.css",
            "chrome.CSS",
            "chrome.txt",
            "a//b.css",
            "https://x.test/a.css",
            1
          ] do
        assert refused(desktop(%{"chrome" => path})) =~ "tincture.desktop.chrome must be",
               inspect(path)
      end
    end
  end

  describe "an app's subjects" do
    test "are kinds of run, thread, schedule, component and file, each once, and declare nothing" do
      assert Tincture.subject_kinds() == ~w(run thread schedule component file)
      app = %{"subjects" => ["run", "file"]}

      assert {:ok, %Tincture{subjects: ["run", "file"]} = decl} =
               Tincture.from_manifest(manifest(app))

      refute Tincture.declared?(manifest(app))
      assert Manifest.validate(manifest(app), fn _ -> true end) == :ok

      {:ok, plain} = Tincture.from_manifest(manifest(@declared))

      {:ok, subjected} =
        Tincture.from_manifest(manifest(Map.put(@declared, "subjects", Tincture.subject_kinds())))

      assert Tincture.digest(subjected) == Tincture.digest(plain)
      assert decl.desktop == nil

      assert refused(%{"subjects" => ["note"]}) =~
               "kinds of run, thread, schedule, component, file"

      assert refused(%{"subjects" => ["run", "run"]}) == "tincture.subjects names each kind once"

      assert refused(%{"subjects" => %{"run" => true}}) ==
               "tincture.subjects must be a list of kinds"
    end
  end

  test "a pointer's segments are unescaped as RFC 6901 says" do
    assert Tincture.pointer_segments("/result/servers") == {:ok, ["result", "servers"]}
    assert Tincture.pointer_segments("/a~1b/c~0d") == {:ok, ["a/b", "c~d"]}
    assert Tincture.pointer_segments("") == :error
    assert Tincture.pointer_segments("result") == :error
    assert Tincture.pointer_segments(nil) == :error
  end

  test "the name grammars the wire and the provider declarations share" do
    assert Tincture.stream_name?("executions.deltas")
    refute Tincture.stream_name?("executions")
    assert Tincture.operation_name?("execution.list")
    refute Tincture.operation_name?("execution.list.all")
    assert Tincture.literal_subject?("exec_1:2")
    refute Tincture.literal_subject?(Tincture.any_subject())
  end
end
