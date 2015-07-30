defmodule Resource do

  use Behaviour
  @timeout 5_000

  defcallback init(args) ::
    {:ok, state} | :ignore | {:stop, reason}
    when args: any, state: any, reason: any

  defcallback handle_checkout(info, from, state) ::
    {:ok, resource, state} | {:error, error, state} |
    {:stop, reason, state} | {:stop, reason, error, state}
    when info: any, from: {pid, any}, state: var, resource: any, error: any,
         reason: any

  defcallback handle_checkin(info, state) ::
    {:ok, state} | {:stop, reason, state}
    when info: any, state: var, reason: any

  defcallback handle_down(down_reason, state) ::
    {:ok, state} | {:stop, reason, state}
    when down_reason: any, state: var, reason: any

  defcallback handle_cancel(state) ::
    {:ok, state} | {:stop, reason, state}
    when state: var, reason: any

  defcallback handle_info(msg, state) ::
    {:ok, state} | {:stop, reason, state}
    when msg: any, state: var, reason: any

  defcallback code_change(oldvsn, state, extra) ::
    {:ok, state} | {:error, reason}
    when oldvsn: any, state: var, extra: any, reason: any

  defcallback terminate(reason, state) :: any when reason: any, state: any

  defmacro __using__(_) do
    quote location: :keep do
      @behaviour Resource

      @doc false
      def init(args) do
        {:ok, args}
      end

      @doc false
      def handle_checkout(info, _from, state) do
        case :erlang.phash2(1, 1) do
          1 -> exit({:bad_checkout, info})
          0 -> {:stop, {:bad_checkout, info}, state}
        end
      end

      @doc false
      def handle_checkin(info, state) do
        case :erlang.phash2(1, 1) do
          1 -> exit({:bad_checkin, info})
          0 -> {:stop, {:bad_checkin, info}, state}
        end
      end

      @doc false
      def handle_down(info, state) do
        case :erlang.phash2(1, 1) do
          1 -> exit({:bad_down, info})
          0 -> {:stop, {:bad_down, info}, state}
        end
      end

      @doc false
      def handle_cancel(state) do
        case :erlang.phash2(1, 1) do
          1 -> exit(:bad_cancel)
          0 -> {:stop, :bad_cancel, state}
        end
      end

      @doc false
      def handle_info(_msg, state) do
        {:noreply, state}
      end

      @doc false
      def terminate(_reason, _state) do
        :ok
      end

      @doc false
      def code_change(_old, state, _extra) do
        {:ok, state}
      end

      defoverridable [init: 1, handle_checkout: 3, handle_checkin: 2,
                      handle_down: 2, handle_cancel: 1, terminate: 2,
                      code_change: 3]
    end
  end



  def start_link(mod, args, opts \\ []) do
    GenServer.start_link(__MODULE__, {mod, args}, opts)
  end

  def checkout(process, info, timeout \\ @timeout) do
    ref = make_ref()
    call = {:checkout, ref, info}
    try do
      GenServer.call(process, call, timeout)
    catch
      :exit, {:timeout, {_, :call, [^process, ^call, ^timeout]}} ->
        GenServer.cast(process, {:cancel, ref})
        exit({:timeout, {__MODULE__, :checkout, [process, info, timeout]}})
    end
  end

  def checkin(process, ref, info) do
    GenServer.cast(process, {:checkin, ref, info})
  end

  @doc false
  def init({mod, args}) do
    Process.put(:"$initial_call", {mod, :init, 1})
    case callback(mod, :init, [args]) do
      {:ok, state} ->
        s = %{mod: mod, state: state, queue: :queue.new, client: nil,
              raise: false}
        {:ok, s}
      :ignore ->
        :ignore
      {:stop, _} = stop ->
        stop
      other ->
        {:stop, {:bad_return_value, other}}
    end
  end

  @doc false
  def handle_call({:checkout, ref, info}, {pid, _} = from, %{client: nil} = s) do
    %{mod: mod, state: state} = s
    case callback(mod, :handle_checkout, [info, from, state]) do
      {:ok, resource, state} ->
        monitor = Process.monitor(pid)
        {:reply, {:ok, ref, resource}, %{s | state: state, client: {monitor, ref}}}
      {:error, error, state} ->
        {:reply, {:error, error}, %{s | state: state}}
      {:stop, reason, error, state} ->
         {:stop, reason, {:error, error}, %{s | state: state}}
      {:stop, reason, state} ->
        {:stop, reason, %{s | state: state}}
      other ->
        {:stop, {:bad_return_value, other}, s}
    end
  end
  def handle_call({:checkout, ref, info}, {pid, _} = from, %{queue: queue} = s) do
    queue =  :queue.in({Process.monitor(pid), ref, info, from}, queue)
    {:noreply, %{s | queue: queue}}
  end

  @doc false
  def handle_cast({:checkin, ref, info}, %{client: {monitor, ref}} = s) do
    %{mod: mod, state: state} = s
    Process.demonitor(monitor, [:flush])
    case callback(mod, :handle_checkin, [info, state]) do
      {:ok, state} ->
        checkout_loop(state, s)
      {:stop, reason, state} ->
        {:stop, reason, %{s | state: state, client: nil}}
      other ->
        {:stop, {:bad_return_value, other}, %{s | client: nil}}
    end
  end
  def handle_cast({:cancel, ref}, %{client: {monitor, ref}} = s) do
    %{mod: mod, state: state} = s
    Process.demonitor(monitor, [:flush])
    case callback(mod, :handle_cancel, [state]) do
      {:ok, state} ->
        checkout_loop(state, s)
      {:stop, reason, state} ->
        {:stop, reason, %{s | state: state, client: nil}}
      other ->
        {:stop, {:bad_return_value, other}, %{s | client: nil}}
    end
  end
  def handle_cast({:cancel, ref}, %{queue: queue} = s) do
    cancel =
      fn({monitor, ref2, _, _}) when ref === ref2 ->
          Process.demonitor(monitor, [:flush])
          false
        (_) ->
          true
      end
    {:noreply, %{s | queue: :queue.filter(cancel, queue)}}
  end

  @doc false
  def handle_info({:DOWN, monitor, _, _, reason}, %{client: {monitor, _}} = s) do
    %{mod: mod, state: state} = s
    case callback(mod, :handle_down, [reason, state]) do
      {:ok, state} ->
        checkout_loop(state, s)
      {:stop, reason, state} ->
        {:stop, reason, %{s | state: state, client: nil}}
      other ->
        {:stop, {:bad_return_value, other}, %{s | client: nil}}
    end
  end
  def handle_info({:DOWN, monitor, _, _, _} = down, %{queue: queue} = s) do
    len = :queue.len(queue)
    filter = fn({monitor2, _, _, _}) -> monitor !== monitor2 end
    queue = :queue.filter(filter, queue)
    case :queue.len(queue) do
      ^len ->
        callback_info(down, %{s | queue: queue})
      _ ->
        {:noreply, %{s | queue: queue}}
    end
  end
  def handle_info(msg, s) do
    callback_info(msg, s)
  end

  @doc false
  def code_change(oldvsn, %{mod: mod, state: state} = s, extra) do
    case callback(mod, :code_change, [oldvsn, state, extra]) do
      {:ok, state}        -> {:ok, %{s | state: state}}
      {:error, _} = error -> error
    end
  end

  @doc false
  def format_status(opt, [pdict, %{mod: mod, state: state} = s]) do
    try do
      apply(mod, :format_status, [opt, [pdict, state]])
    catch
      _, _ ->
        format_status(opt, state, s)
    else
      state ->
        format_status(opt, state, s)
    end
  end

  @doc false
  def terminate({class, reason, stack}, %{raise: true} = s) do
    %{mod: mod, state: state} = s
    callback(mod, :terminate, [raise_reason(class, reason, stack), state])
    :erlang.raise(class, reason, stack)
  end
  def terminate(reason, %{raise: false, mod: mod, state: state}) do
    callback(mod, :terminate, [reason, state])
  end

  ## Internal

  defp callback(mod,fun, args) do
    try do
      apply(mod, fun, args)
    catch
      :throw, value ->
        :erlang.raise(:error, {:nocatch, value}, System.stacktrace())
    end
  end

  defp checkout_loop(state, %{queue: queue} = s) do
    checkout_loop(:queue.out(queue), state, s)
  end

  defp checkout_loop({{:value, {monitor, ref, info, from}}, queue}, state, s) do
    %{mod: mod} = s
    try do
      apply(mod, :handle_checkout, [info, from, state])
    catch
      class, reason ->
        reason = {class, reason, System.stacktrace()}
        {:stop, reason, %{s | state: state, client: nil, raise: true}}
    else
      {:ok, resource, state} ->
        GenServer.reply(from, {:ok, resource, ref})
        {:noreply, %{s | state: state, client: {monitor, ref}, queue: queue}}
      {:error, error, state} ->
        GenServer.reply(from, {:error, error})
        checkout_loop(:queue.out(queue), state, s)
      {:stop, reason, state} ->
        {:stop, reason, %{s | state: state, queue: queue, client: nil}}
      {:stop, reason, error, state} ->
        GenServer.reply(from, {:error, error})
        {:stop, reason, %{s | state: state, queue: queue, client: nil}}
      other ->
        reason = {:bad_return_value, other}
        {:stop, reason, %{s | queue: queue, client: nil}}
    end
  end
  defp checkout_loop({:empty, queue}, state, s) do
    {:noreply, %{s | state: state, queue: queue, client: nil}}
  end

  defp callback_info(msg, %{mod: mod, state: state} = s) do
    case callback(mod, :handle_info, [msg, state]) do
      {:ok, state} ->
        {:noreply, %{s | state: state}}
      {:stop, reason, state} ->
        {:stop, reason, %{s | state: state}}
      other ->
        {:stop, {:bad_return_value, other}, s}
    end
  end

  defp format_status(:normal, state, %{mod: mod, client: client, queue: queue}) do
    status = if client, do: :checked_out, else: :checked_in
    queue = format_queue(queue)
    [{:data, [{'Module', mod},
              {'State', state},
              {'Resource Status', status},
              {'Queue', queue}]}]
  end
  defp format_status(:terminate, state, s) do
    %{s | state: state}
  end

  defp format_queue(queue) do
    queue
    |> :queue.to_list()
    |> Enum.map(fn({_, _, info, {pid, _}}) -> {pid, info} end)
  end

  defp raise_reason(:exit, reason, _),      do: reason
  defp raise_reason(:error, reason, stack), do: {reason, stack}
  defp raise_reason(:throw, value, stack),  do: {{:nocatch, value}, stack}
end
