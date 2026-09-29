defmodule Knotra.Access do
  @moduledoc """
  Host authorization for durable operations. Resolve tenant identity from trusted
  context, never model arguments. `:checkpoint` grants access to sensitive private
  continuation data and must be authorized separately from `:inspect`.
  """
  @callback authorize(:submit | :inspect | :checkpoint | :recover, String.t() | nil, term()) ::
              {:ok, String.t()} | {:error, atom()}
end
