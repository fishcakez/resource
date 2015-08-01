defmodule TCPResourceTest do
  use ExUnit.Case

  test "the truth" do
    Task.start_link(fn() ->
      {:ok, listener} = :gen_tcp.listen(8000, [active: false, mode: :binary])
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, "hello"} = :gen_tcp.recv(socket, 5)
      :ok = :gen_tcp.send(socket, "hi")
    end)

    assert {:ok, pid} = TCPResource.start_link({127,0,0,1}, 8000, [mode: :binary], 1000)
    assert {:ok, ref, socket} = TCPResource.checkout(pid)
    assert {:timeout, _} = catch_exit(TCPResource.checkout(pid))
    assert :ok = TCPResource.send(socket, "hello")
    assert {:ok, "hi"} = TCPResource.recv(socket, 2)
    assert :ok = TCPResource.checkin(pid, ref)
 end
end
