defmodule Knotra.Access do
  @moduledoc """
  Host authorization for durable operations. Resolve tenant identity from trusted
  context, never model arguments. `:checkpoint` grants access to sensitive private
  continuation data and must be authorized separately from `:inspect`. `:answer`
  permits a responder to decide the identified approval or to answer the identified
  input request; it does not grant tool business authority. For `:answer`, return
  `{:ok, tenant_id, responder_id}`: a host-authenticated, nonsecret binary reference
  of 1–256 bytes, never credentials or a channel/model-supplied actor. It is recorded
  atomically with the decision or answer.
  Other actions may still return `{:ok, tenant_id}`. `:cancel` permits pre-admission
  durable cancellation; `:close` deletes one terminal or blocked record and releases
  its capacity; `:list` is tenant-scoped inspection of public records.
  Inspection/recovery/answering/listing also materialize an already-due response
  expiry.
  """
  @callback authorize(
              :submit
              | :inspect
              | :list
              | :checkpoint
              | :recover
              | :answer
              | :cancel
              | :close,
              String.t() | nil,
              term()
            ) ::
              {:ok, String.t()} | {:ok, String.t(), String.t()} | {:error, atom()}
end
