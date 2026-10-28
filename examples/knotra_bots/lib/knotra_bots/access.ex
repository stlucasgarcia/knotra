defmodule KnotraBots.Access do
  @moduledoc """
  Tenant-scoped authorization for the demo.

  The LiveView supplies a scope map; tenant identity never comes from model
  arguments. Only the `"demo"` tenant is allowed. `:answer` additionally derives a
  nonsecret responder reference from the OS user.

  This local demo has no web authentication. `responder/0` distinguishes operators
  sharing one workstation, not web sessions; a real host must derive the responder
  from its authenticated session. Scope permissions still gate `:answer`.
  """

  @behaviour Knotra.Access

  @actions [:submit, :inspect, :list, :checkpoint, :recover, :answer, :cancel, :close]

  @impl true
  def authorize(action, _id, %{tenant: tenant, permissions: permissions})
      when action in @actions and is_list(permissions) do
    cond do
      tenant != KnotraBots.tenant() -> {:error, :forbidden}
      action not in permissions -> {:error, :forbidden}
      action == :answer -> {:ok, KnotraBots.tenant(), responder()}
      true -> {:ok, KnotraBots.tenant()}
    end
  end

  def authorize(_action, _id, _context), do: {:error, :forbidden}

  defp responder, do: System.get_env("USER") || "web"
end
