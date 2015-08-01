defmodule TCPResource do

  use Resource

  def start_link(host, port, opts, timeout \\ 5_000) do
    Resource.start_link(__MODULE__, {host, port, opts, timeout})
  end

  def checkout(pid), do: Resource.checkout(pid, nil)

  def checkin(pid, ref), do: Resource.checkin(pid, ref, nil)

  defdelegate send(sock, data), to: :gen_tcp

  def recv(sock, len, bytes \\ 3_000)

  defdelegate recv(sock, len, bytes), to: :gen_tcp

  @doc false
  def init({host, port, opts, timeout}) do
    opts = opts ++ [active: :once, exit_on_close: false]
    case :gen_tcp.connect(host, port, opts, timeout) do
      {:ok, _} = ok    -> ok
      {:error, reason} -> {:stop, {:tcp_error, reason}}
    end
  end

  @doc false
  def handle_checkout(_, _, sock) do
    case :inet.setopts(sock, [active: false]) do
      :ok ->
        receive do
          {:tcp, ^sock, data}         -> {:stop, {:tcp, data}, sock}
          {:tcp_error, ^sock, reason} -> {:stop, {:tcp_error, reason}, sock}
          {:tcp_closed, ^sock}        -> {:stop, :tcp_closed, sock}
        after
          0 -> {:ok, sock, sock}
        end
      {:error, reason} ->
        {:stop, {:tcp_error, reason}, sock}
    end
  end

  @doc false
  def handle_checkin(_, sock), do: activate(sock)

  @doc false
  def handle_cancel(sock), do: activate(sock)

  @doc false
  def handle_down(_, sock), do: activate(sock)

  @doc false
  def handle_info({:tcp, sock, data}, sock) do
    {:stop, {:tcp, data}, sock}
  end
  def handle_info({:tcp_error, sock, reason}, sock) do
    {:stop, {:tcp_error, reason}, sock}
  end
  def handle_info({:tcp_closed, sock}, sock) do
    {:stop, :tcp_closed, sock}
  end
  def handle_info(_, sock) do
    {:ok, sock}
  end

  ## Helpers

  defp activate(sock) do
    case :inet.setopts(sock, [active: :once]) do
      :ok              -> {:ok, sock}
      {:error, reason} -> {:stop, {:tcp_error, reason}, sock}
    end
  end
end
