defmodule Knotra.Access do
  @moduledoc """
  Host authorization for durable operations. Resolve tenant identity from trusted
  context, never model arguments. `:checkpoint` grants access to sensitive private
  continuation data and must be authorized separately from `:inspect`. `:answer`
  permits a responder to decide the identified request, not to bypass fresh tool
  business authorization. For `:answer`, return `{:ok, tenant_id, responder_id}`:
  a host-authenticated, nonsecret binary reference of 1–256 bytes, never credentials
  or a channel/model-supplied actor. It is recorded atomically with the decision.
  Other actions may still return `{:ok, tenant_id}`. `:cancel` permits pre-admission
  durable cancellation; inspection/recovery/answering also materialize an
  already-due response expiry.
  """
  @callback authorize(
              :submit | :inspect | :checkpoint | :recover | :answer | :cancel,
              String.t() | nil,
              term()
            ) ::
              {:ok, String.t()} | {:ok, String.t(), String.t()} | {:error, atom()}
end
