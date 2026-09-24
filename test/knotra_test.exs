defmodule KnotraTest do
  use ExUnit.Case
  doctest Knotra

  test "greets the world" do
    assert Knotra.hello() == :world
  end
end
