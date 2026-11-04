defmodule SipPhone.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :duplicate, name: SipPhone.Clients},
        {Registry, keys: :unique, name: SipPhone.AccountReg},
        {Registry, keys: :unique, name: SipPhone.MediaReg},
        {DynamicSupervisor,
         name: SipPhone.AccountSup, strategy: :one_for_one, max_restarts: 20, max_seconds: 5},
        {Task.Supervisor, name: SipPhone.ConnSup},
        SipPhone.Accounts
      ] ++ web_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: SipPhone.Supervisor)
  end

  defp web_children do
    if System.get_env("SIPPHONE_NO_WEB") in [nil, "", "0"] do
      [SipPhone.Web.Server]
    else
      []
    end
  end
end
