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

    case Supervisor.start_link(children, strategy: :one_for_one, name: SipPhone.Supervisor) do
      {:ok, _pid} = ok ->
        case :logger.add_handler(:sipphone_ui_errors, SipPhone.ErrorHandler, %{level: :error}) do
          :ok -> :ok
          {:error, {:already_exist, _}} -> :ok
          {:error, reason} -> require Logger; Logger.warning("Error panel logger unavailable: #{inspect(reason)}")
        end

        ok

      error -> error
    end
  end

  defp web_children do
    if System.get_env("SIPPHONE_NO_WEB") in [nil, "", "0"] do
      [SipPhone.Web.Server]
    else
      []
    end
  end
end
