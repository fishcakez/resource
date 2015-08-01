TCPResource
===========

Start a listening socket and accept a connection:
```elixir
{:ok, listener} = :gen_tcp.listen(8000, [active: false, mode: :binary])
{:ok, socket} = :gen_tcp.accept(listener)
{:ok, "hello"} = :gen_tcp.recv(socket, 5)
:ok = :gen_tcp.send(socket, "hi")
```

Then in another shell start the resource:
```elixir
{:ok, pid} = TCPResource.start_link({127,0,0,1}, 8000, [mode: :binary], 1000)
{:ok, ref, socket} = TCPResource.checkout(pid)
:ok = TCPResource.send(socket, "hello")
{:ok, "hi"} = TCPResource.recv(socket, 2)
:ok = TCPResource.checkin(pid, ref)
```
