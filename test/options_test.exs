defmodule Claudio.OptionsTest do
  use ExUnit.Case, async: true

  alias Claudio.Options

  describe "validate!/3" do
    test "returns the options when every key is allowed" do
      assert Options.validate!([a: 1], [:a, :b], "Mod.fun/2") == [a: 1]
      assert Options.validate!([], [:a], "Mod.fun/2") == []
    end

    test "an unknown key names the function, the key and the allowed keys" do
      assert_raise ArgumentError,
                   "Mod.fun/2: unknown option :c; allowed: :a, :b",
                   fn -> Options.validate!([a: 1, c: 2], [:a, :b], "Mod.fun/2") end
    end

    test "several unknown keys are all listed, once each" do
      assert_raise ArgumentError,
                   "Mod.fun/2: unknown options :c, :d; allowed: :a",
                   fn -> Options.validate!([c: 1, d: 2, c: 3], [:a], "Mod.fun/2") end
    end

    test "a non-keyword value names the function and the value" do
      assert_raise ArgumentError,
                   "Mod.fun/2: options must be a keyword list; got %{a: 1}",
                   fn -> Options.validate!(%{a: 1}, [:a], "Mod.fun/2") end

      assert_raise ArgumentError,
                   ~s(Mod.fun/2: options must be a keyword list; got ["a"]),
                   fn -> Options.validate!(["a"], [:a], "Mod.fun/2") end
    end
  end
end
