defmodule MiniPbx.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :duplicate, name: MiniPbx.Clients},
        {Registry, keys: :unique, name: MiniPbx.CallReg},
        {Task.Supervisor, name: MiniPbx.ConnSup},
        {Task.Supervisor, name: MiniPbx.SipSup},
        {DynamicSupervisor, strategy: :one_for_one, name: MiniPbx.CallSup},
        MiniPbx.Store,
        MiniPbx.Cdr,
        MiniPbx.Auth,
        MiniPbx.Registrar,
        MiniPbx.Transport
      ] ++ web_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: MiniPbx.Supervisor)
  end

  defp web_children do
    if System.get_env("MINIPBX_NO_WEB") in [nil, "", "0"], do: [MiniPbx.Web.Server], else: []
  end
end
