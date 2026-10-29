defmodule KnotraBots.Access do
  @moduledoc """
  Tenant-scoped authorization for the demo.

  The LiveView supplies a scope map; tenant identity never comes from model
  arguments. Only the `"demo"` tenant is allowed. `:answer` derives a nonsecret
  responder reference: a host-supplied `:responder` wins when trusted host code
  (such as the read-only auto-approval policy) sets it, otherwise the OS user.

  This local demo has no web authentication. `responder/1` distinguishes operators
  sharing one workstation, not web sessions; a real host must derive the responder
  from its authenticated session. Scope permissions still gate `:answer`.
  """

  @behaviour Knotra.Access

  @actions [:submit, :inspect, :list, :checkpoint, :recover, :answer, :cancel, :close]

  @impl true
  def authorize(action, _id, %{tenant: tenant, permissions: permissions} = context)
      when action in @actions and is_list(permissions) do
    cond do
      tenant != KnotraBots.tenant() -> {:error, :forbidden}
      action not in permissions -> {:error, :forbidden}
      action == :answer -> {:ok, KnotraBots.tenant(), responder(context)}
      true -> {:ok, KnotraBots.tenant()}
    end
  end

  def authorize(_action, _id, _context), do: {:error, :forbidden}

  defp responder(%{responder: responder}) when is_binary(responder) and responder != "",
    do: responder

  defp responder(_context), do: System.get_env("USER") || "web"
end
