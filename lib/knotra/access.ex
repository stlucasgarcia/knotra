defmodule Knotra.Access do
  @moduledoc """
  Host authorization for durable operations. Resolve tenant identity from trusted
  context, never model arguments. `:checkpoint` grants access to sensitive private
  continuation data and must be authorized separately from `:inspect`. `:answer`
  permits a responder to decide the identified request, not to bypass fresh tool
  business authorization. `:cancel` permits pre-admission durable cancellation;
  inspection/recovery/answering also materialize an already-due response expiry.
  """
  @callback authorize(
              :submit | :inspect | :checkpoint | :recover | :answer | :cancel,
              String.t() | nil,
              term()
            ) ::
              {:ok, String.t()} | {:error, atom()}
end
