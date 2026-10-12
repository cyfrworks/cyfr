# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EnvFilesTest do
  @moduledoc """
  The `.env` files a boot reads keep every value literal (`Cyfr.EnvFiles`):
  no `$(…)` runs, on the read that only collects the names
  (`side_effect: false`) or on the read the boot configures from, and a
  `$(` the parser cannot keep refuses the boot by file and line, never by
  value. The last cases evaluate `config/runtime.exs` the way a release
  does, since the suite's own boot skips it.
  """

  # Sets the operating system's environment for the duration of a case.
  use ExUnit.Case, async: false

  @root Path.expand("../../../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "cyfr-env-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, marker: Path.join(dir, "ran")}
  end

  defp env_file(dir, lines) do
    path = Path.join(dir, ".env")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  describe "values" do
    test "each $(…) is kept as written and runs nothing, on both reads", %{
      dir: dir,
      marker: marker
    } do
      path =
        env_file(dir, [
          "A=$(id)",
          ~s[B="pa$(touch #{marker})ss"],
          "C=x$(touch #{marker})y",
          ~s[D="x $(echo hi) y"],
          "E=$(a(b))"
        ])

      expected = %{
        "A" => "$(id)",
        "B" => "pa$(touch #{marker})ss",
        "C" => "x$(touch #{marker})y",
        "D" => "x $(echo hi) y",
        "E" => "$(a(b))"
      }

      assert Cyfr.EnvFiles.source!([path], side_effect: false) == expected
      assert Cyfr.EnvFiles.source!([path]) == expected
      assert Dotenvy.env!("B", :string) == "pa$(touch #{marker})ss"
      refute File.exists?(marker)
    end

    test "a single-quoted value is literal throughout, an unclosed $( included", %{dir: dir} do
      path = env_file(dir, ["A='$(id)'", "B='x $( y'", "C='$()'", "D='$(id", ")'"])

      assert Cyfr.EnvFiles.source!([path], side_effect: false) ==
               %{"A" => "$(id)", "B" => "x $( y", "C" => "$()", "D" => "$(id\n)"}
    end

    test "the space just inside a kept $( … ) is trimmed", %{dir: dir} do
      path = env_file(dir, ["A=$( id -u )", "B=$(id  -u)"])

      assert Cyfr.EnvFiles.source!([path], side_effect: false) == %{
               "A" => "$(id -u)",
               "B" => "$(id  -u)"
             }
    end

    test "${NAME} still takes an earlier input's value", %{dir: dir} do
      path = env_file(dir, ["A=${HOME_DIR}/cache"])

      assert Cyfr.EnvFiles.source!([%{"HOME_DIR" => "/h"}, path], side_effect: false)["A"] ==
               "/h/cache"
    end
  end

  describe "a $( the parser cannot keep" do
    test "one not closed on its line refuses, naming the file and line and not the value", %{
      dir: dir
    } do
      path = env_file(dir, ["A=a", "# a note", "B=s3cr3t$(oops"])

      message =
        Exception.message(assert_raise RuntimeError, fn -> Cyfr.EnvFiles.source!([path]) end)

      assert message ==
               "[Cyfr] FATAL: #{path} line 3 opens a $( it does not close on that line. " <>
                 ".env values are literal and no command runs; close the $( on its line, " <>
                 "or single-quote the value"

      refute message =~ "s3cr3t"
      refute message =~ "Stop sequence"
    end

    test "one closed only on a later line refuses, rather than reading the lines between into its value",
         %{dir: dir} do
      path = env_file(dir, ["A=x$(y", "B=(z)", "C=c"])

      message =
        Exception.message(assert_raise RuntimeError, fn -> Cyfr.EnvFiles.source!([path]) end)

      assert message =~ "#{path} line 1 opens a $( it does not close on that line."

      quoted = env_file(dir, ["A=a", ~s[B="x $(y], ~s[z)"]])

      message =
        Exception.message(assert_raise RuntimeError, fn -> Cyfr.EnvFiles.source!([quoted]) end)

      assert message =~ "#{quoted} line 2 opens a $( it does not close on that line."
    end

    test "one whose brackets begin or end with a line break refuses, though Dotenvy trims it away",
         %{dir: dir} do
      trailing = env_file(dir, ["A=$(id", ")", "B=after"])

      message =
        Exception.message(
          assert_raise RuntimeError, fn ->
            Cyfr.EnvFiles.source!([trailing], side_effect: false)
          end
        )

      assert message =~
               "[Cyfr] FATAL: #{trailing} line 1 opens a $( it does not close on that line."

      leading = env_file(dir, [~s[A="$(], ~s[id)"], "B=after"])

      message =
        Exception.message(
          assert_raise RuntimeError, fn ->
            Cyfr.EnvFiles.source!([leading], side_effect: false)
          end
        )

      assert message =~
               "[Cyfr] FATAL: #{leading} line 1 opens a $( it does not close on that line."
    end

    test "an empty one refuses, naming the file and line", %{dir: dir} do
      path = env_file(dir, ["A=a", "B=b", "C=x$()"])

      message =
        Exception.message(
          assert_raise RuntimeError, fn -> Cyfr.EnvFiles.source!([path], side_effect: false) end
        )

      assert message ==
               "[Cyfr] FATAL: #{path} line 3 holds an empty $(). " <>
                 ".env values are literal and no command runs; put text between the brackets, " <>
                 "or single-quote the value"
    end

    test "the refusal names the file that holds it, after files that do not", %{dir: dir} do
      clean = env_file(dir, ["A=a"])
      held = Path.join(dir, ".env.local")
      File.write!(held, "B=b\nC=$(\n")

      message =
        Exception.message(
          assert_raise RuntimeError, fn -> Cyfr.EnvFiles.source!([clean, held, %{}]) end
        )

      assert message =~ "#{held} line 2 opens a $("
    end

    test "the refusal names the file and line after a variable an earlier file assigned", %{
      dir: dir
    } do
      shared = env_file(dir, ["SHARED=base"])
      local = Path.join(dir, ".env.local")

      for {line, said} <- [
            {"B=$(secret", "opens a $( it does not close on that line."},
            {"B=$()", "holds an empty $()."}
          ] do
        File.write!(local, "A=${SHARED}\n" <> line <> "\n")

        message =
          Exception.message(
            assert_raise RuntimeError, fn ->
              Cyfr.EnvFiles.source!([shared, local], side_effect: false)
            end
          )

        assert message =~ "[Cyfr] FATAL: #{local} line 2 " <> said
        refute message =~ "secret"
      end
    end

    test "an earlier file that fails another way is reported as Dotenvy reports it", %{dir: dir} do
      broken = env_file(dir, [~s[A="unterminated]])
      held = Path.join(dir, ".env.local")
      File.write!(held, "B=$(\n")

      message =
        Exception.message(
          assert_raise RuntimeError, fn -> Cyfr.EnvFiles.source!([broken, held]) end
        )

      refute message =~ "[Cyfr] FATAL"
      assert message =~ broken
    end

    test "any other failure is Dotenvy's own", %{dir: dir} do
      path = env_file(dir, [~s[A="unterminated]])

      message =
        Exception.message(assert_raise RuntimeError, fn -> Cyfr.EnvFiles.source!([path]) end)

      refute message =~ "[Cyfr] FATAL"
      assert message =~ path
    end
  end

  # ---------------------------------------------------------------------------
  # The boot, evaluated
  # ---------------------------------------------------------------------------

  # The release's environment, with `.env` at its RELEASE_ROOT: the
  # variables a case sets are restored after it.
  defp with_release_env(dir, fun) do
    env = %{
      "CYFR_SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(48)),
      "RELEASE_NAME" => "cyfr",
      "RELEASE_ROOT" => dir,
      "CYFR_DATABASE" => nil,
      "CYFR_COSIGN_KEY" => nil,
      "CYFR_COSIGN_PASSWORD" => nil
    }

    previous = Map.new(env, fn {k, _} -> {k, System.get_env(k)} end)

    try do
      Enum.each(env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp read_prod_config! do
    Config.Reader.read!(Path.join(@root, "config/runtime.exs"), env: :prod, imports: :disabled)
  end

  describe "config/runtime.exs" do
    test "a .env value holding a $(…) reaches the configuration as written, and nothing runs",
         %{dir: dir, marker: marker} do
      env_file(dir, [
        "CYFR_COSIGN_KEY=/keys/cosign.key",
        ~s[CYFR_COSIGN_PASSWORD="pa$(touch #{marker})ss"]
      ])

      config = with_release_env(dir, &read_prod_config!/0)

      assert config[:cyfr][:sigstore][:password] == "pa$(touch #{marker})ss"
      refute File.exists?(marker)
    end

    test "a $( not closed on its line refuses the boot by file and line", %{dir: dir} do
      path = env_file(dir, ["CYFR_COSIGN_KEY=/keys/cosign.key", "CYFR_COSIGN_PASSWORD=pa$(ss"])

      message =
        with_release_env(dir, fn ->
          Exception.message(assert_raise RuntimeError, &read_prod_config!/0)
        end)

      assert message =~ "[Cyfr] FATAL: #{path} line 2 opens a $( it does not close on that line."
      refute message =~ "pa$(ss"
    end
  end
end
